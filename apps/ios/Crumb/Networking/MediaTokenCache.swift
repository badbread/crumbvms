// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Per-camera cache of scoped, short-lived (~15 min) media tokens, replacing the
/// old pattern of embedding the full (up to 10-year) login JWT in every
/// per-camera media URL (`?token=<JWT>`), where it could leak into proxy /
/// access logs and any player or `<img>`-style source.
///
/// `GET /media-token?camera=<uuid>` (called WITH the full login JWT in the
/// `Authorization` header) mints a token valid ONLY as `?token=` on media
/// endpoints for that ONE camera, for ~15 min (`MediaTokenResponse`). This actor:
///
/// - Maps `cameraId -> (token, expiresAt)`, `expiresAt` parsed straight from
///   the server's own `expires_at` (RFC-3339) rather than assumed locally.
/// - Refreshes when a cached token is missing or expiring within
///   `refreshMargin` (~10s) of now, so a caller never hands out a token that's
///   about to die mid-request.
/// - Dedupes concurrent fetches for the same camera to a single in-flight
///   `Task` — actor isolation makes this trivial (no explicit locking).
/// - Never falls back to the full JWT on failure. A transient fetch error
///   surfaces as `nil` from `token(for:)`; the existing player/image retry
///   loops elsewhere in the app re-attempt on their own schedules, and a
///   genuine 401 (session expired/revoked) is handled by `CrumbAPI.execute`'s
///   existing `clearSession()` path, which this cache rides on transparently
///   since it calls through `CrumbAPI.mediaToken`.
actor MediaTokenCache {

    private struct Entry {
        let token: String
        let expiresAt: Date
    }

    /// Tokens are minted for ~15 min server-side; refresh a little early so a URL
    /// built "now" doesn't die in flight (slow network, queued request, etc.).
    private static let refreshMargin: TimeInterval = 10
    /// Fallback TTL if `expires_at` fails to parse (shouldn't happen against a
    /// conforming server) — conservative, shorter than the real ~15 min so a
    /// parse miss still refreshes promptly rather than serving a dead token.
    private static let fallbackTTL: TimeInterval = 45

    private let api: CrumbAPI
    private var entries: [String: Entry] = [:]
    /// One in-flight mint `Task` per camera, so concurrent callers (e.g. a
    /// live tile opening while playback also warms the same camera) share a
    /// single network round trip instead of racing independent fetches.
    private var inFlight: [String: Task<MediaTokenResponse, Error>] = [:]

    init(api: CrumbAPI) {
        self.api = api
    }

    /// Returns a fresh (or freshly-cached) scoped media token for `cameraId`,
    /// minting one via `GET /media-token` if the cache is empty or the cached
    /// token expires within `refreshMargin`. Returns `nil` only on failure —
    /// callers must NOT fall back to the full JWT; instead they should retry
    /// per their own existing retry/backoff behavior.
    func token(for cameraId: String) async -> String? {
        if let entry = entries[cameraId], entry.expiresAt.timeIntervalSinceNow > Self.refreshMargin {
            return entry.token
        }
        if let existing = inFlight[cameraId] {
            return try? await existing.value.token
        }
        let task = Task<MediaTokenResponse, Error> { [api] in
            try await api.mediaToken(cameraId: cameraId)
        }
        inFlight[cameraId] = task
        defer { inFlight[cameraId] = nil }

        do {
            let resp = try await task.value
            let expiresAt = parseISO8601(resp.expiresAt) ?? Date().addingTimeInterval(Self.fallbackTTL)
            entries[cameraId] = Entry(token: resp.token, expiresAt: expiresAt)
            return resp.token
        } catch {
            return nil
        }
    }

    /// Drop any cached/in-flight state for one camera. Currently unused (no
    /// call site needs per-camera invalidation yet) but kept for symmetry with
    /// `invalidateAll()` and as the natural extension point if one shows up.
    func invalidate(cameraId: String) {
        entries[cameraId] = nil
        inFlight[cameraId]?.cancel()
        inFlight[cameraId] = nil
    }

    /// Drop everything — call on logout/`clearSession()` so a stale token from
    /// a previous session can never be reused after re-login, and on server
    /// switch (`rebuildApi()`) since a cached token is only valid against the
    /// server that minted it.
    func invalidateAll() {
        entries.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }
}
