// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

final class CrumbAPI {

    private let store: KeychainStore
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    init(store: KeychainStore) {
        self.store = store
    }

    private var baseURL: String { store.serverUrl }

    // MARK: - Auth

    func login(_ body: LoginRequest) async throws -> LoginResponse {
        try await post("auth/login", body: body, authenticated: false)
    }

    func me() async throws -> UserDto {
        try await get("auth/me")
    }

    /// Mint a scoped, short-lived (~15 min) media token for one camera. Called
    /// WITH the full login JWT (`authenticated: true`, the default). See
    /// `MediaTokenCache`, which owns caching/refresh/dedup for this call.
    func mediaToken(cameraId: String) async throws -> MediaTokenResponse {
        try await get("media-token", query: ["camera": cameraId])
    }

    // MARK: - Cameras

    /// Viewer-safe camera list, scoped to the caller (admins get all cameras,
    /// viewers only their permitted ones; sensitive fields omitted). Use this for
    /// all live-wall, playback, and clip camera-list loads.
    func visibleCameras() async throws -> [CameraDto] {
        try await get("cameras")
    }

    /// Admin camera list with full config (go2rtc_name, policy, motion mask).
    /// Admin-only (`403` for viewers) — use only for the motion tuner.
    func cameras() async throws -> [CameraDto] {
        try await get("config/cameras")
    }

    // MARK: - Timeline

    func timeline(cameraIds: [String], start: String, end: String) async throws -> TimelineResponse {
        try await get("timeline", query: [
            "camera_ids": cameraIds.joined(separator: ","),
            "start": start,
            "end": end,
        ])
    }

    func timelineIntensity(cameraId: String, start: String, end: String, buckets: Int = 240) async throws -> IntensityResponse {
        try await get("timeline/intensity", query: [
            "camera_id": cameraId,
            "start": start,
            "end": end,
            "buckets": "\(buckets)",
        ])
    }

    // MARK: - Playback

    func play(cameraId: String, ts: String, stream: String = "main") async throws -> ResolvedSegment {
        try await get("play/\(cameraId)", query: ["ts": ts, "stream": stream])
    }

    // MARK: - Live

    func liveStreams(cameraId: String) async throws -> LiveStreamsResponse {
        try await get("cameras/\(cameraId)/streams")
    }

    // MARK: - Status

    func status() async throws -> SystemStatusResponse {
        try await get("status")
    }

    // MARK: - PTZ

    func ptz(cameraId: String, body: PtzRequest) async throws -> PtzResponse {
        try await post("cameras/\(cameraId)/ptz", body: body)
    }

    // MARK: - Updates

    /// `GET /updates/latest` (any authenticated user) — the server-mediated
    /// GitHub version check (`docs/UPDATE-SYSTEM-PLAN.md` §2.1). `refresh:
    /// true` forces the server to bypass its TTL cache and re-check
    /// github.com immediately ("Check now", §2.5); the server itself
    /// rate-limits this, so callers don't need to. A 404 means an older
    /// server without the endpoint at all — see `UpdateChecker`, which
    /// treats that as "show nothing" via `Error.isNotFound`.
    func updatesLatest(refresh: Bool = false) async throws -> UpdateStatus {
        try await get("updates/latest", query: refresh ? ["refresh": "1"] : [:])
    }

    // MARK: - Filmstrip

    func filmstrip(cameraId: String, start: String, end: String, width: Int = 160) async throws -> FilmstripResponse {
        try await get("filmstrip/\(cameraId)", query: [
            "start": start,
            "end": end,
            "width": "\(width)",
        ])
    }

    // MARK: - Bookmarks

    func bookmarks(cameraId: String? = nil) async throws -> [BookmarkDto] {
        var query: [String: String] = [:]
        if let cameraId { query["camera_id"] = cameraId }
        return try await get("bookmarks", query: query)
    }

