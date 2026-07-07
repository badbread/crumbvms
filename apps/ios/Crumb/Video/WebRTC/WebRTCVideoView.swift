// SPDX-License-Identifier: AGPL-3.0-or-later

#if canImport(WebRTC)
import SwiftUI
import WebRTC

/// Renders a WebRTC camera stream with a snapshot backdrop that fades out the
/// moment the first decoded frame arrives — eliminating the black-screen window
/// during peer-connection setup (~100-300ms on LAN).
///
/// This is the single entry point for live video in the app. It owns a
/// `WebRTCManager`, connects on appear, and tears down on disappear.
struct WebRTCVideoView: View {

    let cameraId: String
    let mediaUrls: MediaUrls
    let fill: Bool

    @StateObject private var manager: WebRTCManager
    @Environment(\.scenePhase) private var scenePhase

    init(cameraId: String, mediaUrls: MediaUrls, hasSub: Bool, fill: Bool = false) {
        self.cameraId = cameraId
        self.mediaUrls = mediaUrls
        self.fill = fill
        // The manager mints a fresh authenticated (scoped-token) WHEP URL for each
        // signaling POST. When the camera has a sub stream we prefer it (lighter,
        // usually H.264 → native-decodable) with main as the fallback; otherwise
        // main is primary with no fallback.
        _manager = StateObject(wrappedValue: WebRTCManager(
            primaryProvider: { await mediaUrls.liveWhepURL(cameraId: cameraId, sub: hasSub) },
            fallbackProvider: hasSub ? { await mediaUrls.liveWhepURL(cameraId: cameraId, sub: false) } : nil
        ))
    }

    var body: some View {
        ZStack {
            Color.black

            // Backdrop snapshot — shown until the first WebRTC frame decodes.
            // Resolves its own scoped media-token URL and re-resolves it
            // every poll (P0-SESSIONS): if WebRTC never connects (persistent
            // "Reconnecting…"), this can poll far longer than the ~15 min token
            // TTL.
            if !manager.hasFirstFrame {
                SnapshotBackdropView(cameraId: cameraId, mediaUrls: mediaUrls, fill: fill)
            }

            if let track = manager.videoTrack {
                RTCVideoRendererView(
                    track: track,
                    fill: fill,
                    onFirstFrame: { manager.markFirstFrame() }
                )
                .opacity(manager.hasFirstFrame ? 1 : 0)
            }

            if case .incompatibleCodec = manager.state {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(CrumbColors.motionDot)
                    Text("Incompatible codec")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                }
            } else if case .failed = manager.state, !manager.hasFirstFrame {
                VStack(spacing: 4) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundColor(CrumbColors.motionDot)
                    Text("Reconnecting…")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .onAppear { manager.connect() }
        .onDisappear { manager.disconnect() }
        // onAppear/onDisappear don't fire on app background, so the peer
        // connection would otherwise keep streaming in the background and resume
        // on a dead socket. Tear down on background; reconnect on foreground.
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                manager.disconnect()
            case .active:
                // Stagger reconnects across the wall's N tiles so they don't all
                // hammer go2rtc at the same instant on resume.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0...0.6) * 1_000_000_000))
                    manager.connect()
                }
            default:
                break
            }
        }
    }
}

// MARK: - Metal renderer wrapper

/// Wraps `RTCMTLVideoView` (hardware-accelerated Metal renderer). Attaches the
/// remote track and fires `onFirstFrame` when the first frame establishes size.
private struct RTCVideoRendererView: UIViewRepresentable {

    let track: RTCVideoTrack
    let fill: Bool
    let onFirstFrame: () -> Void

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        view.delegate = context.coordinator
        view.clipsToBounds = true
        // Metal renderer renders rotated content correctly for camera feeds.
        track.add(view)
        context.coordinator.attachedTrack = track
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        if context.coordinator.attachedTrack !== track {
            context.coordinator.attachedTrack.map { track in track.remove(uiView) }
            track.add(uiView)
            context.coordinator.attachedTrack = track
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attachedTrack?.remove(uiView)
        coordinator.attachedTrack = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFirstFrame: onFirstFrame) }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var attachedTrack: RTCVideoTrack?
        private let onFirstFrame: () -> Void
        private var fired = false

        init(onFirstFrame: @escaping () -> Void) {
            self.onFirstFrame = onFirstFrame
        }

        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard !fired, size.width > 0, size.height > 0 else { return }
            fired = true
            Task { @MainActor in onFirstFrame() }
        }
    }
}

// MARK: - Snapshot backdrop

/// Polls the camera's `/frame.jpg` at ~1 fps so the tile shows something
/// immediately while WebRTC negotiates.
private struct SnapshotBackdropView: View {
    let cameraId: String
    let mediaUrls: MediaUrls
    let fill: Bool
    @State private var image: PlatformImage?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                ProgressView().tint(CrumbColors.tealAccent)
            }
        }
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                // Re-resolved every poll tick (P0-SESSIONS): WebRTC can stay
                // in "Reconnecting…" far longer than the ~15 min scoped-token
                // TTL, so this loop must never reuse a URL across ticks.
                // `MediaTokenCache` makes the common case (token still fresh)
                // a cheap in-memory hit.
                guard let url = await mediaUrls.cameraFrameUrl(cameraId) else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.timeoutInterval = 5
                if let (data, resp) = try? await URLSession.crumbMedia.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let img = PlatformImage(data: data) {
                    image = img
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
#endif
