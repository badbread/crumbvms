// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AVFoundation
import Combine

/// Single-camera recorded playback — faithful port of Android `PlaybackScreen`.
/// Full transport (goto-first · frame-step · prev/next-motion · play/pause ·
/// speed · jump-to-time · snapshot · bookmark) over a centered scrub timeline.
struct PlaybackView: View {

    @StateObject private var vm: PlaybackViewModel
    @StateObject private var player = SegmentPlayer()
    /// M6: Picture-in-Picture for recorded playback (`AVPlayerLayer`-backed —
    /// see `PictureInPicture.swift`).
    @StateObject private var pip = PlayerPictureInPicture()
    let cameras: [CameraDto]
    let onBack: () -> Void

    @State private var bookmarks: [Int64] = []
    /// Full bookmark records (macOS "Bookmarks" menu shows description + time).
    @State private var bookmarkList: [BookmarkDto] = []
    @State private var showAddBookmark = false
    @State private var showJump = false
    @State private var showExport = false
    @State private var showCameraPicker = false
    @State private var showSpeedMenu = false
    @State private var savedToast: String?
    @State private var audioOn = false
    // Export-range selection (macOS right-click "mark for export").
    @State private var exportSelStart: Int64?
    @State private var exportSelEnd: Int64?
    // macOS desktop transport: inline time-field draft + bookmarks popover.
    @State private var jumpDraft = Date()
    @State private var showBookmarksList = false
    @Environment(\.verticalSizeClass) private var vSize

