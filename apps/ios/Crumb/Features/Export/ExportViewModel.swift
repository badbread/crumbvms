// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Model

/// One clip in the export list (the desktop client's `exportState.list` item):
/// a camera + a time range. Output settings are global to the batch.
struct ExportClip: Identifiable, Equatable {
    let id: Int
    var cameraId: String
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// The add/edit-clip builder (the desktop client's `exportState.builder`).
/// Non-nil = builder mode; nil = list mode.
struct ExportBuilder: Equatable {
    /// Id of the clip being edited, nil for a new clip.
    var editId: Int? = nil
    var cameraId: String? = nil
    var start: Date
    var end: Date
    /// Validation error shown inside the builder.
    var error: String? = nil
    /// Preview-scrubber position as a 0…1 fraction of the clip range.
    var scrubFraction: Double = 0
    /// True while the preview auto-advances (the builder's play toggle).
    var playing: Bool = false
}

// MARK: - UI State

/// Snapshot of everything the Export view needs to render.
///
/// - `cameraError`: optional banner shown above the camera list (e.g. 403 partial access).
/// - `cameras`: full list passed in by the caller at init; the VM never fetches cameras.
/// - `clips`: the export list — the batch exports the whole list.
/// - `builder`: non-nil while the add/edit-clip builder is open.
/// - `burnTimestamp` / `format` / `includeAudio` / `password`: global output settings.
///   A non-empty password → AES-256-encrypted ZIP archive server-side.
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
    var clips: [ExportClip] = []
    var builder: ExportBuilder? = nil
    var burnTimestamp: Bool = true
    var format: ExportFormat = .mp4H264
    var includeAudio: Bool = false
    var password: String = ""
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
    /// Builder preview: still frame at the scrubber position for the builder's
    /// camera. Resolved async (scoped media token) — refreshed by
    /// `refreshPreview()`, which the view calls from a `.task(id:)` keyed on
    /// whatever inputs affect it (builder camera, range, scrub position).
    @Published private(set) var previewURL: URL?

    private let container: AppContainer
    private var pollTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    /// Id of the in-flight export job, used to cancel it server-side.
    private var currentJobId: String?
    /// Monotonic id source for list items.
    private var seq = 0
    /// Builder camera pre-selection when the caller had a camera focused
    /// (fullscreen playback / selected wall tile) — mirrors the desktop's
    /// `exportPopulateCameraSelect(selectedId)`.
    private let seedCameraId: String?

    /// - Parameters:
    ///   - container: App-wide service locator (API, MediaUrls).
    ///   - cameras: Full list of cameras the user may pick from.
    ///   - seedCameraId: Camera to pre-select in the add-clip builder (e.g. the
    ///     camera the user was viewing). nil → first camera.
    ///   - initialRange: When set (the playback "Export selection…" path), the
    ///     builder opens pre-filled with `seedCameraId` + this range, so it's
    ///     one click to add it as the first clip — the desktop `exportEnter`
    ///     behavior. nil (the Exports tab) → start in list mode.
    init(
        container: AppContainer,
        cameras: [CameraDto],
        seedCameraId: String? = nil,
        initialRange: (start: Date, end: Date)? = nil
    ) {
        self.container = container
        self.seedCameraId = seedCameraId
        var st = ExportUiState(cameras: cameras)
        if let range = initialRange {
            st.builder = ExportBuilder(
                cameraId: seedCameraId ?? cameras.first?.id,
                start: min(range.start, range.end.addingTimeInterval(-1)),
                end: range.end
            )
        }
        self.state = st
    }

    /// Media-URL builder, exposed for the clip-list thumbnails (each row mints
    /// its own short-lived scoped token, same as the desktop list).
    func mediaUrls() -> MediaUrls { container.mediaUrls() }

    // MARK: - Clip list

    func openBuilder(editing clip: ExportClip? = nil) {
        stopPlay()
        if let clip {
            state.builder = ExportBuilder(
                editId: clip.id, cameraId: clip.cameraId,
                start: clip.start, end: clip.end
            )
        } else {
            state.builder = ExportBuilder(
                cameraId: seedCameraId ?? state.clips.last?.cameraId ?? state.cameras.first?.id,
                start: Date(timeIntervalSinceNow: -60),
                end: Date()
            )
        }
    }

    func cancelBuilder() {
        stopPlay()
        state.builder = nil
    }

    /// Validate + commit the builder's clip into the list (add new or save an edit).
    func commitBuilder() {
        guard var b = state.builder else { return }
        guard let cam = b.cameraId, state.cameras.contains(where: { $0.id == cam }) else {
            b.error = "Pick a camera for this clip."
            state.builder = b
            return
        }
        guard b.end > b.start else {
            b.error = "End must be after start."
            state.builder = b
            return
        }
        if let editId = b.editId, let idx = state.clips.firstIndex(where: { $0.id == editId }) {
            state.clips[idx].cameraId = cam
            state.clips[idx].start = b.start
            state.clips[idx].end = b.end
        } else {
            seq += 1
            state.clips.append(ExportClip(id: seq, cameraId: cam, start: b.start, end: b.end))
        }
        // Output-setting/list changes after a completed export revert the job
        // panel so the button reads "Export N clips" again (desktop behavior).
        clearFinishedJob()
        stopPlay()
        state.builder = nil
    }

    func removeClip(_ id: Int) {
        state.clips.removeAll { $0.id == id }
        clearFinishedJob()
    }

