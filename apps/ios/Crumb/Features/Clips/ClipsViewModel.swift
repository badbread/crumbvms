// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

@MainActor
final class ClipsViewModel: ObservableObject {

    // MARK: - Published state

    @Published var clips: [ClipDescriptor] = []
    @Published var cameras: [CameraDto] = []
    @Published var isLoading = false
    @Published var error: String?
    /// Server-configured motion-highlight auto-zoom duration (0 = disabled).
    @Published var motionHighlightSeconds = 0

    /// nil = "All cameras"
    @Published var selectedCameraId: String?

    /// nil = all kinds; otherwise "motion" or "detection".
    @Published var selectedKind: String?

    /// When a saved **View** is active on the wall, the Clips feed is restricted to
    /// that view's cameras. nil = no active view (all cameras). Set by `ClipsView`
    /// from the wall's active view; `load()` and the filter chips honor it.
    var viewCameraIds: [String]?

    // MARK: - Time window

    /// Hours before now to load clips from (default last 24 h). Changing it reloads.
    @Published var windowHours: Double = 24

    // MARK: - Paging (server orders newest-first with offset 0, so "load more"
    // grows the limit rather than paging by offset).
    /// Total clips available in the window (from the server) — drives the count
    /// label + whether more can be loaded.
    @Published var total = 0
    /// How many clips to request; grows on "Load more" up to the server cap.
    @Published var loadLimit = 500
    private let maxLimit = 2000
    var canLoadMore: Bool { clips.count < total && loadLimit < maxLimit }

    func loadMore() {
        guard canLoadMore else { return }
        loadLimit = min(loadLimit + 500, maxLimit)
        Task { await load() }
    }

    // MARK: - Dependencies

    private let container: AppContainer

    // MARK: - Init

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: - Computed

    var mediaUrls: MediaUrls { container.mediaUrls() }

    /// Cameras offered as filter chips — narrowed to the active View when one is set.
    var chipCameras: [CameraDto] {
        guard let ids = viewCameraIds else { return cameras }
        let set = Set(ids)
        return cameras.filter { set.contains($0.id) }
    }

    /// Clips after the active-View restriction and then the selected camera chip.
    var filteredClips: [ClipDescriptor] {
        var list = clips
        if let ids = viewCameraIds {
            let set = Set(ids)
            list = list.filter { set.contains($0.cameraId) }
        }
        if let camId = selectedCameraId {
            list = list.filter { $0.cameraId == camId }
        }
        if let kind = selectedKind {
            list = list.filter { $0.kind == kind }
        }
        return list
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        error = nil
        do {
            // Load cameras list to populate filter chips (best-effort; skip on failure).
            if cameras.isEmpty {
                cameras = (try? await container.api.visibleCameras().filter(\.enabled)) ?? []
            }

            // Load every camera permitted by the active View (all cameras when no
            // view is active); the filter chips narrow the feed client-side (see
            // `filteredClips`). Loading only the selected camera meant a reload/retry
            // while a chip was active wiped the other cameras' clips.
            let ids = chipCameras.map(\.id).joined(separator: ",")
            guard !ids.isEmpty else { clips = []; isLoading = false; return }

            let end = Date()
            let start = Date(timeIntervalSinceNow: -windowHours * 3600)
            let response = try await container.api.clips(
                cameraIds: ids,
                start: iso8601String(start),
                end: iso8601String(end),
                limit: loadLimit
            )
            clips = response.clips
            total = response.total
            motionHighlightSeconds = response.motionHighlightSeconds
        } catch {
            self.error = error.userMessage
        }
        isLoading = false
    }

    func refresh() async {
        await load()
    }

    // MARK: - Mark viewed

    func markViewed(_ clip: ClipDescriptor) {
        // Optimistically flip the local flag so the unviewed dot disappears immediately.
        if let idx = clips.firstIndex(where: { $0.id == clip.id }) {
            clips[idx] = clips[idx].withViewed(true)
        }
        Task {
            try? await container.api.markClipViewed(id: clip.id)
        }
    }

    // MARK: - Camera filter

    func selectCamera(_ id: String?) {
        selectedCameraId = id
    }

    func selectKind(_ kind: String?) {
        selectedKind = kind
    }

    /// Change the lookback window and reload (the window is a server-side query bound).
    func setWindowHours(_ hours: Double) {
        guard hours != windowHours else { return }
        windowHours = hours
        loadLimit = 500 // new window → reset paging
        Task { await load() }
    }

    /// Apply the wall's active-View camera restriction. Drops a per-camera chip
    /// selection that's no longer part of the active view.
    func setViewFilter(_ ids: [String]?) {
        viewCameraIds = ids
        if let sel = selectedCameraId, let ids, !ids.contains(sel) {
            selectedCameraId = nil
        }
    }
}
