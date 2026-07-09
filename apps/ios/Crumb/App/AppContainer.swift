// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Combine

@MainActor
final class AppContainer: ObservableObject {

    let store: KeychainStore
    /// Observable user preferences (grid layout, toggles, saved views).
    let settings: AppSettings
    private(set) var api: CrumbAPI
    /// Per-camera scoped media-token cache (P0-SESSIONS media-URL migration).
    /// Rebuilt alongside `api` in `rebuildApi()` so a token is never reused
    /// against a different server than the one that minted it.
    private(set) var mediaTokens: MediaTokenCache
    /// Shared macOS+iOS update-available checker (issue #7, task C4). Unlike
    /// `mediaTokens`, this object's own identity stays stable for the life of
    /// the container — `rebuildApi()` only swaps its `api` reference — so a
    /// view's `@ObservedObject` binding (e.g. `SettingsView`) survives a
    /// server-URL change.
    let updateChecker: UpdateChecker
    @Published var isLoggedIn: Bool = false
    /// Effective per-user capabilities, driving feature gating across the app.
    /// Seeded from persistence at launch, refreshed by `GET /auth/me`.
    @Published private(set) var capabilities: Capabilities
    @Published private(set) var isAdmin: Bool

    private var cancellable: AnyCancellable?

    init() {
        let store = KeychainStore()
        self.store = store
        self.settings = AppSettings()
        self.api = CrumbAPI(store: store)
        self.mediaTokens = MediaTokenCache(api: self.api)
        self.updateChecker = UpdateChecker(api: self.api)
        self.isLoggedIn = store.isLoggedIn
        self.capabilities = store.capabilities
        self.isAdmin = store.isAdmin
        cancellable = store.$token
            .receive(on: DispatchQueue.main)
            .sink { [weak self] token in
                let loggedIn = token != nil && !(token?.isEmpty ?? true)
                self?.isLoggedIn = loggedIn
                // On logout, drop capabilities back to the restrictive default so a
                // stale grant can't briefly leak into the next session's UI.
                if !loggedIn {
                    self?.capabilities = Capabilities()
                    self?.isAdmin = false
                    // A logged-out session's cached scoped media tokens must
                    // never survive into the next login (different user,
                    // possibly different camera scope).
                    if let cache = self?.mediaTokens {
                        Task { await cache.invalidateAll() }
                    }
                }
            }
        // Best-effort session validation on launch: a 401 explicitly clears the
        // stored token (forcing re-login); any other failure (offline, server
        // down, transient error) keeps the user signed in — the wall + status
        // calls will retry on their own.
        if isLoggedIn {
            Task { await self.validateSession() }
        }
    }

    /// Persist + publish the signed-in user's role and effective capabilities.
    /// Call after login and on every `GET /auth/me`.
    func applyUser(_ me: UserDto) {
        let caps = me.effectiveCapabilities
        capabilities = caps
        isAdmin = me.isAdmin
        store.capabilities = caps
        store.role = me.role
        // `applyUser` runs exactly once per successful login and once per
        // launch (session validation below), which is precisely "check once
        // after login/launch" for the update checker (§3) — `checkIfNeeded()`
        // itself throttles to at most every 24h.
        Task { await updateChecker.checkIfNeeded() }
    }

    private func validateSession() async {
        do {
            let me = try await api.me()
            applyUser(me)
        } catch let error as APIError {
            if error.isUnauthorized {
                store.clearSession()
            }
        } catch {
            // Network error / server unreachable — keep the session
        }
    }

    func rebuildApi() {
        api = CrumbAPI(store: store)
        // A cached media token is only valid against the server that minted
        // it (same JWT_SECRET) — a server-address change must not let a
        // stale token leak into requests against the new server.
        let old = mediaTokens
        Task { await old.invalidateAll() }
        mediaTokens = MediaTokenCache(api: api)
        // Point the (stable-identity) update checker at the new server
        // instead of replacing it, so any existing @ObservedObject binding
        // to it keeps working.
        updateChecker.api = api
    }

    func mediaUrls() -> MediaUrls {
        MediaUrls(serverUrl: store.serverUrl, token: store.token, tokenCache: mediaTokens)
    }
}