    func createBookmark(_ body: CreateBookmarkRequest) async throws -> BookmarkDto {
        try await post("bookmarks", body: body)
    }

    func deleteBookmark(id: String) async throws {
        let _: EmptyResponse = try await delete("bookmarks/\(id)")
    }

    // MARK: - Export

    func createExport(_ body: CreateExportRequest) async throws -> CreateExportResponse {
        try await post("export", body: body)
    }

    /// Batch export: a list of {camera, range} clips bundled into one job
    /// (single archive server-side when >1 output or a password is set).
    func createBatchExport(_ body: CreateBatchExportRequest) async throws -> CreateExportResponse {
        try await post("export/batch", body: body)
    }

    func exportStatus(jobId: String) async throws -> ExportJob {
        try await get("export/\(jobId)")
    }

    /// Cancel a running/queued export (DELETE /export/{id}; 204, idempotent).
    func cancelExport(jobId: String) async throws {
        let _: EmptyResponse = try await delete("export/\(jobId)")
    }

    // MARK: - Clips

    func clips(
        cameraIds: String = "",
        start: String,
        end: String,
        type: String = "",
        limit: Int = 200
    ) async throws -> ClipsResponse {
        var query: [String: String] = [
            "start": start,
            "end": end,
            "limit": "\(limit)",
        ]
        if !cameraIds.isEmpty { query["camera_ids"] = cameraIds }
        if !type.isEmpty { query["type"] = type }
        return try await get("clips", query: query)
    }

    func markClipViewed(id: String) async throws {
        let _: EmptyResponse = try await post("clips/viewed", body: MarkViewedRequest(id: id))
    }

    // MARK: - Events

    func events(cameraIds: String, start: String, end: String, limit: Int = 500, offset: Int = 0) async throws -> DetectionEventsResponse {
        try await get("events", query: [
            "camera_ids": cameraIds,
            "start": start,
            "end": end,
            "limit": "\(limit)",
            "offset": "\(offset)",
        ])
    }

    // MARK: - License Plates (LPR)

    /// `GET /plates` — license-plate reads for the given cameras (viewer-scoped;
    /// out-of-scope cameras are dropped server-side). Needs `view_plates`.
    /// Newest-first, except `match == "fuzzy"` which the server orders by
    /// similarity — the caller must preserve that order (do not re-sort by time).
    func plates(cameraIds: [String], start: String? = nil, end: String? = nil,
                q: String? = nil, match: String? = nil,
                limit: Int = 200, offset: Int = 0) async throws -> PlatesResponse {
        var query: [String: String] = [
            "camera_ids": cameraIds.joined(separator: ","),
            "limit": "\(limit)",
            "offset": "\(offset)",
        ]
        if let start { query["start"] = start }
        if let end { query["end"] = end }
        // `q`/`match` are only meaningful together and only when `q` is non-empty.
        if let q, !q.isEmpty {
            query["q"] = q
            if let match { query["match"] = match }
        }
        return try await get("plates", query: query)
    }

    /// `GET /lpr/watchlist` — the plate watchlist. Needs `view_plates`.
    func watchlist() async throws -> [WatchlistEntry] {
        try await get("lpr/watchlist")
    }

    /// `GET /config/lpr` — admin-only LPR config (carries `watchlist_fuzz` for
    /// the live match preview). Callers swallow a 403 (non-admin) and hide it.
    func lprConfig() async throws -> LprConfigDto {
        try await get("config/lpr")
    }

    /// `PUT /config/lpr` — admin. Set the watchlist fuzziness; round-trips
    /// `enabled`/`retention_days` unchanged (server clamps fuzz to 0…0.5).
    @discardableResult
    func putLprConfig(enabled: Bool, retentionDays: Int, watchlistFuzz: Double) async throws -> LprConfigDto {
        struct Body: Encodable {
            let enabled: Bool
            let retention_days: Int
            let watchlist_fuzz: Double
        }
        return try await put("config/lpr", body: Body(enabled: enabled, retention_days: retentionDays, watchlist_fuzz: watchlistFuzz))
    }

