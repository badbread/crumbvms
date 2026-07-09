// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Sheet entry point

/// Export sheet: operator picks cameras, adjusts the clip window, toggles burn-in,
/// taps Export, then watches the job progress to completion. On success the iOS
/// native Share sheet presents the authenticated download URL(s).
///
/// Present this as `.sheet(isPresented:)` from a parent view.
struct ExportView: View {

    @StateObject private var vm: ExportViewModel
    private let onClose: () -> Void

    /// - Parameters:
    ///   - container: App-wide service locator.
    ///   - cameras: Full list of cameras the user may pick from.
    ///   - cameraIds: Pre-selected camera IDs.
    ///   - start: Pre-filled clip start.
    ///   - end: Pre-filled clip end.
    ///   - onClose: Called when the user taps Cancel / Done.
    init(
        container: AppContainer,
        cameras: [CameraDto],
        cameraIds: [String],
        start: Date,
        end: Date,
        onClose: @escaping () -> Void
    ) {
        _vm = StateObject(wrappedValue: ExportViewModel(
            container: container,
            cameras: cameras,
            cameraIds: cameraIds,
            start: start,
            end: end
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

    /// Left builder column: what to export.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            previewSection
            cameraSection
            timeRangeSection
        }
    }

    /// Right output column: how to export + run it.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            formatSection
            optionsSection
            exportButton
            jobSection
        }
    }

    // MARK: - Section: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Preview")
            ZStack {
                Color.black
                if let url = vm.previewURL {
                    // [both] H2 fix: `url` carries the auth token as a `?token=` query
                    // param. SwiftUI's `AsyncImage` has no custom-URLSession init and
                    // always uses `URLSession.shared`, whose disk URL cache would
                    // persist the tokened URL (and thus the token) to disk.
                    // `TokenedAsyncImage` (MediaSession.swift) fetches via the
                    // ephemeral `.crumbMedia` session instead — in-memory only.
                    TokenedAsyncImage(url: url) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().tint(CrumbColors.tealAccent)
                    } failure: {
                        previewPlaceholder("Preview unavailable")
                    }
                    .id(url)   // reload when camera/start changes
                } else {
                    previewPlaceholder("Select a camera to preview")
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            // Cap the height so a wide window doesn't blow the preview up to fill
            // the whole column and push the camera + time-range controls below the
            // fold. Centered; stays 16:9.
            .frame(maxWidth: .infinity, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Scoped media token (P0-SESSIONS): the preview URL is now minted
            // async, so it's refreshed reactively rather than computed inline
            // in `body`. Keyed on the inputs that change which still to show.
            .task(id: PreviewKey(cameraIds: vm.state.selectedCameraIds, start: vm.state.start)) {
                vm.refreshPreview()
            }
            Text("Still frame at the clip start.")
                .font(.caption)
                .foregroundColor(CrumbColors.textSecondary)
        }
        .padding(.bottom, 2)
    }

    private func previewPlaceholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo").font(.title2).foregroundColor(CrumbColors.textTertiary)
            Text(text).font(.caption).foregroundColor(CrumbColors.textTertiary)
        }
    }

    /// `.task(id:)` identity for `vm.refreshPreview()` — the preview still
    /// depends on the selected camera set and the clip start date.
    private struct PreviewKey: Equatable {
        let cameraIds: Set<String>
        let start: Date
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Section: Camera Selection

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Cameras")

            let s = vm.state
            if s.cameras.isEmpty {
                Text("No cameras available.")
                    .font(.subheadline)
                    .foregroundColor(CrumbColors.textSecondary)
                    .padding(.vertical, 8)
            } else {
                if let err = s.cameraError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(CrumbColors.error)
                        .padding(.bottom, 4)
                }
                SurfaceCard {
                    ForEach(Array(s.cameras.enumerated()), id: \.element.id) { index, camera in
                        CameraCheckRow(
                            camera: camera,
                            isSelected: s.selectedCameraIds.contains(camera.id),
                            onToggle: { vm.toggleCamera(camera.id) }
                        )
                        if index < s.cameras.count - 1 {
                            Divider()
                                .background(CrumbColors.divider)
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Section: Time Range

    private var timeRangeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Clip Window")

            let s = vm.state
            let disabled = s.polling

            // Start picker
            SurfaceCard {
                DatePicker(
                    "Start",
                    selection: Binding(
                        get: { s.start },
                        set: { vm.setStart($0) }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .disabled(disabled)
                .foregroundColor(CrumbColors.textPrimary)
                .tint(CrumbColors.tealAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // End picker
            SurfaceCard {
                DatePicker(
                    "End",
                    selection: Binding(
                        get: { s.end },
                        set: { vm.setEnd($0) }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .disabled(disabled)
                .foregroundColor(CrumbColors.textPrimary)
                .tint(CrumbColors.tealAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Duration hint
            Text("Duration: \(formatDuration(s.end.timeIntervalSince(s.start)))")
                .font(.caption)
                .foregroundColor(CrumbColors.textSecondary)
        }
        .padding(.bottom, 16)
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
                }
            }
        }
        .padding(.bottom, 16)
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
                .tint(CrumbColors.teal)
                .disabled(vm.state.polling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                Text(vm.state.polling ? "Exporting…" : "Create Export")
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

                    ForEach(job.outputFiles, id: \.cameraId) { file in
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
        if cameraId == "00000000-0000-0000-0000-000000000000" { return "Archive (all cameras)" }
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

private struct CameraCheckRow: View {
    let camera: CameraDto
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? CrumbColors.tealAccent : CrumbColors.textSecondary)
                    .font(.system(size: 20))

                Text(camera.name)
                    .font(.body)
                    .foregroundColor(CrumbColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !camera.enabled {
                    Text("disabled")
                        .font(.caption2)
                        .foregroundColor(CrumbColors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
