// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct MediaUrls {
    let serverUrl: String
    let token: String?
    /// Per-camera scoped media-token cache (P0-SESSIONS), owned by
    /// `AppContainer` and shared by every `MediaUrls` value it hands out.
    /// `Optional` only so a bare `MediaUrls` can still be constructed (e.g. a
    /// future preview/test) without a live container — `scopedURL` simply
    /// returns `nil` in that case, matching "token mint failed".
    let tokenCache: MediaTokenCache?

    /// Full-JWT-authed URL — for endpoints that are NOT single-camera-scoped
    /// (export batch downloads, which can span multiple cameras and the
    /// archive pseudo-camera) or non-media API calls. Do NOT use this for
    /// per-camera media (frame/segment/clip/filmstrip) — use `scopedURL`.
    func authed(_ pathOrUrl: String) -> URL? {
        let absolute = toAbsolute(pathOrUrl)
        guard var components = URLComponents(string: absolute) else { return URL(string: absolute) }
        if let token, !token.isEmpty {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "token", value: token))
            components.queryItems = items
        }
        return components.url
    }

    /// Camera-scoped media URL carrying a short-lived (~15 min) `?token=` minted
    /// via `GET /media-token?camera=<cameraId>` (cached/refreshed/deduped by
    /// `MediaTokenCache`), instead of the full login JWT. This is the
    /// migrated replacement for `authed(_:)` on every per-camera media
    /// endpoint (live stream proxy, recorded segment, filmstrip/scrub frame,
    /// clip thumbnail/video, camera snapshot).
    ///
    /// Returns `nil` if the token mint fails (offline, camera access revoked,
    /// session expired — the 401 path already routes through
    /// `CrumbAPI.execute`'s `clearSession()`) — callers must NOT fall back to
    /// the full JWT; let the existing player/image retry loop try again.
    func scopedURL(cameraId: String, _ pathOrUrl: String) async -> URL? {
        guard let tokenCache, let token = await tokenCache.token(for: cameraId) else { return nil }
        return urlWithToken(pathOrUrl, token: token)
    }

    /// Non-async convenience for call sites that already hold a fresh token
    /// (e.g. re-minting a per-segment URL from a token obtained moments
    /// earlier in the same async context — see `HEVCRetag`'s range-proxy).
    func urlWithToken(_ pathOrUrl: String, token: String) -> URL? {
        let absolute = toAbsolute(pathOrUrl)
        guard var components = URLComponents(string: absolute) else { return URL(string: absolute) }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url
    }

    func cameraFrameUrl(_ cameraId: String) async -> URL? {
        await scopedURL(cameraId: cameraId, "/cameras/\(cameraId)/frame.jpg")
    }

    /// Authenticated live fragmented-MP4 stream via the API's `/live` proxy
    /// (`GET /live/{id}/stream.mp4?stream=main|sub`). go2rtc is no longer exposed
    /// directly (it runs with `local_auth`), so live rides the JWT-protected API
    /// with a scoped `?token=` like every other media URL. Mint fresh per connect:
    /// the token is short-lived and a persistent stream may reconnect after it
    /// expires.
    func liveFmp4URL(cameraId: String, sub: Bool) async -> URL? {
        await scopedURL(cameraId: cameraId, "/live/\(cameraId)/stream.mp4?stream=\(sub ? "sub" : "main")")
    }

    /// Authenticated WebRTC (WHEP) signaling endpoint via the API's `/live` proxy
    /// (`POST /live/{id}/webrtc?stream=main|sub`) — go2rtc's REST API is no longer
    /// LAN-reachable. Scoped `?token=`, minted fresh per signaling POST (the
    /// manager reconnects, and the token is short-lived).
    func liveWhepURL(cameraId: String, sub: Bool) async -> URL? {
        await scopedURL(cameraId: cameraId, "/live/\(cameraId)/webrtc?stream=\(sub ? "sub" : "main")")
    }

    /// Historical still extracted on-demand from recorded footage at `ts`
    /// (RFC-3339). Used for the playback wall's scrub-to-moment tile previews.
    func historicalFrameUrl(cameraId: String, tsISO: String) async -> URL? {
        let encoded = tsISO.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tsISO
        return await scopedURL(cameraId: cameraId, "/filmstrip/\(cameraId)/frame?ts=\(encoded)")
    }

    /// Thumbnail still for a clip. Requires token auth; scoped to `cameraId`.
    func clipThumbUrl(_ id: String, cameraId: String) async -> URL? {
        await scopedURL(cameraId: cameraId, "/clip/\(id)/thumbnail.jpg")
    }

    /// Preview MP4 for a clip. `quality` defaults to `"preview"` (reduced res/fps).
    func clipVideoUrl(_ id: String, cameraId: String, quality: String = "preview") async -> URL? {
        await scopedURL(cameraId: cameraId, "/clip/\(id)/clip.mp4?q=\(quality)")
    }


    private func toAbsolute(_ pathOrUrl: String) -> String {
        if pathOrUrl.hasPrefix("http://") || pathOrUrl.hasPrefix("https://") {
            return pathOrUrl
        }
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        let path = pathOrUrl.hasPrefix("/") ? pathOrUrl : "/\(pathOrUrl)"
        return "\(base)\(path)"
    }
}