    // MARK: - Builder fields

    func setBuilderCamera(_ id: String) {
        state.builder?.cameraId = id
        state.builder?.error = nil
    }

    func setBuilderStart(_ date: Date) {
        guard var b = state.builder else { return }
        // Clamp: start must be at least 1 second before end.
        b.start = min(date, b.end.addingTimeInterval(-1))
        b.error = nil
        state.builder = b
    }

    func setBuilderEnd(_ date: Date) {
        guard var b = state.builder else { return }
        // Clamp: end must be at least 1 second after start.
        b.end = max(date, b.start.addingTimeInterval(1))
        b.error = nil
        state.builder = b
    }

    // MARK: - Builder preview scrubber

    func setScrubFraction(_ f: Double) {
        stopPlay()
        state.builder?.scrubFraction = min(max(f, 0), 1)
    }

    /// The wall-clock moment the scrubber points at, or nil in list mode.
    var scrubDate: Date? {
        guard let b = state.builder else { return nil }
        return b.start.addingTimeInterval(b.scrubFraction * b.end.timeIntervalSince(b.start))
    }

    /// Toggle the preview auto-advance: steps the scrubber so a full play is
    /// ≤ ~24 frames (each step is one server-side frame extraction — the cap
    /// keeps a long clip from hammering the extractor; desktop parity).
    func togglePlay() {
        guard var b = state.builder else { return }
        if b.playing { stopPlay(); return }
        b.playing = true
        state.builder = b
        let span = b.end.timeIntervalSince(b.start)
        guard span > 0 else { stopPlay(); return }
        let step = max(1.0, span / 24) / span   // fraction per tick
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, var cur = self.state.builder, cur.playing else { return }
                let next = cur.scrubFraction + step
                if next >= 1 {
                    cur.scrubFraction = 1
                    cur.playing = false
                    self.state.builder = cur
                    return
                }
                cur.scrubFraction = next
                self.state.builder = cur
            }
        }
    }

    private func stopPlay() {
        playTask?.cancel()
        playTask = nil
        state.builder?.playing = false
    }

    /// Re-resolve `previewURL` — the builder's still frame at the scrubber
    /// position. Call from a `.task(id:)` keyed on the inputs that can change
    /// it (builder camera, range, scrub position); a short debounce plus
    /// cancellation keeps a fast scrub from racing in stale frames or minting
    /// a token per tick.
    func refreshPreview() {
        previewTask?.cancel()
        guard let b = state.builder, let camId = b.cameraId, let at = scrubDate else {
            previewURL = nil
            return
        }
        let iso = iso8601String(at)
        previewTask = Task { [weak self] in
            guard let self else { return }
            // Debounce continuous scrubs (each frame is a server-side extraction).
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            // Builder-preview width matches the desktop scrubber's 480px request
            // (crisp at panel size without paying for the 640px cap per tick).
            let url = await container.mediaUrls().historicalFrameUrl(cameraId: camId, tsISO: iso, width: 480)
            guard !Task.isCancelled else { return }
            previewURL = url
        }
    }

    // MARK: - Output settings

    func setBurnTimestamp(_ value: Bool) {
        state.burnTimestamp = value
        clearFinishedJob()
    }

    func setFormat(_ value: ExportFormat) {
        state.format = value
        clearFinishedJob()
    }

    func setIncludeAudio(_ value: Bool) {
        state.includeAudio = value
        clearFinishedJob()
    }

    func setPassword(_ value: String) {
        state.password = value
        clearFinishedJob()
    }

    /// Any list/output change after a completed run clears the finished-job
    /// panel so the view reverts to a fresh "Export N clips" state.
    private func clearFinishedJob() {
        guard let job = state.job, job.isTerminal else { return }
        state.job = nil
        state.jobError = nil
        currentJobId = nil
    }

    // MARK: - Batch summary

    var clipCount: Int { state.clips.count }

    var distinctCameraCount: Int { Set(state.clips.map(\.cameraId)).count }

    var totalDuration: TimeInterval { state.clips.reduce(0) { $0 + max(0, $1.duration) } }

    /// Rough size estimate (heuristic ~4 Mbps main stream), scaled by codec:
    /// H.265 re-encodes to roughly half the bitrate; copy/H.264 keep the source
    /// rate. Always labelled "~" by the view. Mirrors the desktop `exportEstSize`.
    var estimatedSizeBytes: Int64 {
        let factor = state.format.videoCodec == "h265" ? 0.5 : 1.0
        return Int64(totalDuration * 500_000 * factor) // 4 Mbps ≈ 500 KB/s
    }

    // MARK: - Export job

    var canExport: Bool {
        !state.clips.isEmpty && !state.polling
    }

    func createExport() {
        guard canExport else { return }

        let items = state.clips.map {
            BatchExportItem(
                cameraId: $0.cameraId,
                start: iso8601String($0.start),
                end: iso8601String($0.end)
            )
        }

        // Reset any previous job state.
        state.job = nil
        state.jobError = nil
        state.shareItems = nil

        Task {
            do {
                let response = try await container.api.createBatchExport(
                    CreateBatchExportRequest(
                        items: items,
                        burnTimestamp: state.burnTimestamp,
                        includeAudio: state.includeAudio,
                        videoCodec: state.format.videoCodec,
                        container: state.format.container,
                        password: state.password.isEmpty ? nil : state.password
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
        stopPlay()
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