    /// `GET /events/{event_id}/snapshot` — the full detection frame for a plate
    /// read, Bearer-authed + `view_plates`-gated. Returns raw JPEG bytes; the
    /// client derives the tight plate crop from the read's `bbox`.
    func plateSnapshot(eventId: String) async throws -> Data {
        try await imageData("events/\(eventId)/snapshot")
    }

    /// `POST /lpr/watchlist` — add or edit (keyed on the normalized plate) a
    /// watchlist entry. ADMIN ONLY (server returns 403 otherwise).
    @discardableResult
    func addWatchlist(_ body: WatchlistAddRequest) async throws -> WatchlistEntry {
        try await post("lpr/watchlist", body: body)
    }

    /// `DELETE /lpr/watchlist/{id}` — remove a watchlist entry. ADMIN ONLY.
    /// Verifies the HTTP status rather than assuming success: a `404` means the
    /// entry was already gone (treated as success); any other non-2xx (notably a
    /// `403` for a non-admin) propagates as an `APIError` so the UI never falsely
    /// reports "removed".
    func deleteWatchlist(id: String) async throws {
        do {
            let _: EmptyResponse = try await delete("lpr/watchlist/\(id)")
        } catch let error as APIError where error.isNotFound {
            // Already gone — the desired end state, treat as success.
        }
    }

    // MARK: - Home Assistant overlay

    /// `GET /cameras/:id/ha/links` — the camera's linked HA entities (+ overlay
    /// placement). Viewer-accessible (camera-scoped). Empty ⇒ no HA for this cam.
    func haLinks(cameraId: String) async throws -> [HaLink] {
        try await get("cameras/\(cameraId)/ha/links")
    }

    /// `GET /ha/states` — live states for entities the caller can see (RBAC
    /// projected). `stale`/`fetched_at_ms_ago` drive badge greying. Returns 400
    /// when HA is disabled — callers treat that as "no states", not a hard error.
    func haStates() async throws -> HaStatesResponse {
        try await get("ha/states")
    }

    // MARK: - Saved Views (server-backed, per-user; shared with desktop/android/web)

    /// All views visible to the caller (own + legacy global + shared-with-me).
    func views() async throws -> [ViewDto] {
        try await get("views")
    }

    /// Create a view owned by the caller. Requires the `manage_views` capability.
    @discardableResult
    func createView(_ body: CreateViewRequest) async throws -> ViewDto {
        try await post("views", body: body)
    }

    /// Delete a view by id. Owner or admin only.
    func deleteView(id: String) async throws {
        let _: EmptyResponse = try await delete("views/\(id)")
    }

    // MARK: - Motion Tuner

    /// Live heatmap: `GET /cameras/{id}/motion-grid`
    func motionGrid(cameraId: String) async throws -> MotionGridDto {
        try await get("cameras/\(cameraId)/motion-grid")
    }

    /// Update motion policy (sensitivity + threshold): `PUT /config/cameras/{id}/policy`
    @discardableResult
    func updatePolicy(cameraId: String, body: UpdatePolicyRequest) async throws -> PolicyDto {
        try await put("config/cameras/\(cameraId)/policy", body: body)
    }

    /// Replace exclusion mask: `PUT /config/cameras/{id}` with motion_mask only.
    @discardableResult
    func updateCameraMask(cameraId: String, body: UpdateCameraMaskRequest) async throws -> CameraDto {
        try await put("config/cameras/\(cameraId)", body: body)
    }

    /// Set motion source + algorithm: `PUT /config/cameras/{id}` with motion_source + motion_algorithm.
    @discardableResult
    func updateCameraMotion(cameraId: String, body: UpdateCameraMotionRequest) async throws -> CameraDto {
        try await put("config/cameras/\(cameraId)", body: body)
    }

    // MARK: - Transport