    init(camera: CameraDto, cameras: [CameraDto], container: AppContainer, startTime: Date? = nil, onBack: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: PlaybackViewModel(cameraId: camera.id, container: container, startTime: startTime))
        self.cameras = cameras
        self.onBack = onBack
    }

    var body: some View {
        let landscape = vSize == .compact
        ZStack {
            CrumbColors.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if !landscape { topBar }
                ZStack(alignment: .topLeading) {
                    videoArea(landscape: landscape)
                    if landscape {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left").font(.title3.bold()).foregroundColor(.white)
                                .padding(8).background(.black.opacity(0.45)).clipShape(Circle())
                        }
                        .padding(8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : nil)
                .layoutPriority(1)
                #if os(macOS)
                macTransportBar
                #else
                transportBar(compact: landscape)
                #endif
            }

            if let toast = savedToast {
                VStack { Spacer()
                    Text(toast)
                        .font(.subheadline.weight(.medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.75)))
                        .padding(.bottom, 120)
                }.allowsHitTesting(false).transition(.opacity)
            }
        }
        .task { await loadBookmarks() }
        .onChange(of: vm.cameraId) { _ in Task { await loadBookmarks() } }
        // Feed the player whenever the resolved segment changes. `segmentPath`/
        // `cameraId`/`mediaUrls` let the HEVC-retag range-proxy re-mint a fresh
        // scoped media token if this segment plays longer than the token's
        // ~15 min TTL (P0-SESSIONS) — see `SegmentPlayer.feed`.
        .onChange(of: vm.currentSegmentURL) { url in
            player.feed(url: url, offsetMs: vm.segmentOffsetMs, playing: vm.playing && !vm.scrubbing,
                        segmentStartMs: vm.currentSegment.map { Int64((parseISO8601($0.start)?.timeIntervalSince1970 ?? 0) * 1000) } ?? 0,
                        segmentPath: vm.currentSegment?.url, cameraId: vm.cameraId, mediaUrls: vm.mediaUrls())
        }
        .onChange(of: vm.playing) { p in player.setPlaying(p && !vm.scrubbing) }
        .onChange(of: vm.speed) { s in player.setSpeed(s) }
        .onChange(of: vm.scrubbing) { s in player.setPlaying(!s && vm.playing) }
        .onAppear {
            player.onEnded = { vm.onSegmentEnded() }
            player.onError = { vm.onPlayerError() }
            player.onTick = { ms in vm.onPlaybackTick(ms) }
        }
        .sheet(isPresented: $showAddBookmark) {
            AddBookmarkDialog(atDate: vm.playheadDate) { desc, days, pre, post in
                Task {
                    if await vm.addBookmark(description: desc, protectDays: days, preSeconds: pre, postSeconds: post) {
                        await loadBookmarks()
                        flash("Bookmark added")
                    }
                }
            }
        }
        .sheet(isPresented: $showJump) {
            JumpToDateTimeDialog(initial: vm.playheadDate) { date in
                vm.jumpToTime(Int64(date.timeIntervalSince1970 * 1000))
            }
        }
        .sheet(isPresented: $showExport) {
            // Seed the batch builder with the viewed camera + the bracketed
            // selection (or the trailing hour) — one click to add it as the
            // first clip, mirroring the desktop "Export selection…" flow.
            let range = exportRange()
            ExportView(
                container: vm.container,
                cameras: cameras,
                seedCameraId: vm.cameraId,
                initialRange: (start: range.start, end: range.end),
                onClose: { showExport = false }
            )
            .macModalSize(width: 560, height: 700)
        }
        .statusBarHiddenCompat(false)
    }

    // MARK: - top bar (camera picker)

    @ViewBuilder private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.title3.bold()).foregroundColor(.white)
            }
            Button { if cameras.count > 1 { showCameraPicker = true } } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.cameraName ?? vm.cameraId).font(.headline).foregroundColor(.white)
                        Text(formatTime(vm.playheadDate, style: .clockLong))
                            .font(.caption2.monospacedDigit()).foregroundColor(CrumbColors.textSecondary)
                    }
                    if cameras.count > 1 {
                        Image(systemName: "chevron.down").font(.caption).foregroundColor(CrumbColors.textSecondary)
                    }
                }
            }
            Spacer()
            Menu {
                if vm.container.isAdmin || vm.container.capabilities.canBookmark {
                    Button { showAddBookmark = true } label: { Label("Add bookmark", systemImage: "bookmark") }
                }
                Button { snapshot() } label: { Label("Snapshot", systemImage: "camera") }
                Button { showJump = true } label: { Label("Jump to date/time", systemImage: "calendar.badge.clock") }
                if vm.container.isAdmin || vm.container.capabilities.export {
                    Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .confirmationDialog("Switch camera", isPresented: $showCameraPicker) {
            ForEach(cameras) { cam in
                Button(cam.name) { vm.switchCamera(cam.id) }
            }
        }
    }

    // MARK: - video

    @ViewBuilder private func videoArea(landscape: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            PlayerLayerView(player: player.player, onLayer: { pip.attach(to: $0) })
                .zoomable()

            // M6: Picture-in-Picture toggle — only rendered once PiP is
            // actually possible for the current player (system convention).
            PictureInPictureButton(pip: pip)
                .padding(8)

            if vm.scrubbing, let f = vm.scrubFrameURL {
                Color.black.opacity(0.55)
                // [both] H2 fix (same bug class as ExportView's preview + HEVCRetag):
                // `f` is a tokened historical-frame URL. SwiftUI's `AsyncImage` has
                // no custom-URLSession init, and always uses `URLSession.shared`
                // (disk-cached) — use `TokenedAsyncImage` (MediaSession.swift),
                // which fetches via the ephemeral `.crumbMedia` session instead.
                // keepStaleImage: the scrub URL changes per tick; keep the prior
                // frame up while the next loads instead of blinking to black.
                TokenedAsyncImage(url: f, keepStaleImage: true) { img in img.resizable().scaledToFit() } placeholder: { EmptyView() }
            }
            if vm.loading && vm.currentSegment == nil {
                ProgressView().tint(CrumbColors.teal)
            } else if vm.noFootageAtPlayhead && vm.currentSegment == nil {
                Text("No footage at this time").font(.subheadline).foregroundColor(CrumbColors.textTertiary)
            } else if let err = vm.error, vm.currentSegment == nil {
                VStack(spacing: 8) {
                    Text(err).font(.caption).foregroundColor(CrumbColors.error)
                    Button("Retry") { vm.seekTo(vm.playheadMs) }.foregroundColor(CrumbColors.teal)
                }
            } else if vm.spans.isEmpty && !vm.loading {
                Text("No footage in this time window").font(.subheadline).foregroundColor(CrumbColors.textTertiary)
            }
        }
        .modifier(VideoSizing(landscape: landscape))
    }

    // MARK: - transport + timeline

    @ViewBuilder private func transportBar(compact: Bool) -> some View {
        let ctlSize: CGFloat = compact ? 26 : 36
        let ctlIcon: CGFloat = compact ? 15 : 19
        let playSize: CGFloat = compact ? 33 : 50
        VStack(spacing: compact ? 0 : 6) {
            HStack(spacing: 2) {
                ctl("backward.frame.fill", "Step back one frame", ctlSize, ctlIcon) { player.stepFrame(forward: false); vm.setPlaying(false) }
                motionJump(forward: false, size: ctlSize, icon: ctlIcon) { vm.jumpToPrevMotion() }
                Button { vm.setPlaying(!vm.playing) } label: {
                    Image(systemName: vm.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: playSize * 0.5)).foregroundColor(.white)
                        .frame(width: playSize, height: playSize).background(CrumbColors.teal).clipShape(Circle())
                }
                .accessibilityLabel(vm.playing ? "Pause" : "Play")
                .padding(.horizontal, 4)
                motionJump(forward: true, size: ctlSize, icon: ctlIcon) { vm.jumpToNextMotion() }
                ctl("forward.frame.fill", "Step forward one frame", ctlSize, ctlIcon) { player.stepFrame(forward: true); vm.setPlaying(false) }
                ctl("forward.to.line", "Jump to latest", ctlSize, ctlIcon) { vm.gotoLast() }
                Button {
                    audioOn.toggle(); player.setMuted(!audioOn)
                } label: {
                    Image(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: ctlIcon)).foregroundColor(audioOn ? CrumbColors.tealAccent : .white)
                        .frame(width: ctlSize, height: ctlSize)
                }
                .accessibilityLabel(audioOn ? "Mute audio" : "Unmute audio")
                Menu {
                    ForEach([8.0, 4.0, 2.0, 1.0, 0.5], id: \.self) { s in
                        Button { vm.setSpeed(Float(s)) } label: {
                            Text(speedLabel(Float(s)))
                            if vm.speed == Float(s) { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    Text(speedLabel(vm.speed)).font(.caption.bold()).foregroundColor(CrumbColors.tealAccent)
                        .frame(minWidth: ctlSize, minHeight: ctlSize)
                }
            }
            .padding(.top, compact ? 1 : 6)

            timeline
                .frame(height: compact ? 30 : 72)
                .padding(.horizontal, 8).padding(.bottom, compact ? 2 : 8)
        }
        // Interactive content stays inside the safe area (so scrubbing near the
        // bottom never steals the iOS home-indicator swipe), but the bar's surface
        // bleeds into the home-indicator inset so that strip isn't dead black
        // padding — the bar reads as ending at the screen edge.
        .background(CrumbColors.surface, ignoresSafeAreaEdges: .bottom)
    }

    /// The scrub timeline, shared by the iOS compact bar and the macOS desktop bar.
    @ViewBuilder private var timeline: some View {
        CenteredTimelineView(
            spans: vm.spans, motionBuckets: vm.motionBuckets,
            motionStartMs: vm.motionStartMs, motionEndMs: vm.motionEndMs,
            detectionEvents: vm.detectionEvents, bookmarks: bookmarks,
            playheadMs: vm.playheadMs, spanMs: vm.visibleSpanMs,
            onScrubStart: { vm.onScrubStart() },
            onScrub: { vm.onScrub($0) },
            onScrubEnd: { vm.onScrubEnd($0) },
            onSpanChange: { vm.setVisibleSpan($0) },
            exportSelStartMs: exportSelStart,
            exportSelEndMs: exportSelEnd,
            onSetExportStart: { setExportEdge(start: true, ms: $0) },
            onSetExportEnd: { setExportEdge(start: false, ms: $0) },
            onExportSelection: { showExport = true },
            onClearExportSelection: { exportSelStart = nil; exportSelEnd = nil }
        )
    }

    private func ctl(_ icon: String, _ label: String, _ size: CGFloat, _ iconSize: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: iconSize)).foregroundColor(.white)
                .frame(width: size, height: size)
        }
        .accessibilityLabel(label)
    }

    /// Prev/next-motion control: a directional chevron + the running-person glyph,
    /// so it reads as "jump to a MOTION event" rather than a generic skip.
    private func motionJump(forward: Bool, size: CGFloat, icon: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: -1) {
                if !forward { Image(systemName: "chevron.left").font(.system(size: icon * 0.7)).foregroundColor(.white) }
                Image(systemName: "figure.run").font(.system(size: icon * 0.85)).foregroundColor(CrumbColors.tealAccent)
                if forward { Image(systemName: "chevron.right").font(.system(size: icon * 0.7)).foregroundColor(.white) }
            }
            .frame(width: size * 1.25, height: size)
        }
    }

    private func speedLabel(_ s: Float) -> String {
        s == 0.5 ? "0.5×" : "\(Int(s))×"
    }

    // MARK: - macOS desktop transport

    #if os(macOS)
    /// Discrete zoom spans (2m … 24h), matching the desktop client's zoom steps.
    private static let zoomSteps: [Int64] = [
        120_000, 300_000, 900_000, 1_800_000, 3_600_000,
        10_800_000, 21_600_000, 43_200_000, 86_400_000,
    ]

    @ViewBuilder private var macTransportBar: some View {
        VStack(spacing: 8) {
            // Row 1 — playhead time · centered transport · speed + mute
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatTime(vm.playheadDate, style: .clockLong))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                    Text(macDateLabel(vm.playheadDate))
                        .font(.caption2).foregroundColor(CrumbColors.textSecondary)
                }
                .frame(minWidth: 150, alignment: .leading)

                Spacer()

                HStack(spacing: 6) {
                    ctl("backward.frame.fill", "Step back one frame", 34, 17) { player.stepFrame(forward: false); vm.setPlaying(false) }
                    motionJump(forward: false, size: 34, icon: 17) { vm.jumpToPrevMotion() }
                    Button { vm.setPlaying(!vm.playing) } label: {
                        Image(systemName: vm.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 22)).foregroundColor(.white)
                            .frame(width: 46, height: 46).background(CrumbColors.teal).clipShape(Circle())
                    }
                    .buttonStyle(.plain).padding(.horizontal, 4)
                    motionJump(forward: true, size: 34, icon: 17) { vm.jumpToNextMotion() }
                    ctl("forward.frame.fill", "Step forward one frame", 34, 17) { player.stepFrame(forward: true); vm.setPlaying(false) }
                    ctl("forward.to.line", "Jump to latest", 34, 17) { vm.gotoLast() }
                }

                Spacer()

                HStack(spacing: 8) {
                    Menu {
                        ForEach([8.0, 4.0, 2.0, 1.0, 0.5], id: \.self) { s in
                            Button { vm.setSpeed(Float(s)) } label: {
                                Text(speedLabel(Float(s)))
                                if vm.speed == Float(s) { Image(systemName: "checkmark") }
                            }
                        }
                    } label: {
                        Text(speedLabel(vm.speed)).font(.callout.bold())
                            .foregroundColor(CrumbColors.tealAccent).frame(minWidth: 38)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button { audioOn.toggle(); player.setMuted(!audioOn) } label: {
                        Image(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 17)).foregroundColor(audioOn ? CrumbColors.tealAccent : .white)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                }
                .frame(minWidth: 150, alignment: .trailing)
            }

            // Row 2 — jump buttons + time field · bookmark controls · export
            HStack(spacing: 8) {
                Text("Jump").font(.caption).foregroundColor(CrumbColors.textSecondary)
                jumpChip("−1h") { shiftPlayhead(-3_600_000) }
                jumpChip("−10m") { shiftPlayhead(-600_000) }
                jumpChip("+10m") { shiftPlayhead(600_000) }
                jumpChip("+1h") { shiftPlayhead(3_600_000) }

                macDivider

                DatePicker("", selection: $jumpDraft, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.compact).fixedSize()
                Button("Go") { vm.jumpToTime(Int64(jumpDraft.timeIntervalSince1970 * 1000)) }
                    .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundColor(CrumbColors.tealAccent)

                Spacer()

                if vm.container.isAdmin || vm.container.capabilities.canBookmark {
                    iconChip("bookmark", "Add bookmark") { showAddBookmark = true }
                }
                iconChip("chevron.backward.to.line", "Previous bookmark") { jumpBookmark(forward: false) }
                    .disabled(bookmarks.isEmpty)
                iconChip("chevron.forward.to.line", "Next bookmark") { jumpBookmark(forward: true) }
                    .disabled(bookmarks.isEmpty)
                // "Bookmarks" list — labeled like the desktop client's
                // "Bookmarks" button (was a bare ≡ icon that read as a mystery
                // date list). Each item jumps playback to that bookmark.
                Menu {
                    if bookmarkList.isEmpty {
                        Text("No saved bookmarks")
                    } else {
                        ForEach(bookmarkList) { bm in
                            Button(bookmarkMenuTitle(bm)) {
                                if let d = parseISO8601(bm.ts) {
                                    vm.jumpToTime(Int64(d.timeIntervalSince1970 * 1000))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark").font(.system(size: 12))
                        Text("Bookmarks").font(.callout)
                    }
                    .foregroundColor(CrumbColors.textSecondary)
                    .frame(height: 30)
                }
                .menuStyle(.borderlessButton).fixedSize().help("View saved bookmarks")

                if vm.container.isAdmin || vm.container.capabilities.export {
                    macDivider
                    Button { showExport = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up").font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundColor(CrumbColors.tealAccent)
                }
            }

            // Row 3 — timeline
            timeline.frame(height: 78)

            // Row 4 — zoom control
            HStack(spacing: 8) {
                Spacer()
                Text("Zoom").font(.caption2).foregroundColor(CrumbColors.textSecondary)
                Button { zoomStep(out: true) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).foregroundColor(CrumbColors.textSecondary)
                Slider(value: zoomSliderBinding, in: 0...Double(Self.zoomSteps.count - 1), step: 1)
                    .frame(width: 170).tint(CrumbColors.tealAccent)
                Button { zoomStep(out: false) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).foregroundColor(CrumbColors.textSecondary)
                Text(macSpanLabel(vm.visibleSpanMs))
                    .font(.caption2.monospacedDigit()).foregroundColor(CrumbColors.textPrimary)
                    .frame(width: 34, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .background(CrumbColors.surface)
        .onAppear { jumpDraft = vm.playheadDate }
    }

    private var macDivider: some View {
        Rectangle().fill(CrumbColors.divider).frame(width: 1, height: 18)
    }

    private func jumpChip(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(CrumbColors.surfaceVariant, in: Capsule())
                .foregroundColor(CrumbColors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func iconChip(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15))
                .foregroundColor(CrumbColors.textSecondary).frame(width: 32, height: 30)
        }
        .buttonStyle(.plain).help(help)
    }

    private func shiftPlayhead(_ delta: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        vm.jumpToTime(min(max(vm.playheadMs + delta, 0), now))
    }

    /// Jump to the nearest bookmark before/after the playhead (`bookmarks` sorted).
    private func jumpBookmark(forward: Bool) {
        let p = vm.playheadMs
        if forward {
            if let next = bookmarks.first(where: { $0 > p + 500 }) { vm.jumpToTime(next) }
        } else {
            if let prev = bookmarks.last(where: { $0 < p - 500 }) { vm.jumpToTime(prev) }
        }
    }

    private func nearestZoomIndex(_ ms: Int64) -> Int {
        var best = 0, bestDiff = Int64.max
        for (i, s) in Self.zoomSteps.enumerated() {
            let d = abs(s - ms)
            if d < bestDiff { bestDiff = d; best = i }
        }
        return best
    }

    /// Slider value where higher = more zoomed in (smaller span), matching desktop.
    private var zoomSliderBinding: Binding<Double> {
        let n = Self.zoomSteps.count - 1
        return Binding(
            get: { Double(n - nearestZoomIndex(vm.visibleSpanMs)) },
            set: { v in vm.setVisibleSpan(Self.zoomSteps[n - Int(v.rounded())]) }
        )
    }

    private func zoomStep(out: Bool) {
        let n = Self.zoomSteps.count - 1
        let idx = nearestZoomIndex(vm.visibleSpanMs)
        let next = out ? min(idx + 1, n) : max(idx - 1, 0)
        vm.setVisibleSpan(Self.zoomSteps[next])
    }

    private func macSpanLabel(_ ms: Int64) -> String {
        let m = ms / 60_000
        return m < 60 ? "\(m)m" : "\(m / 60)h"
    }

    private func macDateLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return f.string(from: d)
    }
    #endif

    // MARK: - export selection

    /// Set one edge of the export bracket, seeding the missing edge from the
    /// playhead so a range is always visible once an edge is placed. Mirrors the
    /// desktop `pbSetExportEdge`.
    private func setExportEdge(start: Bool, ms: Int64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let t = min(ms, now)
        if start {
            exportSelStart = t
            if exportSelEnd == nil { exportSelEnd = max(t, vm.playheadMs) }
        } else {
            exportSelEnd = t
            if exportSelStart == nil { exportSelStart = min(t, vm.playheadMs) }
        }
    }

    /// The export range: the bracketed selection if present, else the hour ending
    /// at the playhead (the prior default).
    private func exportRange() -> (start: Date, end: Date) {
        if let s = exportSelStart, let e = exportSelEnd {
            let a = min(s, e), b = max(s, e)
            return (Date(timeIntervalSince1970: Double(a) / 1000),
                    Date(timeIntervalSince1970: Double(b) / 1000))
        }
        return (vm.playheadDate.addingTimeInterval(-3600), vm.playheadDate)
    }

    // MARK: - helpers

    private func loadBookmarks() async {
        if let list = try? await vm.container.api.bookmarks(cameraId: vm.cameraId) {
            bookmarkList = list.sorted { $0.ts < $1.ts }
            bookmarks = list.compactMap { parseISO8601($0.ts).map { Int64($0.timeIntervalSince1970 * 1000) } }.sorted()
        }
    }

    /// "Front door — Mon Jun 3, 14:05:30" (or just the time when undescribed).
    private func bookmarkMenuTitle(_ bm: BookmarkDto) -> String {
        let time = parseISO8601(bm.ts).map { formatTime($0, style: .clockLong) } ?? bm.ts
        if let desc = bm.description, !desc.isEmpty { return "\(desc) — \(time)" }
        return time
    }

    /// [both] H1 fix: snapshot the PLAYHEAD frame, not the live camera frame.
    /// `cameraFrameUrl` hits the live `/frame.jpg` proxy — wrong for a playback
    /// view where the operator is scrubbed to a specific historical moment.
    /// `historicalFrameUrl` extracts the still on-demand from recorded footage at
    /// the current playhead timestamp (same endpoint the scrub-preview tiles use).
    private func snapshot() {
        let iso = ISO8601DateFormatter().string(from: vm.playheadDate)
        let camId = vm.cameraId
        Task {
            guard let frameUrl = await vm.mediaUrls().historicalFrameUrl(cameraId: camId, tsISO: iso) else { return }
            if let (data, _) = try? await URLSession.crumbMedia.data(from: frameUrl), let img = PlatformImage(data: data) {
                try? await saveToPhotos(img)
                flash("Snapshot saved")
            }
        }
    }

    private func flash(_ msg: String) {
        withAnimation { savedToast = msg }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { savedToast = nil } }
    }
}

/// Portrait → letterboxed 16:9; landscape → fill the available height so the
/// transport bar doesn't shrink the video (the Android landscape lesson).
private struct VideoSizing: ViewModifier {
    let landscape: Bool
    func body(content: Content) -> some View {
        if landscape {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }
}

// MARK: - AVPlayer controller for recorded segments

@MainActor
final class SegmentPlayer: ObservableObject {
    let player = AVPlayer()
    var onEnded: () -> Void = {}
    var onError: () -> Void = {}
    var onTick: (Int64) -> Void = { _ in }

    private var retagDelegate: HEVCRetagLoaderDelegate?
    private var currentURL: URL?
    private var segmentStartMs: Int64 = 0
    private var speed: Float = 1
    private var wantPlaying = false
    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    /// Guards against a stale probe (from a segment we've since moved past)
    /// installing its player item after a newer `feed` call has already won.
    private var probeGeneration = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true // recorded audio starts muted; user toggles it on
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            if self.player.timeControlStatus == .playing {
                self.onTick(self.segmentStartMs + Int64(time.seconds * 1000))
            }
        }
    }

    /// Feed a new (or the same) recorded segment to the player.
    ///
    /// **M4 seek redesign:** rather than unconditionally routing every segment
    /// through the whole-file-download HEVC retag loader, this first probes
    /// the segment header (a few-KB range fetch, `HEVCRetag.probe`) to learn
    /// whether it actually needs the `hev1`→`hvc1` retag:
    /// - Not needed (`hvc1`/AVC/no video trak) → the origin URL is handed
    ///   straight to `AVURLAsset`, so AVPlayer performs its own native HTTP
    ///   range requests and seeks instantly with zero pre-download.
    /// - Needed → routed through `HEVCRetagLoaderDelegate`'s range-streamed
    ///   proxy (patches only the small `moov` header in memory; `moof`/`mdat`
    ///   are proxied from the origin on demand as AVFoundation asks for them).
    /// - Inconclusive → falls back to the old whole-segment download, so
    ///   correctness is preserved even for an unexpected box layout.
    ///
    /// The probe itself is a small, fast request (typically a single range
    /// GET of tens of KB), so this adds negligible latency versus the old
    /// path while eliminating the full-segment download in the common case.
    ///
    /// - Parameters:
    ///   - url: the (already scoped-token-bearing) segment URL to play.
    ///   - segmentPath: the RAW path (`segment.url` from `ResolvedSegment`,
    ///     e.g. `/segments/{id}`) `url` was built from — carried through so
    ///     the HEVC-retag range-proxy can re-mint a FRESH scoped token for
    ///     this same segment if playback outlives the ~15 min token that was
    ///     current when `url` was minted (P0-SESSIONS). `nil` disables
    ///     refresh (falls back to reusing `url`'s original token for the
    ///     whole segment — matches pre-migration behavior, just with a
    ///     shorter-lived token).
    ///   - cameraId / mediaUrls: together with `segmentPath`, let the retag
    ///     delegate re-mint via `MediaTokenCache` (a cache hit in the common
    ///     case where the token is still fresh).
    func feed(
        url: URL?, offsetMs: Int64, playing: Bool, segmentStartMs: Int64,
        segmentPath: String? = nil, cameraId: String? = nil, mediaUrls: MediaUrls? = nil
    ) {
        self.segmentStartMs = segmentStartMs
        self.wantPlaying = playing
        guard let url else {
            player.replaceCurrentItem(with: nil)
            currentURL = nil
            return
        }
        guard url != currentURL else {
            // Same segment — just reseek to the offset.
            seek(ms: offsetMs)
            return
        }
        currentURL = url
        probeGeneration += 1
        let generation = probeGeneration

        Task { [weak self] in
            let requirement = await HEVCRetag.probe(url: url)
            guard let self, self.probeGeneration == generation, self.currentURL == url else { return }
            self.installPlayerItem(
                for: url, requirement: requirement, offsetMs: offsetMs,
                segmentPath: segmentPath, cameraId: cameraId, mediaUrls: mediaUrls
            )
        }
    }

    private func installPlayerItem(
        for url: URL, requirement: HEVCRetag.RemuxRequirement, offsetMs: Int64,
        segmentPath: String?, cameraId: String?, mediaUrls: MediaUrls?
    ) {
        let asset: AVURLAsset
        switch requirement {
        case .passthrough:
            // No retag needed — native AVURLAsset against the origin URL.
            // AVFoundation issues its own Range: requests; seeking is exactly
            // as instant as any ordinary progressive-download HTTP asset.
            //
            // NOTE: unlike the retag path below, there is no app-level proxy
            // sitting in front of these requests to refresh an expiring
            // scoped token — AVFoundation talks to the origin directly. A
            // segment played passthrough for longer than the ~15 min token TTL
            // could see AVFoundation's own range request 401. This matches
            // the instructed scope (HEVCRetag's proxy is the seam that needs
            // freshness handling); a passthrough mid-playback 401 surfaces
            // through the existing `onError` → `PlaybackViewModel.onPlayerError()`
            // → `seekTo(playheadMs)` retry path, which re-resolves the segment
            // and mints a fresh token via a new `/play` + scoped-URL round trip.
            asset = AVURLAsset(url: url)
            retagDelegate = nil
        case .retagRequired, .unknown:
            let custom = HEVCRetag.customSchemeURL(url)
            asset = AVURLAsset(url: custom)
            var refresh: (() async -> URL?)?
            if let segmentPath, let cameraId, let mediaUrls {
                refresh = { await mediaUrls.scopedURL(cameraId: cameraId, segmentPath) }
            }
            let delegate = HEVCRetagLoaderDelegate(realURL: url, wholeFileFallback: requirement == .unknown, refreshURL: refresh)
            asset.resourceLoader.setDelegate(delegate, queue: .main)
            retagDelegate = delegate
        }

        let item = AVPlayerItem(asset: asset)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.onEnded()
        }
        statusCancellable = item.publisher(for: \.status).sink { [weak self] status in
            if status == .failed { self?.onError() }
        }
        player.replaceCurrentItem(with: item)
        if offsetMs > 0 { seek(ms: offsetMs) }
        applyRate()
    }

    private func seek(ms: Int64) {
        player.seek(to: CMTime(seconds: Double(ms) / 1000, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setPlaying(_ p: Bool) { wantPlaying = p; applyRate() }
    func setSpeed(_ s: Float) { speed = s; applyRate() }
    func setMuted(_ m: Bool) { player.isMuted = m }
    private func applyRate() { player.rate = wantPlaying ? speed : 0 }

    /// Native single-frame step (auto-pauses). iOS handles this directly.
    func stepFrame(forward: Bool) {
        wantPlaying = false
        player.pause()
        player.currentItem?.step(byCount: forward ? 1 : -1)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

