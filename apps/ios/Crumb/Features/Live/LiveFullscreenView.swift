// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AVKit
import SwiftUI

struct LiveFullscreenView: View {

    let camera: CameraDto
    let cameras: [CameraDto]
    @ObservedObject var vm: LiveViewModel
    let onBack: () -> Void
    let onSwipeCamera: (String) -> Void
    let onOpenPlayback: (String) -> Void

    @State private var isPtz = false
    @State private var ptzPresets: [PtzPresetDto] = []
    /// Live audio on/off for the current camera, restored from the per-camera
    /// preference and threaded into `Fmp4VideoView` as `muted: !audioOn`.
    @State private var audioOn = false
    /// Scoped (~15 min-token) snapshot-backdrop URL, resolved async — see
    /// `.task(id: camera.id)` below. `cameraFrameUrl` used to be a synchronous
    /// full-JWT URL built inline in `body`; minting the scoped token requires
    /// an await, so it's now state refreshed whenever the camera changes.
    @State private var frameUrl: URL?

    // Snapshot toast
    @State private var showSavedToast = false

    // PTZ presets sheet
    @State private var showPresetsSheet = false

    // Motion tuner sheet
    @State private var showTuner = false

    /// Selected media quality (Full/Data-saver/Auto), loaded from the secure
    /// store; the chip cycles + persists it. On a metered link (or Data-saver)
    /// the fullscreen feed switches to the native sub stream.
    @State private var quality: PlaybackQuality = .fallback
    /// App-wide metered signal, observed so `.auto` re-selects the stream live
    /// when the link flips metered mid-session.
    @ObservedObject private var connectivity: ConnectivityMonitor

    /// Home Assistant entity links + live states for on-video badges + sheet.
    @StateObject private var ha: HAController
    @State private var haVideoSize: CGSize?
    @State private var showHASheet = false
    #if os(iOS)
    @State private var shareItem: ShareImageItem?
    #endif

    /// M6: Picture-in-Picture for the live feed (iOS only — see
    /// `PictureInPicture.swift`; macOS has no PiP concept here, matching the
    /// desktop Tauri client).
    #if os(iOS)
    @StateObject private var pip = LivePictureInPicture()
    #endif

    init(camera: CameraDto, cameras: [CameraDto], vm: LiveViewModel,
         onBack: @escaping () -> Void,
         onSwipeCamera: @escaping (String) -> Void,
         onOpenPlayback: @escaping (String) -> Void) {
        self.camera = camera
        self.cameras = cameras
        self.vm = vm
        self.onBack = onBack
        self.onSwipeCamera = onSwipeCamera
        self.onOpenPlayback = onOpenPlayback
        _connectivity = ObservedObject(wrappedValue: vm.container.connectivity)
        _ha = StateObject(wrappedValue: HAController(container: vm.container))
    }