    /// Fetch raw bytes (e.g. a JPEG) from a Bearer-authed endpoint. Non-media
    /// image endpoints (plate snapshots) use the login JWT, not a media token.
    private func imageData(_ path: String) async throws -> Data {
        let url = try buildURL(path)
        var request = URLRequest(url: url)
        addAuth(&request)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            // `imageData` is nonisolated and resumes off the main actor after the
            // `await` above — `store.clearSession()` synchronously writes
            // `KeychainStore`'s `@Published var token` (see KeychainStore.swift),
            // which SwiftUI expects to only ever change on the main thread. Hop
            // over rather than call it directly from here.
            if http.statusCode == 401 { Task { @MainActor in self.store.clearSession() } }
            throw APIError.http(statusCode: http.statusCode, data: data)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], authenticated: Bool = true) async throws -> T {
        let url = try buildURL(path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if authenticated { addAuth(&request) }
        request.timeoutInterval = 30
        return try await execute(request)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, authenticated: Bool = true) async throws -> T {
        let url = try buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if authenticated { addAuth(&request) }
        request.timeoutInterval = 30
        return try await execute(request)
    }

    private func put<B: Encodable, T: Decodable>(_ path: String, body: B, authenticated: Bool = true) async throws -> T {
        let url = try buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if authenticated { addAuth(&request) }
        request.timeoutInterval = 30
        return try await execute(request)
    }

    private func delete<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        let url = try buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if authenticated { addAuth(&request) }
        request.timeoutInterval = 30
        return try await execute(request)
    }

    private func addAuth(_ request: inout URLRequest) {
        if let token = store.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func buildURL(_ path: String, query: [String: String] = [:]) throws -> URL {
        let base = baseURL.hasSuffix("/") ? baseURL : "\(baseURL)/"
        guard var components = URLComponents(string: "\(base)\(path)") else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            // A runtime 401 means the token expired/was revoked. Drop the session
            // so the app returns to login instead of silently failing every call.
            // (403 is a capability denial, not a session problem — left untouched.)
            //
            // `execute` is nonisolated and resumes off the main actor after the
            // `await` above — `store.clearSession()` synchronously writes
            // `KeychainStore`'s `@Published var token`, which SwiftUI expects to
            // only ever change on the main thread (an unsynchronized read/write
            // race otherwise). Hop over rather than call it directly from here.
            if http.statusCode == 401 {
                Task { @MainActor in store.clearSession() }
            }
            throw APIError.http(statusCode: http.statusCode, data: data)
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct EmptyResponse: Decodable {}

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case http(statusCode: Int, data: Data)

    var isUnauthorized: Bool {
        if case .http(let code, _) = self { return code == 401 }
        return false
    }

    var isNotFound: Bool {
        if case .http(let code, _) = self { return code == 404 }
        return false
    }

    /// A capability/role denial (e.g. a non-admin attempting a watchlist write).
    var isForbidden: Bool {
        if case .http(let code, _) = self { return code == 403 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL."
        case .invalidResponse: return "Invalid response from server."
        case .http(let code, _):
            switch code {
            case 401: return "Session expired or invalid credentials."
            case 403: return "You don't have access to this resource."
            case 404: return "Not found."
            default: return "Server error (\(code))."
            }
        }
    }
}

extension Error {
    var isNotFound: Bool {
        (self as? APIError)?.isNotFound ?? false
    }

    /// M2: lets call sites (e.g. `LiveViewModel.loadCameras`) distinguish "the
    /// session died" from any other failure without downcasting to `APIError`
    /// themselves — mirrors `isNotFound` above.
    var isUnauthorized: Bool {
        (self as? APIError)?.isUnauthorized ?? false
    }

    var userMessage: String {
        if let api = self as? APIError { return api.localizedDescription }
        if (self as NSError).domain == NSURLErrorDomain {
            return "Can't reach the server. Check the address and your connection."
        }
        return localizedDescription
    }
}
