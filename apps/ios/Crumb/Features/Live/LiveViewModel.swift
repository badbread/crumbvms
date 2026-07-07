// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Combine

@MainActor
final class LiveViewModel: ObservableObject {

    @Published var cameras: [CameraDto] = []
    @Published var cameraStatuses: [String: CameraStatusEntry] = [:]
    @Published var activeDetections: [String: [String]] = [:]
    /// Per-camera live stream URLs (WebRTC/RTSP) resolved from the auth-scoped
    /// `GET /cameras/{id}/streams`. Keyed by camera id. The viewer camera list
    /// omits `go2rtc_name`, so the live URLs come from here, not built client-side.
    @Published var streams: [String: LiveStreamsResponse] = [:]
    @Published var configVersion = ""
    @Published var isLoading = false
    @Published var error: String?
    /// Saved views (M1: server-backed via `/views`, replacing the old
    /// phone/desktop-local-only UserDefaults set — see `loadViews()`).
    @Published var views: [CameraView] = []

    let container: AppContainer
    private var statusTask: Task<Void, Never>?
    private var detectionsTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
    }

    var store: KeychainStore { container.store }

    func mediaUrls() -> MediaUrls {
        container.mediaUrls()
    }

    /// Load the visible camera list.
    ///
    /// M2 self-heal: if the list comes back empty, or the fetch fails
    /// (including a 401), transparently retry once rather than leaving the
    /// wall permanently blank. A 401 additionally drives the existing
    /// logout/re-auth path (`KeychainStore.clearSession()`, already triggered
    /// by `CrumbAPI.execute` on any 401) so the user lands back at the login
    /// screen instead of staring at an empty wall with no explanation.
    func loadCameras() async {
        await loadCameras(retriesRemaining: 1)
    }

    private func loadCameras(retriesRemaining: Int) async {
        isLoading = true
        do {
            let cams = try await container.api.visibleCameras().filter(\.enabled)
            if cams.isEmpty, retriesRemaining > 0 {
                // Could be a transient empty response (server mid-restart,
                // config still propagating, or a stale/empty local cache) —
                // one silent retry before we accept "no cameras" as the true
                // state.
                try? await Task.sleep(nanoseconds: 400_000_000)
                await loadCameras(retriesRemaining: retriesRemaining - 1)
                return
            }
            cameras = cams
            error = nil
            await resolveStreams(cams)
        } catch {
            if error.isUnauthorized {
                // CrumbAPI.execute already cleared the session on 401 — the
                // existing logout/re-auth path (AppContainer's `$token`
                // observer flips `isLoggedIn` false) takes it from here;
                // RootView swaps back to LoginView. Nothing more to retry.
                self.error = nil
            } else if retriesRemaining > 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await loadCameras(retriesRemaining: retriesRemaining - 1)
                return
            } else {
                self.error = error.userMessage
            }
        }
        isLoading = false
    }

    /// Concurrently resolve each camera's live (WebRTC/RTSP) stream URLs from the
    /// auth-scoped `GET /cameras/{id}/streams`. Individual failures are dropped —
    /// a tile with no URL shows its own error/snapshot state. Mirrors Android's
    /// `LiveViewModel.resolveStreams`.
    private func resolveStreams(_ cams: [CameraDto]) async {
        let api = container.api  // snapshot off the main actor before fan-out
        var result: [String: LiveStreamsResponse] = [:]
        await withTaskGroup(of: (String, LiveStreamsResponse?).self) { group in
            for cam in cams {
                let id = cam.id
                group.addTask { (id, try? await api.liveStreams(cameraId: id)) }
            }
            for await (id, resp) in group {
                if let resp { result[id] = resp }
            }
        }
        streams = result
    }

    /// Ensure a single camera's live stream URLs are resolved — used by the
    /// fullscreen view when opened/swiped before the wall's bulk resolve covers it.
    func ensureStream(_ cameraId: String) async {
        if streams[cameraId] != nil { return }
        let api = container.api
        if let resp = try? await api.liveStreams(cameraId: cameraId) {
            streams[cameraId] = resp
        }
    }

    func startStatusPolling() {
        stopStatusPolling()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        detectionsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDetections()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
        detectionsTask?.cancel()
        detectionsTask = nil
    }

    private func pollStatus() async {
        do {
            let resp = try await container.api.status()
            var map: [String: CameraStatusEntry] = [:]
            for entry in resp.cameras { map[entry.id] = entry }
            cameraStatuses = map

            if !configVersion.isEmpty && resp.configVersion != configVersion {
                await loadCameras()
            }
            configVersion = resp.configVersion
        } catch {
            // Status polling is best-effort
        }
    }

    private func pollDetections() async {
        let ids = cameras.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            let windowStart = iso8601String(Date(timeIntervalSinceNow: -25))
            let windowEnd = iso8601String(Date(timeIntervalSinceNow: 5))
            let resp = try await container.api.events(
                cameraIds: ids.joined(separator: ","),
                start: windowStart,
                end: windowEnd,
                limit: 100
            )
            let nowMs = Date().timeIntervalSince1970 * 1000
            let lingerMs: Double = 8000
            var byCam: [String: [String]] = [:]
            for event in resp.events {
                let active: Bool
                if event.endTs == nil {
                    active = true
                } else if let endDate = parseISO8601(event.endTs!) {
                    active = (nowMs - endDate.timeIntervalSince1970 * 1000) < lingerMs
                } else {
                    active = false
                }
                guard active, !event.iconKey.isEmpty, event.iconKey != "motion" else { continue }
                var keys = byCam[event.cameraId, default: []]
                if !keys.contains(event.iconKey) {
                    keys.append(event.iconKey)
                    byCam[event.cameraId] = keys
                }
            }
            activeDetections = byCam
        } catch {
            // Best-effort
        }
    }

    func logout() {
        stopStatusPolling()
        container.store.clearSession()
    }

    // MARK: - Saved Views (M1: server-backed `/views`, shared with desktop/android/web)

    /// Load saved views from the server. Best-effort — a failure (offline,
    /// server error) leaves the last-known `views` in place rather than
    /// clearing the chip row out from under the user.
    func loadViews() async {
        guard let list = try? await container.api.views() else { return }
        views = list.map { $0.toCameraView() }
    }

    /// Create a view owned by the caller and make it active. Returns the
    /// server-assigned view on success.
    @discardableResult
    func createView(_ view: CameraView) async -> CameraView? {
        guard let created = try? await container.api.createView(view.toCreateRequest()) else { return nil }
        let cameraView = created.toCameraView()
        views.append(cameraView)
        return cameraView
    }

    /// Delete a view by id (owner or admin only, enforced server-side).
    /// Optimistically removes it from the local list on success.
    func deleteView(_ id: String) async {
        guard (try? await container.api.deleteView(id: id)) != nil else { return }
        views.removeAll { $0.id == id }
    }

    // MARK: - PTZ

    func ptzMove(cameraId: String, pan: Float, tilt: Float, zoom: Float = 0) async {
        _ = try? await container.api.ptz(cameraId: cameraId, body: PtzRequest(action: "move", pan: pan, tilt: tilt, zoom: zoom))
    }

    func ptzStop(cameraId: String) async {
        _ = try? await container.api.ptz(cameraId: cameraId, body: PtzRequest(action: "stop"))
    }

    func ptzHome(cameraId: String) async {
        _ = try? await container.api.ptz(cameraId: cameraId, body: PtzRequest(action: "home"))
    }

    /// Probe PTZ presets. Returns `nil` when the call fails (camera isn't PTZ /
    /// not reachable), an array (possibly empty) when it succeeds — so callers can
    /// tell "PTZ camera with no presets" apart from "not a PTZ camera".
    func ptzPresets(cameraId: String) async -> [PtzPresetDto]? {
        try? await container.api.ptz(cameraId: cameraId, body: PtzRequest(action: "presets")).presets
    }

    func ptzRecallPreset(cameraId: String, presetToken: String) async {
        _ = try? await container.api.ptz(
            cameraId: cameraId,
            body: PtzRequest(action: "preset", preset: presetToken)
        )
    }
}
