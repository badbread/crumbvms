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
    /// Balances `CrumbAudioSession` acquire/release for recorded-playback audio.
    @State private var audioSessionHeld = false
    // Export-range selection (macOS right-click "mark for export").
    @State private var exportSelStart: Int64?
    @State private var exportSelEnd: Int64?
    // macOS desktop transport: inline time-field draft + bookmarks popover.
    @State private var jumpDraft = Date()
    @State private var showBookmarksList = false
    @Environment(\.verticalSizeClass) private var vSize
    /// Selected media quality (Full/Data-saver/Auto), loaded from the secure
    /// store on appear; the chip cycles + persists it.
    @State private var quality: PlaybackQuality = .fallback
    /// App-wide metered signal, observed so `.auto` re-resolves live when the
    /// link flips metered mid-session.
    @ObservedObject private var connectivity: ConnectivityMonitor

    init(camera: CameraDto, cameras: [CameraDto], container: AppContainer, startTime: Date? = nil, onBack: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: PlaybackViewModel(cameraId: camera.id, container: container, startTime: startTime))
        _connectivity = ObservedObject(wrappedValue: container.connectivity)
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
                #if os(iOS)
                // iOS: the video region fills the space between the header and the
                // transport bar in BOTH orientations. The transport bar pins to
                // the bottom of the screen (matching Android), the video sits
                // CENTERED in the region (AVPlayerLayer `resizeAspect`), and
                // pinch-zoom grows the video into the letterbox bars — because the
                // zoomable/clipped area is now the full region, not the fitted
                // 16:9 box (issue #36).
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : nil)
                #endif
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
        .onChange(of: vm.cameraId) { _ in Task { await loadBookmarks() }; restoreAudio() }
        // Feed the player whenever the resolved segment changes. `segmentPath`/
        // `cameraId`/`mediaUrls` let the HEVC-retag range-proxy re-mint a fresh
        // scoped media token if this segment plays longer than the token's
        // ~15 min TTL (P0-SESSIONS) — see `SegmentPlayer.feed`.
        .onChange(of: vm.currentSegmentURL) { url in
            player.feed(url: url, offsetMs: vm.segmentOffsetMs, playing: vm.playing && !vm.scrubbing,
                        segmentStartMs: vm.currentSegment.map { Int64((parseISO8601($0.start)?.timeIntervalSince1970 ?? 0) * 1000) } ?? 0,
                        segmentPath: vm.currentSegment?.url, cameraId: vm.cameraId, mediaUrls: vm.mediaUrls())
        }
        // Gapless boundary (issue #23): the VM resolves the next contiguous
        // segment ~2.5s early; hand it to the player to probe + queue so the
        // ~4s boundary advances with no black flash.
        .onChange(of: vm.prefetchNext) { signal in
            guard let signal else { return }
            player.enqueueNext(url: signal.url, segmentStartMs: signal.startMs,
                               segmentPath: signal.path, cameraId: vm.cameraId, mediaUrls: vm.mediaUrls())
        }
        .onChange(of: vm.playing) { p in player.setPlaying(p && !vm.scrubbing) }
        .onChange(of: vm.speed) { s in player.setSpeed(s) }
        .onChange(of: vm.scrubbing) { s in player.setPlaying(!s && vm.playing) }
        // `.auto`: re-resolve playback when the link flips metered/unmetered.
        .onChange(of: connectivity.isMetered) { _ in applyQuality() }
        .onAppear {
            player.onEnded = { vm.onSegmentEnded() }
            player.onError = { vm.onPlayerError() }
            player.onTick = { ms in vm.onPlaybackTick(ms) }
            player.onAdvanced = { vm.commitAdvance() }
            restoreAudio()
            quality = PlaybackQuality(persisted: vm.container.store.playbackQuality)
            applyQuality()
        }
        .onDisappear { releaseAudioSession() }
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

            // Top-right controls: audio toggle (always shown) + PiP (shown once
            // PiP is actually possible for the current player).
            HStack(spacing: 6) {
                audioToggleButton
                PictureInPictureButton(pip: pip)
            }
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
                ctl("backward.to.line", "Jump to oldest", ctlSize, ctlIcon) { vm.gotoFirst() }
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
                qualityChip(minSize: ctlSize)
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

    // MARK: - audio

    /// The top-right audio toggle, pinned over the video so it's reachable in
    /// both orientations (the header is hidden in landscape). Enables/disables
    /// sound for the recorded footage of the current camera; remembered per
    /// camera. Audio only exists in segments the recorder captured with the
    /// camera's `record_audio` policy on.
    private var audioToggleButton: some View {
        Button { setAudio(!audioOn) } label: {
            Image(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.title3)
                .foregroundColor(audioOn ? CrumbColors.tealAccent : .white)
                .padding(8)
                .background(.black.opacity(0.45))
                .clipShape(Circle())
        }
        .accessibilityLabel(audioOn ? "Mute audio" : "Unmute audio")
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - quality

    /// One-tap quality chip (Auto → Full → Data saver → Auto), mirroring
    /// Android's playback-bar chip: `HD`/`SD`/`AUTO`, teal when a non-Auto
    /// override is active. Persists the choice and re-resolves playback.
    private func qualityChip(minSize: CGFloat) -> some View {
        Button {
            quality = quality.next
            vm.container.store.playbackQuality = quality.rawValue
            applyQuality()
        } label: {
            Text(quality.short)
                .font(.caption2.bold())
                .foregroundColor(quality == .auto ? .white : CrumbColors.tealAccent)
                .frame(minWidth: minSize, minHeight: minSize)
        }
        .accessibilityLabel("Quality: \(quality.label)")
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    /// Apply an audio on/off choice: mute the player, persist it for this camera,
    /// and acquire/release the shared `.playback` session so unmuted sound
    /// actually plays (through the speaker, ignoring the ring switch).
    private func setAudio(_ on: Bool) {
        audioOn = on
        player.setMuted(!on)
        vm.container.settings.setAudioEnabled(on, for: vm.cameraId)
        if on {
            if !audioSessionHeld { CrumbAudioSession.acquire(); audioSessionHeld = true }
        } else if audioSessionHeld {
            CrumbAudioSession.release(); audioSessionHeld = false
        }
    }

    /// Restore the remembered audio choice for the current camera (called on
    /// appear and camera switch).
    private func restoreAudio() {
        setAudio(vm.container.settings.audioEnabled(for: vm.cameraId))
    }

    /// Drop the audio session if we hold it (leaving the view).
    private func releaseAudioSession() {
        if audioSessionHeld { CrumbAudioSession.release(); audioSessionHeld = false }
    }

    /// Resolve the current quality preference + metered state into the low/full
    /// decision and hand it to the view-model (which drives `/low.mp4` vs the raw
    /// segment). Called on appear, on chip change, and whenever the link's
    /// metered state flips (so `.auto` reacts live).
    private func applyQuality() {
        vm.setLowQuality(quality.useLow(metered: connectivity.isMetered))
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
                    ctl("backward.to.line", "Jump to oldest", 34, 17) { vm.gotoFirst() }
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
                    qualityChip(minSize: 34)
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
        #if os(iOS)
        // iOS: fill in both orientations so the video sits centered within the
        // region (resizeAspect) and pinch-zoom can expand into the letterbox
        // bars, matching Android (issue #36). Was 16:9-boxed in portrait, which
        // top-anchored the video and bounded zoom to the fitted rect.
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        if landscape {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
        #endif
    }
}

// MARK: - AVPlayer controller for recorded segments

@MainActor
final class SegmentPlayer: ObservableObject {
    // AVQueuePlayer (an AVPlayer subclass, so `PlayerLayerView` + PiP keep
    // working unchanged) is what makes playback GAPLESS across the ~4 s segment
    // boundaries (issue #23): the next segment is prefetched + queued while the
    // current one still plays, and the queue advances to the already-warm item
    // with no teardown — instead of the old single-`AVPlayer` `replaceCurrentItem`
    // at the boundary, which flashed black for a frame or several every segment.
    let player = AVQueuePlayer()
    var onEnded: () -> Void = {}
    var onError: () -> Void = {}
    var onTick: (Int64) -> Void = { _ in }
    /// The queue gaplessly advanced to the prefetched next segment. The view
    /// forwards this to `PlaybackViewModel.commitAdvance()`, which promotes the
    /// prefetched segment to `currentSegment` and prefetches the one after.
    var onAdvanced: () -> Void = {}

    // Retag delegates must stay retained for as long as their item is in the
    // queue (the resource-loader holds them weakly). One per live item.
    private var currentDelegate: HEVCRetagLoaderDelegate?
    private var nextDelegate: HEVCRetagLoaderDelegate?

    private var currentURL: URL?
    /// The prefetched-and-queued next segment's URL (nil = nothing queued).
    private var nextURL: URL?
    private var segmentStartMs: Int64 = 0
    private var nextStartMs: Int64 = 0
    private var speed: Float = 1
    private var wantPlaying = false
    private var timeObserver: Any?
    private var statusCancellable: AnyCancellable?
    private var currentItemCancellable: AnyCancellable?
    /// Guards against a stale probe (from a segment we've since moved past)
    /// installing its player item after a newer `feed`/advance has already won.
    private var probeGeneration = 0
    /// True while we programmatically rebuild the queue (`feed` replace path),
    /// so the `currentItem` observer doesn't mistake the transient change for a
    /// real boundary. Starts true so the observer's first emission is ignored.
    private var isReplacing = true
    /// Set when the queue auto-advanced to the prefetched next item, so the
    /// view-model's follow-up `feed(sameURL, offset:0)` is a no-op rather than a
    /// seek-to-0 hitch on the item that is already playing.
    private var justAdvanced = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true // recorded audio starts muted; user toggles it on
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            if self.player.timeControlStatus == .playing {
                self.onTick(self.segmentStartMs + Int64(time.seconds * 1000))
            }
        }
        // Drive boundary handling off `currentItem`: the queue removes the
        // finished item and either advances to the queued next (→ gapless) or,
        // when nothing is queued, runs dry (→ nil = end-of-segment). `[.new]`
        // (no `.initial`) + `isReplacing` keep the startup/rebuild churn quiet.
        currentItemCancellable = player.publisher(for: \.currentItem, options: [.new])
            .sink { [weak self] item in self?.handleCurrentItemChange(item) }
    }

    private func handleCurrentItemChange(_ item: AVPlayerItem?) {
        guard !isReplacing else { return }
        if item == nil {
            // Queue ran dry with nothing prefetched — a recording gap, a
            // prefetch that didn't land in time, or the end of footage. Fall
            // back to the existing resolve-and-seek path (its old ~1-frame
            // flash, only on these non-contiguous transitions).
            onEnded()
        } else if nextURL != nil {
            // Gapless auto-advance to the prefetched next segment.
            promoteNext()
            justAdvanced = true
            applyRate()
            attachStatusObserver(item)
            onAdvanced()
        }
    }

    /// Promote the queued next segment's bookkeeping to "current" after the
    /// queue advanced to it (the item itself is already the queue's currentItem).
    private func promoteNext() {
        currentURL = nextURL
        segmentStartMs = nextStartMs
        currentDelegate = nextDelegate
        nextURL = nil
        nextStartMs = 0
        nextDelegate = nil
        probeGeneration += 1 // invalidate any still-in-flight prefetch probe
    }

    /// Feed a new recorded segment — the REPLACE path (initial load, seek/jump,
    /// scrub-resume, camera switch). Clears the queue and any prefetched next.
    /// Linear boundary advances do NOT come through here; they go gaplessly via
    /// the queue (`enqueueNext` + the `currentItem` observer).
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
    /// - Parameters:
    ///   - url: the (already scoped-token-bearing) segment URL to play.
    ///   - segmentPath: the RAW path (`segment.url` from `ResolvedSegment`,
    ///     e.g. `/segments/{id}`) `url` was built from — carried through so
    ///     the HEVC-retag range-proxy can re-mint a FRESH scoped token for
    ///     this same segment if playback outlives the ~15 min token that was
    ///     current when `url` was minted (P0-SESSIONS).
    ///   - cameraId / mediaUrls: together with `segmentPath`, let the retag
    ///     delegate re-mint via `MediaTokenCache`.
    func feed(
        url: URL?, offsetMs: Int64, playing: Bool, segmentStartMs: Int64,
        segmentPath: String? = nil, cameraId: String? = nil, mediaUrls: MediaUrls? = nil
    ) {
        self.wantPlaying = playing
        guard let url else {
            rebuild(with: nil, offsetMs: 0, segmentStartMs: 0)
            return
        }
        if url == currentURL {
            // Same segment. A gapless advance already positioned us at offset 0,
            // so the view-model's follow-up feed is a no-op; otherwise it's a
            // scrub within the current segment → reseek.
            if justAdvanced { justAdvanced = false; return }
            self.segmentStartMs = segmentStartMs
            seek(ms: offsetMs)
            return
        }
        probeGeneration += 1
        let generation = probeGeneration
        Task { [weak self] in
            let requirement = await HEVCRetag.probe(url: url)
            guard let self, self.probeGeneration == generation else { return }
            let (item, delegate) = self.buildItem(
                url: url, requirement: requirement,
                segmentPath: segmentPath, cameraId: cameraId, mediaUrls: mediaUrls
            )
            self.currentURL = url
            self.currentDelegate = delegate
            self.rebuild(with: item, offsetMs: offsetMs, segmentStartMs: segmentStartMs)
        }
    }

    /// Prefetch + queue the next contiguous segment so the boundary is gapless.
    /// No-op (→ falls back to `onEnded`) if the probe/build races a seek or the
    /// current item is already gone; a failed queued item recovers via `onError`.
    func enqueueNext(
        url: URL, segmentStartMs: Int64,
        segmentPath: String? = nil, cameraId: String? = nil, mediaUrls: MediaUrls? = nil
    ) {
        guard url != currentURL, url != nextURL, player.currentItem != nil else { return }
        let generation = probeGeneration
        Task { [weak self] in
            let requirement = await HEVCRetag.probe(url: url)
            // Bail if a feed/advance happened meanwhile, or a next is already
            // queued, or the queue emptied out from under us.
            guard let self, self.probeGeneration == generation,
                  self.nextURL == nil, url != self.currentURL,
                  let current = self.player.currentItem else { return }
            let (item, delegate) = self.buildItem(
                url: url, requirement: requirement,
                segmentPath: segmentPath, cameraId: cameraId, mediaUrls: mediaUrls
            )
            guard self.player.canInsert(item, after: current) else { return }
            self.player.insert(item, after: current)
            self.nextURL = url
            self.nextStartMs = segmentStartMs
            self.nextDelegate = delegate
        }
    }

    /// Build an `AVPlayerItem` (+ its retag delegate, if any) for a segment URL.
    /// Shared by the replace path (`feed`) and the prefetch path (`enqueueNext`).
    private func buildItem(
        url: URL, requirement: HEVCRetag.RemuxRequirement,
        segmentPath: String?, cameraId: String?, mediaUrls: MediaUrls?
    ) -> (AVPlayerItem, HEVCRetagLoaderDelegate?) {
        let asset: AVURLAsset
        let delegate: HEVCRetagLoaderDelegate?
        switch requirement {
        case .passthrough:
            // No retag needed — native AVURLAsset against the origin URL.
            // AVFoundation issues its own Range: requests; seeking is as instant
            // as any ordinary progressive-download HTTP asset.
            //
            // NOTE: unlike the retag path, there is no app-level proxy in front
            // of these requests to refresh an expiring scoped token. A passthrough
            // segment played past the ~15 min token TTL could 401 on AVFoundation's
            // own range request; that surfaces through `onError` →
            // `PlaybackViewModel.onPlayerError()` → `seekTo(playheadMs)`, which
            // re-resolves with a fresh token.
            asset = AVURLAsset(url: url)
            delegate = nil
        case .retagRequired, .unknown:
            let custom = HEVCRetag.customSchemeURL(url)
            asset = AVURLAsset(url: custom)
            var refresh: (() async -> URL?)?
            if let segmentPath, let cameraId, let mediaUrls {
                refresh = { await mediaUrls.scopedURL(cameraId: cameraId, segmentPath) }
            }
            let d = HEVCRetagLoaderDelegate(realURL: url, wholeFileFallback: requirement == .unknown, refreshURL: refresh)
            asset.resourceLoader.setDelegate(d, queue: .main)
            delegate = d
        }
        return (AVPlayerItem(asset: asset), delegate)
    }

    /// Replace the whole queue with a single item (or clear it when nil).
    private func rebuild(with item: AVPlayerItem?, offsetMs: Int64, segmentStartMs: Int64) {
        isReplacing = true
        justAdvanced = false
        self.segmentStartMs = segmentStartMs
        // Drop any prefetched next — it belonged to the old position.
        nextURL = nil
        nextStartMs = 0
        nextDelegate = nil
        player.removeAllItems()
        if let item {
            if player.canInsert(item, after: nil) { player.insert(item, after: nil) }
            attachStatusObserver(item)
        } else {
            currentURL = nil
            currentDelegate = nil
            statusCancellable = nil
        }
        isReplacing = false
        if offsetMs > 0 { seek(ms: offsetMs) }
        applyRate()
    }

    private func attachStatusObserver(_ item: AVPlayerItem?) {
        statusCancellable = item?.publisher(for: \.status).sink { [weak self] status in
            if status == .failed { self?.onError() }
        }
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
    }
}