    var body: some View {
        let urls = vm.mediaUrls()

        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Smooth, full-res live: go2rtc's fragmented-MP4 (passthrough codec —
                // H.265 stays H.265) decoded by VideoToolbox hardware on an
                // AVSampleBufferDisplayLayer. Replaces the choppy WKWebView path that
                // the native WebRTC build's missing H.265 decoder forced. The stream
                // URL carries the go2rtc name from the auth-scoped streams resolve.
                // Fmp4VideoView shows its own snapshot backdrop until the first frame.
                fmp4View(urls: urls, frameUrl: frameUrl)
                    .id(camera.id)
                    .ignoresSafeArea()
                // Digital zoom (scroll/pinch) for fixed cameras; PTZ cameras zoom
                // physically via their own drag controls, so don't fight them.
                .zoomable(enabled: !isPtz)

                // Home Assistant entity badges over the video (empty areas pass
                // taps through to the video/zoom below; badges tap → detail card).
                HAOverlayLayer(controller: ha, videoSize: haVideoSize)
                    .ignoresSafeArea()

                if isPtz {
                    ptzLayer
                }

                // Controls stay visible AND on top of the PTZ layer — a security
                // viewer must never be trapped, and the back / prev / next buttons
                // must win taps over the PTZ wheel/edge arrows.
                controlsOverlay

                // "Saved to Photos" toast
                if showSavedToast {
                    VStack {
                        Spacer()
                        Text("Saved to Photos")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(Color.black.opacity(0.72))
                            )
                            .padding(.bottom, 48)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
        }
        .statusBarHiddenCompat(true)
        .task(id: camera.id) {
            // Restore this camera's remembered audio choice (default off) + quality.
            audioOn = vm.container.settings.audioEnabled(for: camera.id)
            quality = PlaybackQuality(persisted: vm.container.store.playbackQuality)
            haVideoSize = nil
            ha.activate(cameraId: camera.id)
            frameUrl = nil
            frameUrl = await vm.mediaUrls().cameraFrameUrl(camera.id)
        }
        .task(id: camera.id) {
            await vm.ensureStream(camera.id)
            // PTZ controls require the `ptz` capability (admins implicitly have it).
            // Then, like Android, probe the camera: the controls show whenever the
            // camera is PTZ-capable — a successful probe OR the DTO's `ptz` flag —
            // NOT only when it has saved presets (a PTZ camera can have none).
            let mayPtzUser = vm.container.isAdmin || vm.container.capabilities.ptz
            guard mayPtzUser else { isPtz = false; ptzPresets = []; return }
            let probe = await vm.ptzPresets(cameraId: camera.id)   // nil = not PTZ
            isPtz = camera.ptzSupported || (probe != nil)
            ptzPresets = probe ?? []
        }
        .sheet(isPresented: $showPresetsSheet) {
            ptzPresetsSheet
        }
        .sheet(isPresented: $showTuner) {
            MotionTunerView(
                container: vm.container,
                cameraId: camera.id,
                onClose: { showTuner = false }
            )
        }
        .sheet(isPresented: $showHASheet) {
            HAEntitySheet(controller: ha, cameraName: camera.name)
                .macModalSize(width: 420, height: 560)
        }
        #if os(iOS)
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.image])
        }
        #endif
        .onDisappear { ha.stop() }
    }

    /// Whether to serve the low-bitrate variant for this camera right now —
    /// the resolved Full/Data-saver/Auto choice against the metered signal.
    private var useLow: Bool {
        quality.useLow(metered: connectivity.isMetered)
    }

    /// On a metered link (or explicit Data-saver) prefer the camera's native
    /// **sub** stream — already low-res H.264 and, unlike the go2rtc `_mobile`
    /// transcode, reachable through the fMP4 proxy (`stream=sub`). This mirrors
    /// the first half of Android's `rtsp_sub_url ?? rtsp_mobile_url`. A camera
    /// with NO sub stays on main: the `_mobile` transcode (Android's fallback)
    /// is NOT reachable from iOS's fMP4/WebRTC live path — see `rtspMobileUrl`
    /// in `LiveStreamsResponse` and the task note.
    private var useSubStream: Bool { useLow && camera.hasSubStream }

    /// `Fmp4VideoView` construction, split out because its `pip:` parameter
    /// only exists on iOS (`#if os(iOS)` in `Fmp4Player.swift`) — a single
    /// call site can't straddle that with a mid-argument-list `#if`.
    @ViewBuilder
    private func fmp4View(urls: MediaUrls, frameUrl: URL?) -> some View {
        // Fullscreen shows MAIN (full-res) on an unmetered link / Full quality,
        // and the native SUB (low-res) on a metered link / Data-saver. The
        // stream key encodes the choice so flipping quality restarts the stream.
        let cameraId = camera.id
        let sub = useSubStream
        let key = "\(cameraId):\(sub ? "sub" : "main")"
        #if os(iOS)
        Fmp4VideoView(
            streamKey: key,
            streamProvider: { await urls.liveFmp4URL(cameraId: cameraId, sub: sub) },
            snapshotURL: frameUrl,
            muted: !audioOn,
            onVideoSize: { haVideoSize = $0 },
            pip: pip
        )
        #else
        Fmp4VideoView(
            streamKey: key,
            streamProvider: { await urls.liveFmp4URL(cameraId: cameraId, sub: sub) },
            snapshotURL: frameUrl,
            muted: !audioOn,
            onVideoSize: { haVideoSize = $0 }
        )
        #endif
    }

    // MARK: - PTZ layer (respects the ptzStyle setting)

    @ViewBuilder
    private var ptzLayer: some View {
        if vm.container.settings.ptzStyle == "edges" {
            PTZEdgesView(
                onMove: { pan, tilt in
                    Task { await vm.ptzMove(cameraId: camera.id, pan: pan, tilt: tilt) }
                },
                onStop: {
                    Task { await vm.ptzStop(cameraId: camera.id) }
                },
                onHome: {
                    Task { await vm.ptzHome(cameraId: camera.id) }
                },
                onZoom: { z in
                    Task { await vm.ptzMove(cameraId: camera.id, pan: 0, tilt: 0, zoom: z * 0.6) }
                },
                onZoomStop: {
                    Task { await vm.ptzStop(cameraId: camera.id) }
                }
            )
        } else {
            VStack {
                Spacer()
                PTZWheelView(
                    onMove: { pan, tilt in
                        Task { await vm.ptzMove(cameraId: camera.id, pan: pan, tilt: tilt) }
                    },
                    onStop: {
                        Task { await vm.ptzStop(cameraId: camera.id) }
                    },
                    onHome: {
                        Task { await vm.ptzHome(cameraId: camera.id) }
                    },
                    onZoom: { z in
                        Task { await vm.ptzMove(cameraId: camera.id, pan: 0, tilt: 0, zoom: z * 0.6) }
                    },
                    onZoomStop: {
                        Task { await vm.ptzStop(cameraId: camera.id) }
                    }
                )
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - Controls overlay

    @ViewBuilder
    private var controlsOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.black.opacity(0.45))
                        .clipShape(Circle())
                }

                Text(camera.name)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)

                // Status indicators — small dots only
                if let status = vm.cameraStatuses[camera.id] {
                    HStack(spacing: 6) {
                        if status.recording {
                            Circle().fill(CrumbColors.recDot).frame(width: 8, height: 8)
                        }
                        if status.recentMotion {
                            Circle().fill(CrumbColors.motionDot).frame(width: 8, height: 8)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Quality chip (Auto → Full → Data saver): on a metered link /
                // Data-saver the fullscreen feed uses the native sub stream.
                Button {
                    quality = quality.next
                    vm.container.store.playbackQuality = quality.rawValue
                } label: {
                    Text(quality.short)
                        .font(.caption.bold())
                        .foregroundColor(quality == .auto ? .white : CrumbColors.tealAccent)
                        .frame(minWidth: 34, minHeight: 30)
                }
                .accessibilityLabel("Quality: \(quality.label)")

                // M6: Picture-in-Picture toggle (iOS only) — lets the operator
                // keep watching this camera while backgrounding the app or
                // navigating elsewhere.
                #if os(iOS)
                if pip.isPossible {
                    Button {
                        if pip.isActive { pip.stop() } else { pip.start() }
                    } label: {
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel(pip.isActive ? "Exit Picture in Picture" : "Enter Picture in Picture")
                }
                #endif

                // Prev / next camera.
                if cameras.count > 1 {
                    Button { stepCamera(-1) } label: {
                        Image(systemName: "chevron.backward.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                    Button { stepCamera(1) } label: {
                        Image(systemName: "chevron.forward.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                }

                // Audio toggle (top-right): enable/disable live sound for THIS
                // camera. Remembered per camera; plays only if the stream carries
                // an audio track (see `Fmp4Demuxer`/go2rtc transcode).
                Button {
                    audioOn.toggle()
                    vm.container.settings.setAudioEnabled(audioOn, for: camera.id)
                } label: {
                    Image(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                        .foregroundColor(audioOn ? CrumbColors.tealAccent : .white)
                }
                .accessibilityLabel(audioOn ? "Mute audio" : "Unmute audio")

                // Home Assistant entity sheet — shown only when this camera has
                // linked entities (read-only list of states).
                if ha.hasLinks {
                    Button { showHASheet = true } label: {
                        Image(systemName: "house.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("Home Assistant entities")
                }

                // Secondary actions in a menu — keeps the bar uncluttered
                Menu {
                    Button {
                        Task { await takeSnapshot() }
                    } label: {
                        Label("Snapshot", systemImage: "camera.fill")
                    }
                    #if os(iOS)
                    Button {
                        Task { await shareSnapshot() }
                    } label: {
                        Label("Share snapshot", systemImage: "square.and.arrow.up")
                    }
                    #endif

                    if vm.container.isAdmin || vm.container.capabilities.playback {
                        Button {
                            onOpenPlayback(camera.id)
                        } label: {
                            Label("Open playback", systemImage: "film.stack")
                        }
                    }

                    if !ptzPresets.isEmpty {
                        Button {
                            showPresetsSheet = true
                        } label: {
                            Label("PTZ presets", systemImage: "list.star")
                        }
                    }

                    if vm.store.isAdmin && vm.container.settings.motionTunerEnabled {
                        Button {
                            showTuner = true
                        } label: {
                            Label("Motion tuner", systemImage: "slider.horizontal.3")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.black.opacity(0.45))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - PTZ presets sheet

    private var ptzPresetsSheet: some View {
        NavigationView {
            List(ptzPresets, id: \.token) { preset in
                HStack {
                    Text(preset.name.isEmpty ? preset.token : preset.name)
                        .foregroundColor(CrumbColors.textPrimary)
                    Spacer()
                    Button("Recall") {
                        showPresetsSheet = false
                        Task { await vm.ptzRecallPreset(cameraId: camera.id, presetToken: preset.token) }
                    }
                    .foregroundColor(CrumbColors.tealAccent)
                }
            }
            .listStyle(.plain)
            .background(CrumbColors.background)
            .navigationTitle("PTZ Presets")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .barTrailing) {
                    Button("Done") { showPresetsSheet = false }
                        .foregroundColor(CrumbColors.tealAccent)
                }
            }
        }
        .macModalSize(width: 420, height: 520)
    }

    // MARK: - Snapshot

    /// Grabs the current frame from the server's `/frame.jpg` proxy (always works,
    /// codec-agnostic) and saves it to Photos. Simpler + more reliable than tapping
    /// the WebRTC pixel pipeline.
    private func takeSnapshot() async {
        guard let image = await fetchFrameImage() else { return }
        do {
            try await saveToPhotos(image)
            withAnimation { showSavedToast = true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { showSavedToast = false }
        } catch {
            // Silently ignore denied / already-shown system alert
        }
    }

    /// Fetch the current frame from the server's codec-agnostic `/frame.jpg`
    /// proxy (works regardless of the live decode path).
    private func fetchFrameImage() async -> PlatformImage? {
        let urls = vm.mediaUrls()
        guard let frameUrl = await urls.cameraFrameUrl(camera.id) else { return nil }
        var req = URLRequest(url: frameUrl)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.crumbMedia.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let image = PlatformImage(data: data) else { return nil }
        return image
    }

    #if os(iOS)
    /// Capture the current frame and hand it to the system share sheet
    /// (Android #166 parity — share via any installed target).
    private func shareSnapshot() async {
        guard let image = await fetchFrameImage() else { return }
        shareItem = ShareImageItem(image: image)
    }
    #endif

    // MARK: - Camera navigation

    /// Switch to the next/prev camera in the list (the webview owns pan/zoom
    /// gestures, so camera-switching is via buttons rather than an edge swipe).
    private func stepCamera(_ direction: Int) {
        guard let idx = cameras.firstIndex(where: { $0.id == camera.id }), cameras.count > 1 else { return }
        let next = (idx + direction + cameras.count) % cameras.count
        onSwipeCamera(cameras[next].id)
    }
}


#if os(iOS)
/// Identifiable wrapper so a captured snapshot can drive `.sheet(item:)` for the
/// system share sheet.
struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: PlatformImage
}
#endif
