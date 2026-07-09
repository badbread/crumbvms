// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Sheet entry point

/// Export view, mirroring the desktop client's batch-list flow: the operator
/// builds a LIST of clips (camera + range each, "+ Add to list"), sets global
/// output options (format, burn-in, audio, optional AES-256 ZIP password), then
/// runs the whole batch as one job and watches it to completion. On success each
/// output file offers a native Share (iOS) / Save (macOS) action.
///
/// Present as `.sheet(isPresented:)` from playback, or embed (the macOS
/// Exports tab).
struct ExportView: View {

    @StateObject private var vm: ExportViewModel
    private let onClose: () -> Void

    /// - Parameters:
    ///   - container: App-wide service locator.
    ///   - cameras: Full list of cameras the user may pick from.
    ///   - seedCameraId: Camera to pre-select in the add-clip builder (the
    ///     camera the user was viewing), nil for no preference.
    ///   - initialRange: Non-nil (playback "Export selection…" path) opens the
    ///     builder pre-filled with this range so it's one click to add the
    ///     first clip. nil (Exports tab) starts in list mode.
    ///   - onClose: Called when the user taps Close.
    init(
        container: AppContainer,
        cameras: [CameraDto],
        seedCameraId: String? = nil,
        initialRange: (start: Date, end: Date)? = nil,
        onClose: @escaping () -> Void
    ) {
        _vm = StateObject(wrappedValue: ExportViewModel(
            container: container,
            cameras: cameras,
            seedCameraId: seedCameraId,
            initialRange: initialRange
        ))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CrumbColors.background.ignoresSafeArea()

                GeometryReader { geo in
                    // Wide (macOS Exports tab) → desktop 2-column builder; narrow
                    // (iOS sheet / macOS playback-export sheet) → single column.
                    if geo.size.width >= 760 {
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView { leftColumn.padding(20) }
                                .frame(maxWidth: .infinity)
                            Rectangle().fill(CrumbColors.divider).frame(width: 1)
                            ScrollView { rightColumn.padding(20) }
                                .frame(width: 380)
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                leftColumn
                                Rectangle().fill(CrumbColors.divider).frame(height: 1)
                                rightColumn
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .navigationTitle("Export")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button("Close") { onClose() }
                        .foregroundColor(CrumbColors.tealAccent)
                }
            }
            .onDisappear { vm.onDisappear() }
            #if os(iOS)
            // [iOS] C1 fix: the share sheet now only ever receives a local
            // `fileURL` (downloaded authenticated in `vm.shareFile`), never the
            // remote tokened URL.
            .sheet(isPresented: shareSheetBinding) {
                if let items = vm.state.shareItems {
                    ShareSheet(activityItems: items)
                }
            }
            #endif
        }
    }

    // MARK: - Columns

    /// Left builder column: what to export — the clip list, or the add/edit-clip
    /// builder while it's open (desktop list mode ⇄ builder mode).
    @ViewBuilder
    private var leftColumn: some View {
        if vm.state.builder != nil {
            builderSection
        } else {
            listSection
        }
    }

    /// Right output column: how to export + run it.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            formatSection
            optionsSection
            summarySection
            exportButton
            jobSection
        }
    }

    // MARK: - Section: Export list

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(vm.clipCount > 0 ? "Export list (\(vm.clipCount))" : "Export list")
                Spacer()
                Button {
                    vm.openBuilder()
                } label: {
                    Label("Add clip", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(CrumbColors.tealAccent)
                .disabled(vm.state.polling)
            }

            if let err = vm.state.cameraError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(CrumbColors.error)
            }

            if vm.state.clips.isEmpty {
                SurfaceCard {
                    VStack(spacing: 6) {
                        Text("No clips yet.")
                            .font(.subheadline)
                            .foregroundColor(CrumbColors.textSecondary)
                        Text("Add a camera + time range to build your export.")
                            .font(.caption)
                            .foregroundColor(CrumbColors.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                ForEach(Array(vm.state.clips.enumerated()), id: \.element.id) { index, clip in
                    ClipRow(
                        index: index + 1,
                        clip: clip,
                        cameraName: cameraName(for: clip.cameraId),
                        thumbURL: { [weak vm] in
                            await vm?.mediaUrls().historicalFrameUrl(
                                cameraId: clip.cameraId,
                                tsISO: iso8601String(clip.start),
                                width: 160
                            )
                        },
                        onEdit: { vm.openBuilder(editing: clip) },
                        onRemove: { vm.removeClip(clip.id) }
                    )
                    .disabled(vm.state.polling)
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Section: Add/edit-clip builder

    @ViewBuilder
    private var builderSection: some View {
        if let b = vm.state.builder {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(b.editId != nil ? "Edit clip" : "Add clip")

                // Camera
                SurfaceCard {
                    HStack {
                        Text("Camera")
                            .font(.body)
                            .foregroundColor(CrumbColors.textPrimary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { b.cameraId ?? "" },
                            set: { vm.setBuilderCamera($0) }
                        )) {
                            ForEach(vm.state.cameras) { cam in
                                Text(cam.name).tag(cam.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(CrumbColors.textPrimary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                // Range
                SurfaceCard {
                    DatePicker(
                        "Start",
                        selection: Binding(get: { b.start }, set: { vm.setBuilderStart($0) }),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .foregroundColor(CrumbColors.textPrimary)
                    .tint(CrumbColors.tealAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                SurfaceCard {
                    DatePicker(
                        "End",
                        selection: Binding(get: { b.end }, set: { vm.setBuilderEnd($0) }),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .foregroundColor(CrumbColors.textPrimary)
                    .tint(CrumbColors.tealAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Text("Duration: \(formatDuration(b.end.timeIntervalSince(b.start)))")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)

                previewSection(b)

                if let err = b.error {
                    Text(err)
                        .font(.subheadline)
                        .foregroundColor(CrumbColors.error)
                }

                HStack(spacing: 10) {
                    Button {
                        vm.cancelBuilder()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(CrumbColors.surfaceVariant, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundColor(CrumbColors.textPrimary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        vm.commitBuilder()
                    } label: {
                        Text(b.editId != nil ? "Save changes" : "+ Add to list")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(CrumbColors.teal, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// Frame-accurate review before adding: a still at the scrubber position,
    /// a play toggle (auto-advance, extraction-capped) and a scrub slider —
    /// the desktop builder's preview scrubber.
    private func previewSection(_ b: ExportBuilder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let url = vm.previewURL {
                    // [both] H2 fix: `url` carries the auth token as a `?token=` query
                    // param. SwiftUI's `AsyncImage` has no custom-URLSession init and
                    // always uses `URLSession.shared`, whose disk URL cache would
                    // persist the tokened URL (and thus the token) to disk.
                    // `TokenedAsyncImage` (MediaSession.swift) fetches via the
                    // ephemeral `.crumbMedia` session instead — in-memory only.
                    //
                    // keepStaleImage: the URL changes on every scrub/play tick;
                    // the previous frame must stay up while the next one loads
                    // (blanking per tick = a black flash per frame).
                    TokenedAsyncImage(url: url, keepStaleImage: true) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().tint(CrumbColors.tealAccent)
                    } failure: {
                        previewPlaceholder("No footage at this moment")
                    }
                } else {
                    previewPlaceholder("Pick a camera to preview")
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            // Cap the height so a wide window doesn't blow the preview up to fill
            // the whole column and push the range controls below the fold.
            .frame(maxWidth: .infinity, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Scoped media token (P0-SESSIONS): the preview URL is minted async,
            // so it's refreshed reactively rather than computed inline in `body`.
            // Keyed on every input that changes which still to show.
            .task(id: PreviewKey(cameraId: b.cameraId, start: b.start, end: b.end, fraction: b.scrubFraction)) {
                vm.refreshPreview()
            }

            HStack(spacing: 10) {
                Button {
                    vm.togglePlay()
                } label: {
                    Image(systemName: b.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(CrumbColors.teal)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(b.playing ? "Pause preview" : "Play preview")

                Slider(value: Binding(
                    get: { b.scrubFraction },
                    set: { vm.setScrubFraction($0) }
                ), in: 0...1)
                .tint(CrumbColors.tealAccent)

                Text(scrubReadout(b))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(CrumbColors.textSecondary)
                    .frame(minWidth: 96, alignment: .trailing)
            }
        }
    }

    private func previewPlaceholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo").font(.title2).foregroundColor(CrumbColors.textTertiary)
            Text(text).font(.caption).foregroundColor(CrumbColors.textTertiary)
        }
    }

    /// "+M:SS / 7m 19s" — offset into the clip at the scrubber, over the total.
    private func scrubReadout(_ b: ExportBuilder) -> String {
        let span = max(0, b.end.timeIntervalSince(b.start))
        let off = Int((span * b.scrubFraction).rounded())
        return String(format: "+%d:%02d / %@", off / 60, off % 60, formatDuration(span))
    }

    /// `.task(id:)` identity for `vm.refreshPreview()`.
    private struct PreviewKey: Equatable {
        let cameraId: String?
        let start: Date
        let end: Date
        let fraction: Double
    }

    // MARK: - Section: Format

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Format")
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    // Menu-style picker with an explicit control chrome (filled +
                    // bordered + chevron) so it reads as a real dropdown. The plain
                    // picker rendered like a static "MP4 · H.264" caption, so the
                    // other four formats went unnoticed.
                    Picker("", selection: Binding(
                        get: { vm.state.format },
                        set: { vm.setFormat($0) }
                    )) {
                        ForEach(ExportFormat.allCases) { fmt in
                            Text(fmt.label).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(CrumbColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CrumbColors.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(CrumbColors.divider, lineWidth: 1)
                    )
                    .disabled(vm.state.polling)

                    Text(vm.state.format.detail)
                        .font(.caption)
                        .foregroundColor(CrumbColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if vm.state.format.videoCodec == "h265" {
                        Text("H.265 (HEVC) re-encodes the video — noticeably slower to export.")
                            .font(.caption)
                            .foregroundColor(CrumbColors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Section: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Options")

            SurfaceCard {
                VStack(spacing: 0) {
                    optionToggle(
                        "Burn timestamp",
                        "Overlay date/time on the exported video.",
                        get: { vm.state.burnTimestamp },
                        set: { vm.setBurnTimestamp($0) }
                    )
                    Divider().background(CrumbColors.divider).padding(.horizontal, 16)
                    optionToggle(
                        "Include audio",
                        "Keep the camera's audio track in the export.",
                        get: { vm.state.includeAudio },
                        set: { vm.setIncludeAudio($0) }
                    )
                    Divider().background(CrumbColors.divider).padding(.horizontal, 16)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Encryption password")
                            .font(.body)
                            .foregroundColor(CrumbColors.textPrimary)
                        SecureField("Optional", text: Binding(
                            get: { vm.state.password },
                            set: { vm.setPassword($0) }
                        ))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(CrumbColors.surfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(vm.state.polling)
                        Text("When set, the outputs are bundled into an AES-256 encrypted ZIP.")
                            .font(.caption)
                            .foregroundColor(CrumbColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func optionToggle(_ title: String, _ description: String,
                              get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(CrumbColors.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: get, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(CrumbColors.positive)
                .disabled(vm.state.polling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Section: Batch summary

    /// Live batch summary — clip count, distinct cameras, total duration, rough
    /// size estimate. Mirrors the desktop Output panel's "Batch" block.
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Batch")
            SurfaceCard {
                VStack(spacing: 0) {
                    summaryRow("Clips", vm.clipCount > 0 ? "\(vm.clipCount)" : "—")
                    Divider().background(CrumbColors.divider).padding(.horizontal, 16)
                    summaryRow("Cameras", vm.clipCount > 0 ? "\(vm.distinctCameraCount)" : "—")
                    Divider().background(CrumbColors.divider).padding(.horizontal, 16)
                    summaryRow("Duration", vm.clipCount > 0 ? formatDuration(vm.totalDuration) : "—")
                    Divider().background(CrumbColors.divider).padding(.horizontal, 16)
                    summaryRow("Est. size", vm.clipCount > 0 ? "~" + formatFileSize(vm.estimatedSizeBytes) : "—")
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(CrumbColors.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundColor(CrumbColors.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: - Export button

    private var exportButton: some View {
        Button(action: { vm.createExport() }) {
            HStack {
                if vm.state.polling {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                        .padding(.trailing, 4)
                }
                Text(exportButtonLabel)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(vm.canExport ? CrumbColors.teal : CrumbColors.surfaceVariant)
            .foregroundColor(vm.canExport ? .white : CrumbColors.textTertiary)
            .cornerRadius(10)
        }
        .disabled(!vm.canExport)
        .padding(.bottom, 16)
    }

    private var exportButtonLabel: String {
        if vm.state.polling { return "Exporting…" }
        let n = vm.clipCount
        return n > 0 ? "Export \(n) clip\(n == 1 ? "" : "s")" : "Export"
    }

    // MARK: - Section: Job Status

    @ViewBuilder
    private var jobSection: some View {
        let s = vm.state
        if s.polling || s.job != nil || s.jobError != nil {
            VStack(alignment: .leading, spacing: 12) {
                divider
                SectionHeader("Job Status")
                    .padding(.top, 4)

                // Progress bar (while polling or non-terminal)
                if s.polling || (s.job != nil && !(s.job?.isTerminal ?? true)) {
                    jobProgressView

                    Button(role: .destructive) { vm.cancelExport() } label: {
                        Text("Cancel export")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(CrumbColors.error.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundColor(CrumbColors.error)
                    }
                    .buttonStyle(.plain)
                }

                // Error message
                if let err = s.jobError {
                    Text(err)
                        .font(.subheadline)
                        .foregroundColor(CrumbColors.error)
                }

                // Output files when done
                if let job = s.job, job.isDone, !job.outputFiles.isEmpty {
                    Text("Ready to download")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(CrumbColors.textPrimary)

                    // [both] C1/C2 fix: download errors (auth/network) surface here
                    // rather than failing silently.
                    if let err = s.downloadError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(CrumbColors.error)
                    }

                    // Keyed on downloadUrl: a batch job's files aren't guaranteed
                    // unique per camera (the whole-job archive uses a nil camera).
                    ForEach(job.outputFiles, id: \.downloadUrl) { file in
                        OutputFileRow(
                            title: cameraName(for: file.cameraId),
                            outputFile: file,
                            isDownloading: s.downloadingFileId == file.cameraId,
                            onShare: {
                                #if os(iOS)
                                // [iOS] C1 fix: download authenticated, then hand the
                                // Share sheet a local file — never the tokened URL.
                                Task { await vm.shareFile(file) }
                                #else
                                // [macOS] C2 fix: download authenticated to a
                                // user-chosen location via NSSavePanel. The old
                                // `NSWorkspace.activateFileViewerSelecting` on a
                                // remote http(s) URL was a no-op — nothing ever
                                // downloaded.
                                Task { await saveToUserLocation(file) }
                                #endif
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 32)
        }
    }

    private var jobProgressView: some View {
        let job = vm.state.job
        let progress = job.map { Double($0.progressPct) / 100.0 }

        return VStack(spacing: 6) {
            HStack {
                Text(jobStatusLabel(job))
                    .font(.subheadline)
                    .foregroundColor(CrumbColors.textPrimary)
                Spacer()
                Text(job.map { "\($0.progressPct)%" } ?? "—")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(CrumbColors.textSecondary)
            }

            if let pct = progress {
                ProgressView(value: pct)
                    .tint(CrumbColors.tealAccent)
                    .background(CrumbColors.surfaceVariant)
                    .cornerRadius(2)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(CrumbColors.tealAccent)
            }
        }
    }

    // MARK: - Helpers

    private var divider: some View {
        Divider()
            .background(CrumbColors.divider)
            .padding(.bottom, 16)
    }

    #if os(iOS)
    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { vm.state.shareItems != nil },
            set: { if !$0 { vm.clearShareItems() } }
        )
    }
    #endif

    /// Friendly name for an output file's camera id (or the archive sentinel).
    private func cameraName(for cameraId: String) -> String {
        if cameraId == "00000000-0000-0000-0000-000000000000" { return "Archive (all clips)" }
        return vm.state.cameras.first(where: { $0.id == cameraId })?.name ?? cameraId
    }

    #if os(macOS)
    /// [macOS] C2 fix: download the output file authenticated (via
    /// `vm.downloadToTemp`, same code path as C1's iOS share flow), then present
    /// `NSSavePanel` so the user picks the destination, then move the temp file
    /// there. Replaces the old `NSWorkspace.activateFileViewerSelecting` call,
    /// which was handed a remote `http(s)://...?token=` URL and was a silent
    /// no-op — nothing was ever fetched or revealed.
    private func saveToUserLocation(_ file: ExportOutputFile) async {
        guard vm.state.downloadingFileId == nil else { return }
        vm.state.downloadError = nil
        vm.state.downloadingFileId = file.cameraId
        defer { vm.state.downloadingFileId = nil }

        do {
            let tempURL = try await vm.downloadToTemp(file)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = tempURL.lastPathComponent
            panel.canCreateDirectories = true
            let response = await MainActor.run { panel.runModal() }
            guard response == .OK, let destination = panel.url else { return }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: tempURL, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            vm.state.downloadError = error.userMessage
        }
    }
    #endif
}

// MARK: - Sub-views

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundColor(CrumbColors.textPrimary)
    }
}

private struct SurfaceCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(CrumbColors.surface)
            .cornerRadius(10)
    }
}

/// One clip card in the export list: index, start-frame thumbnail, camera,
/// range, duration, edit/remove. The thumbnail URL is minted per-row (a
/// short-lived per-camera scoped media token, never the full login JWT).
private struct ClipRow: View {
    let index: Int
    let clip: ExportClip
    let cameraName: String
    let thumbURL: () async -> URL?
    let onEdit: () -> Void
    let onRemove: () -> Void

    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundColor(CrumbColors.textTertiary)
                .frame(width: 18)

            ZStack {
                Color.black
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                } else if failed {
                    // Distinguish a genuinely-failed extraction from a dark night
                    // frame — a silent black tile reads as "broken" either way.
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 12))
                        .foregroundColor(CrumbColors.textTertiary)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .tint(CrumbColors.textTertiary)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(cameraName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(CrumbColors.textPrimary)
                    .lineLimit(1)
                Text("\(clipClock(clip.start)) → \(clipClock(clip.end))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(CrumbColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatDuration(clip.duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(CrumbColors.textSecondary)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundColor(CrumbColors.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Edit clip")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(CrumbColors.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Remove clip")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CrumbColors.surface)
        .cornerRadius(10)
        .task(id: clip) { await loadThumb() }
    }

    /// Load the clip's start-frame thumbnail, retrying transient failures.
    /// The clip-start still is an ON-DEMAND server extraction (not a pre-cached
    /// clip thumbnail), and the frame endpoint drops some requests when several
    /// rows fetch at once — a single silent fetch left the tile permanently
    /// black. Mirrors the proven retry loop in `ClipThumbnail` (ClipsView).
    private func loadThumb() async {
        failed = false
        image = nil
        for attempt in 0..<4 {
            if Task.isCancelled { return }
            guard let url = await thumbURL() else {
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 600_000_000)
                continue
            }
            var req = URLRequest(url: url)
            req.cachePolicy = .returnCacheDataElseLoad
            req.timeoutInterval = 12
            if let (data, resp) = try? await URLSession.crumbMedia.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let img = PlatformImage(data: data) {
                image = img
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 600_000_000)
        }
        if !Task.isCancelled { failed = true }
    }

    /// Wall-clock "MM/dd HH:mm:ss" for a clip edge (desktop `exportFmtClock`).
    private func clipClock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f.string(from: d)
    }
}

private struct OutputFileRow: View {
    let title: String
    let outputFile: ExportOutputFile
    /// True while this file's authenticated download is in flight (C1/C2).
    var isDownloading: Bool = false
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(CrumbColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(formatFileSize(outputFile.sizeBytes))
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
            }

            Button(action: onShare) {
                HStack {
                    if isDownloading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(CrumbColors.tealAccent)
                            .scaleEffect(0.8)
                    } else {
                        Label("Share / Download", systemImage: "square.and.arrow.up")
                    }
                }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(CrumbColors.teal.opacity(0.2))
                    .foregroundColor(CrumbColors.tealAccent)
                    .cornerRadius(8)
            }
            .disabled(isDownloading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CrumbColors.surface)
        .cornerRadius(10)
    }
}

// MARK: - Share sheet bridge

#if os(iOS)
import UIKit
/// Wraps UIActivityViewController for use in SwiftUI. [iOS] C1 fix: the caller
/// (`ExportView.jobSection`) now only ever passes a LOCAL `fileURL` here (see
/// `ExportViewModel.shareFile`) — never the remote `?token=`-bearing URL, which
/// would otherwise be re-fetched/re-uploaded by whatever share destination the
/// user picks, leaking the auth token.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
// macOS has no share-sheet-in-a-sheet. [macOS] C2 fix: rather than a
// "Reveal in Finder" button that operated on a remote (never-downloaded) URL,
// the "Share / Download" action now drives `ExportView.saveToUserLocation`
// directly (authenticated download → NSSavePanel → reveal in Finder), so there
// is no intermediate sheet state to model here anymore.

// MARK: - Formatting helpers

private func formatFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func jobStatusLabel(_ job: ExportJob?) -> String {
    guard let job else { return "Queuing export…" }
    if job.isDone { return "Done" }
    if job.isFailed { return "Failed" }
    if job.status.caseInsensitiveCompare("running") == .orderedSame { return "Processing…" }
    return "Queued…"
}
