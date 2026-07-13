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
            // Restore this camera's remembered audio choice (default off).
            audioOn = vm.container.settings.audioEnabled(for: camera.id)
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
    }

    /// `Fmp4VideoView` construction, split out because its `pip:` parameter
    /// only exists on iOS (`#if os(iOS)` in `Fmp4Player.swift`) — a single
    /// call site can't straddle that with a mid-argument-list `#if`.
    @ViewBuilder
    private func fmp4View(urls: MediaUrls, frameUrl: URL?) -> some View {
        // Fullscreen shows the MAIN (full-res) stream; the URL is minted per
        // connect through the authenticated /live proxy.
        let cameraId = camera.id
        #if os(iOS)
        Fmp4VideoView(
            streamKey: cameraId,
            streamProvider: { await urls.liveFmp4URL(cameraId: cameraId, sub: false) },
            snapshotURL: frameUrl,
            muted: !audioOn,
            pip: pip
        )
        #else
        Fmp4VideoView(
            streamKey: cameraId,
            streamProvider: { await urls.liveFmp4URL(cameraId: cameraId, sub: false) },
            snapshotURL: frameUrl,
            muted: !audioOn
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

                // Secondary actions in a menu — keeps the bar uncluttered
                Menu {
                    Button {
                        Task { await takeSnapshot() }
                    } label: {
                        Label("Snapshot", systemImage: "camera.fill")
                    }

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
        let urls = vm.mediaUrls()
        guard let frameUrl = await urls.cameraFrameUrl(camera.id) else { return }
        do {
            var req = URLRequest(url: frameUrl)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 8
            let (data, response) = try await URLSession.crumbMedia.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let image = PlatformImage(data: data) else { return }
            try await saveToPhotos(image)
            withAnimation { showSavedToast = true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { showSavedToast = false }
        } catch {
            // Silently ignore denied / already-shown system alert
        }
    }

    // MARK: - Camera navigation

    /// Switch to the next/prev camera in the list (the webview owns pan/zoom
    /// gestures, so camera-switching is via buttons rather than an edge swipe).
    private func stepCamera(_ direction: Int) {
        guard let idx = cameras.firstIndex(where: { $0.id == camera.id }), cameras.count > 1 else { return }
        let next = (idx + direction + cameras.count) % cameras.count
        onSwipeCamera(cameras[next].id)
    }
}

