// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - UI State

/// Snapshot of everything the Export sheet needs to render.
///
/// - `cameraError`: optional banner shown above the camera list (e.g. 403 partial access).
/// - `cameras`: full list passed in by the caller at init; the VM never fetches cameras.
/// - `selectedCameraIds`: set of camera IDs the user has toggled on.
/// - `start` / `end`: current DatePicker values (clamped so start < end).
/// - `burnTimestamp`: overlay date/time on the exported video.
/// - `job`: most-recent ExportJob polled from the server (nil until first response).
/// - `jobError`: human-readable error from a failed job or a polling network blip.
/// - `polling`: true while we are actively polling exportStatus.
/// - `shareItems`: non-nil when the native Share sheet should be presented. These
///   are always LOCAL file URLs (see C1/C2) — never the remote `?token=` URL.
/// - `downloadingFileId`: the `cameraId` of the output file currently being
///   downloaded for share, so its row can show a spinner instead of double-firing.
/// - `downloadError`: surfaced when a share/download fetch fails.
struct ExportUiState {
    var cameraError: String? = nil
    var cameras: [CameraDto] = []
    var selectedCameraIds: Set<String> = []
    var start: Date = Date(timeIntervalSinceNow: -600)
    var end: Date = Date()
    var burnTimestamp: Bool = true
    var format: ExportFormat = .mp4H264
    var includeAudio: Bool = false
    var job: ExportJob? = nil
    var jobError: String? = nil
    var polling: Bool = false
    var shareItems: [URL]? = nil
    var downloadingFileId: String? = nil
    var downloadError: String? = nil
}

// MARK: - ViewModel

@MainActor
final class ExportViewModel: ObservableObject {

    @Published var state: ExportUiState
    /// Still-frame preview at the clip start for the first selected (or first
    /// available) camera. Resolved async (scoped media token) — refreshed by
    /// `refreshPreview()`, which the view calls from a `.task(id:)` keyed on
    /// whatever inputs affect it (selected cameras, start date).
    @Published private(set) var previewURL: URL?

    private let container: AppContainer
    private var pollTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Id of the in-flight export job, used to cancel it server-side.
    private var currentJobId: String?

    /// - Parameters:
    ///   - container: App-wide service locator (API, MediaUrls).
    ///   - cameras: Full list of cameras the user may pick from.
    ///   - cameraIds: Pre-selected IDs (e.g. the camera the user was viewing).
    ///   - start: Pre-filled clip start time.
    ///   - end: Pre-filled clip end time.
    init(
        container: AppContainer,
        cameras: [CameraDto],
        cameraIds: [String],
        start: Date,
        end: Date
    ) {
        self.container = container
        self.state = ExportUiState(
            cameras: cameras,
            selectedCameraIds: Set(cameraIds),
            start: start,
            end: end
        )
    }

    // MARK: - Camera selection

    func toggleCamera(_ id: String) {
        if state.selectedCameraIds.contains(id) {
            state.selectedCameraIds.remove(id)
        } else {
            state.selectedCameraIds.insert(id)
        }
    }

    // MARK: - Date/time

    func setStart(_ date: Date) {
        // Clamp: start must be at least 1 second before end.
        state.start = min(date, state.end.addingTimeInterval(-1))
    }

    func setEnd(_ date: Date) {
        // Clamp: end must be at least 1 second after start.
        state.end = max(date, state.start.addingTimeInterval(1))
    }

    func setBurnTimestamp(_ value: Bool) {
        state.burnTimestamp = value
    }

    func setFormat(_ value: ExportFormat) {
        state.format = value
    }

    func setIncludeAudio(_ value: Bool) {
        state.includeAudio = value
    }

    /// Re-resolve `previewURL` (a still frame at the clip start for the first
    /// selected, or first available, camera) — the export preview thumbnail.
    /// Call from a `.task(id:)` keyed on the inputs that can change it
    /// (selected camera set, start date); cancels any still-resolving prior
    /// request so a rapid camera-toggle or date-drag doesn't race in a stale
    /// URL after a newer one.
    func refreshPreview() {
        previewTask?.cancel()
        guard let camId = state.selectedCameraIds.sorted().first ?? state.cameras.first?.id else {
            previewURL = nil
            return
        }
        let iso = ISO8601DateFormatter().string(from: state.start)
        previewTask = Task { [weak self] in
            guard let self else { return }
            // Request the server's max thumbnail width (640): the preview renders
            // large, so the default ~160px still would look blurry blown up.
            let url = await container.mediaUrls().historicalFrameUrl(cameraId: camId, tsISO: iso, width: 640)
            guard !Task.isCancelled else { return }
            previewURL = url
        }
    }

    // MARK: - Export job

    var canExport: Bool {
        !state.selectedCameraIds.isEmpty && !state.polling
    }

    func createExport() {
        guard canExport else { return }

        let fmt = ISO8601DateFormatter()
        let startIso = fmt.string(from: state.start)
        let endIso = fmt.string(from: state.end)
        let cameraIds = Array(state.selectedCameraIds)

        // Reset any previous job state.
        state.job = nil
        state.jobError = nil
        state.shareItems = nil

        Task {
            do {
                let response = try await container.api.createExport(
                    CreateExportRequest(
                        cameraIds: cameraIds,
                        start: startIso,
                        end: endIso,
                        burnTimestamp: state.burnTimestamp,
                        videoCodec: state.format.videoCodec,
                        container: state.format.container,
                        includeAudio: state.includeAudio
                    )
                )
                currentJobId = response.jobId
                state.polling = true
                startPolling(jobId: response.jobId)
            } catch {
                state.jobError = error.userMessage
            }
        }
    }

    /// Cancel the current job: fire `DELETE /export/{id}` (the server interrupts
    /// ffmpeg and marks it Cancelled), then halt polling and clear the progress UI.
    func cancelExport() {
        let jobId = currentJobId ?? state.job?.id
        stopPolling()
        state.polling = false
        state.job = nil
        state.jobError = nil
        currentJobId = nil
        if let jobId {
            Task { try? await container.api.cancelExport(jobId: jobId) }
        }
    }

    // MARK: - Polling

    private func startPolling(jobId: String) {
        stopPolling()
        pollTask = Task {
            var failStreak = 0
            while !Task.isCancelled {
                // Back off on consecutive failures: 1.5 s → 3 s → 6 s → 12 s max.
                let delayMs = (Self.pollIntervalMs << min(failStreak, 3))
                    .clamped(to: 0...12_000)
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)

                guard !Task.isCancelled else { break }

                do {
                    let job = try await container.api.exportStatus(jobId: jobId)
                    failStreak = 0
                    state.job = job
                    state.jobError = nil   // Clear any transient network blip message.

                    if job.isTerminal {
                        state.polling = false
                        if job.isFailed {
                            state.jobError = job.error ?? "Export failed."
                        }
                        // [iOS/macOS] C1/C2 fix: no longer auto-populate `shareItems`
                        // with remote `?token=`-bearing URLs here. Each output file's
                        // "Share / Download" button now drives an authenticated
                        // download to a local temp file (see `shareFile(_:)` below);
                        // the "Ready to download" file list (ExportView.jobSection)
                        // already renders once `job.isDone`.
                        break
                    }
                } catch {
                    failStreak += 1
                    // Surface only after a few consecutive failures to avoid crying wolf
                    // on a single dropped packet.
                    if failStreak >= 3 {
                        state.jobError = error.userMessage
                    }
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Share sheet helpers

    /// Clears the share items after the share sheet has been dismissed.
    func clearShareItems() {
        state.shareItems = nil
    }

    /// [iOS] C1 fix: download an export output file to a local temp file via an
    /// AUTHENTICATED request (`URLSession.crumbMedia`, token in the URL query —
    /// same server-side auth scheme as every other media endpoint, but the fetch
    /// itself never lands in the on-disk URL cache), then hand `UIActivityViewController`
    /// the local `fileURL`. Previously the raw `?token=<JWT>` URL was handed
    /// straight to the share sheet, which could leak the token to whatever
    /// destination (Mail, Messages, a third-party app, iCloud Drive, AirDrop...)
    /// the user picked, since UIActivityViewController may re-fetch/re-upload the
    /// URL itself rather than treating it as an opaque local file.
    func shareFile(_ file: ExportOutputFile) async {
        guard state.downloadingFileId == nil else { return }
        state.downloadError = nil
        state.downloadingFileId = file.cameraId
        defer { state.downloadingFileId = nil }

        do {
            let localURL = try await downloadToTemp(file)
            state.shareItems = [localURL]
        } catch {
            state.downloadError = error.userMessage
        }
    }

    /// Downloads one output file to a fresh temp file, returning its local URL.
    /// Shared by C1 (iOS share sheet) and C2 (macOS save-panel) call sites.
    func downloadToTemp(_ file: ExportOutputFile) async throws -> URL {
        guard let remote = container.mediaUrls().authed(file.downloadUrl) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: remote)
        req.timeoutInterval = 300   // exports can be large; give the download room
        let (data, response) = try await URLSession.crumbMedia.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crumb-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let localURL = dir.appendingPathComponent(suggestedFilename(for: file))
        try data.write(to: localURL, options: .atomic)
        return localURL
    }

    /// Best-effort filename: the server's download-url last path component (which
    /// already carries the right extension), falling back to a generated name.
    func suggestedFilename(for file: ExportOutputFile) -> String {
        let last = (file.downloadUrl as NSString).lastPathComponent
        if !last.isEmpty, last.contains(".") { return last }
        let ext = state.format.container
        return "\(cameraName(for: file.cameraId))-export.\(ext)"
    }

    private func cameraName(for cameraId: String) -> String {
        if cameraId == "00000000-0000-0000-0000-000000000000" { return "archive" }
        return state.cameras.first(where: { $0.id == cameraId })?.name ?? cameraId
    }

    // MARK: - Cleanup

    func onDisappear() {
        stopPolling()
    }

    // MARK: - Constants

    private static let pollIntervalMs = 1_500
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(self, range.upperBound))
    }
}
