// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AVFoundation
import CoreMedia

/// Low-latency live player for go2rtc's fragmented-MP4 stream (`/api/stream.mp4`),
/// decoded by **VideoToolbox** (hardware H.265 *and* H.264) and rendered on an
/// `AVSampleBufferDisplayLayer` (Metal-backed). This is the smooth, full-res path
/// the native WebRTC build can't provide for H.265 — the same hardware decoder the
/// recorded-playback AVPlayer already uses.
///
/// We stream the endless fMP4 over a single HTTP GET, demux it incrementally
/// (`moov` → format description; `moof`+`mdat` → samples), and enqueue each access
/// unit for immediate display. go2rtc is unauthenticated, so the URL needs no token.
struct Fmp4VideoView: View {
    /// Stable identity (e.g. "cameraId:main") — the view restarts the stream when
    /// it changes (camera switch). The URL itself is minted per connect below.
    let streamKey: String
    /// Builds a fresh, authenticated (scoped-token) stream URL for each connect.
    let streamProvider: () async -> URL?
    let snapshotURL: URL?
    /// When false, the stream's AAC audio track (if any) is decoded and played;
    /// when true (the default — wall tiles, and single views before the operator
    /// taps "listen") the audio path is skipped entirely. Only the fullscreen
    /// single-camera view ever passes `false`.
    var muted: Bool = true
    /// M6 (iOS only — see `PictureInPicture.swift`): when supplied, this
    /// view attaches `controller.displayLayer` to it on appear so the caller
    /// can drive Picture-in-Picture for the live stream. `nil` (the default)
    /// for tile-sized uses (e.g. the wall grid) where PiP doesn't apply.
    #if os(iOS)
    var pip: LivePictureInPicture? = nil
    #endif

    @StateObject private var controller = Fmp4StreamController()
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        ZStack {
            Color.black

            if !controller.displaying {
                Fmp4SnapshotBackdrop(url: snapshotURL)
            }

            SampleBufferLayerView(layer: controller.displayLayer)
                .opacity(controller.displaying ? 1 : 0)

            if controller.failed && !controller.displaying {
                VStack(spacing: 4) {
                    Image(systemName: "wifi.exclamationmark").foregroundColor(CrumbColors.motionDot)
                    Text("Reconnecting…").font(.caption2).foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .onAppear {
            controller.setMuted(muted)
            controller.start(provider: streamProvider)
            #if os(iOS)
            pip?.attach(to: controller.displayLayer)
            #endif
        }
        .onChange(of: muted) { controller.setMuted($0) }
        #if os(iOS)
        .onDisappear {
            // Don't tear down PiP itself here — `LiveFullscreenView.onBack`
            // (the only navigation path away from this view) already handles
            // whether PiP should keep the feed alive. `detach()` here just
            // releases OUR reference; if PiP is genuinely still active the
            // system keeps its own strong reference until the user closes it.
            if pip?.isActive != true { pip?.detach() }
            if pip?.isActive != true { controller.stop() }
        }
        #else
        .onDisappear { controller.stop() }
        #endif
        .onChange(of: streamKey) { _ in
            controller.stop()
            controller.setMuted(muted)
            controller.start(provider: streamProvider)
        }
        #if os(iOS)
        // [iOS] H5 fix: `onAppear`/`onDisappear` don't fire when the app is
        // backgrounded — fullscreen live (`LiveFullscreenView`) uses this exact
        // `Fmp4VideoView`, and without this the HTTP demux connection kept
        // "streaming" into the background and resumed on a dead socket, freezing
        // the "live" view for up to the demux's own stall-detection timeout
        // (`Fmp4StreamController.scheduleReconnect`, ~5s cap — but only kicks in
        // once the OS actually errors the background socket, which can take much
        // longer). Mirrors `WebRTCVideoView`'s scenePhase teardown/reconnect
        // (WebRTCVideoView.swift), including the staggered-reconnect jitter so N
        // tiles resuming at once don't all hit go2rtc in the same instant.
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                // M6: PiP's entire purpose is to keep the live feed visible
                // while the app is backgrounded — don't tear down the stream
                // out from under it. `pip.isActive` is only true once the
                // system has actually started the PiP window (not merely
                // "possible"), so a background transition with no PiP window
                // up still gets the original H5 teardown behavior.
                if pip?.isActive != true {
                    controller.stop()
                }
            case .active:
                controller.setMuted(muted)
                controller.start(provider: streamProvider)
            default:
                break
            }
        }
        #endif
    }
}

// MARK: - Controller

@MainActor
final class Fmp4StreamController: NSObject, ObservableObject {

    /// True once the first decoded frame has been enqueued for display.
    @Published private(set) var displaying = false
    /// True while the connection is down / retrying (drives the reconnect hint).
    @Published private(set) var failed = false

    let displayLayer = AVSampleBufferDisplayLayer()

    // ── Audio (opt-in; only the fullscreen single-camera view unmutes) ────────
    /// Renders decoded AAC access units. Paced by `audioSynchronizer` so it plays
    /// at real-time regardless of how fast the demuxer hands us fragments.
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let audioSynchronizer = AVSampleBufferRenderSynchronizer()
    /// False = play audio when the stream carries it. Default muted: wall tiles
    /// and a freshly-opened single view stay silent until the operator opts in.
    private var muted = true
    /// True once the synchronizer's clock has been anchored to the first audio
    /// sample after (un)muting; reset on mute/stop so the next unmute re-anchors.
    private var audioAnchored = false
    /// Balances `CrumbAudioSession.acquire()`/`release()` so the shared session
    /// refcount can't leak across mute toggles / teardown.
    private var audioSessionHeld = false

    private var session: URLSession?
    private var task: URLSessionDataTask?
    /// Builds a fresh, authenticated (scoped-token) stream URL for each connect.
    private var provider: (() async -> URL?)?
    /// Bumped on every start()/stop() so a stale jittered/async connect bails.
    private var generation = 0
    private let demuxQueue = DispatchQueue(label: "video.crumb.fmp4.demux")
    private let demuxer = Fmp4Demuxer()
    private var reconnectAttempts = 0
    private var stopped = true

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        audioSynchronizer.addRenderer(audioRenderer)
        demuxer.onSample = { [weak self] sample in
            // Demux runs on the demux queue; UI + layer touch the main actor.
            DispatchQueue.main.async { self?.enqueue(sample) }
        }
        // `onAudioSample` is wired only while unmuted (see `setMuted`), so a muted
        // feed pays nothing for audio beyond the near-free moov scan.
    }

    // MARK: - Audio

    /// Turn the stream's audio on/off. Idempotent, and safe to call before
    /// `start()` — deliberately NOT guarded on an unchanged value: the view
    /// re-asserts the current mute state after every `stop()`/`start()` cycle
    /// (camera switch, foreground resume), which must re-wire the demuxer
    /// callback that `stop()` cleared.
    func setMuted(_ newValue: Bool) {
        muted = newValue
        if newValue {
            teardownAudio()
        } else {
            // Acquire the shared `.playback` session and start feeding the renderer
            // audio access units as the demuxer produces them.
            if !audioSessionHeld { CrumbAudioSession.acquire(); audioSessionHeld = true }
            audioAnchored = false
            demuxer.onAudioSample = { [weak self] sample in
                DispatchQueue.main.async { self?.enqueueAudio(sample) }
            }
        }
    }

    /// Feed one timed AAC sample to the renderer, anchoring the synchronizer clock
    /// to the first sample so playback starts immediately and stays real-time.
    private func enqueueAudio(_ sample: CMSampleBuffer) {
        guard !stopped, !muted else { return }
        if !audioAnchored {
            audioAnchored = true
            audioSynchronizer.setRate(1.0, time: sample.presentationTimeStamp)
        }
        if audioRenderer.isReadyForMoreMediaData {
            audioRenderer.enqueue(sample)
        }
        // If the renderer isn't ready (rare — audio is naturally real-time paced),
        // drop the sample rather than let latency grow unbounded.
    }

    /// Stop audio: unhook the demuxer callback, halt + flush the renderer, and
    /// release the shared audio session. Leaves `muted` untouched (callers set it).
    private func teardownAudio() {
        demuxer.onAudioSample = nil
        audioSynchronizer.setRate(0, time: .zero)
        audioRenderer.flush()
        audioRenderer.stopRequestingMediaData()
        audioAnchored = false
        if audioSessionHeld { CrumbAudioSession.release(); audioSessionHeld = false }
    }

    func start(provider: @escaping () async -> URL?) {
        self.provider = provider
        stopped = false
        reconnectAttempts = 0
        generation += 1
        let gen = generation
        // Stagger the initial connect by a small random delay so a wall of N tiles
        // doesn't cold-start N live streams in the same instant (a thundering herd
        // that overwhelms go2rtc's RTSP pulls → first-byte timeouts).
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0...0.8)) { [weak self] in
            guard let self, !self.stopped, self.generation == gen else { return }
            self.connect()
        }
    }

    func stop() {
        stopped = true
        generation += 1
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        demuxQueue.async { [demuxer] in demuxer.reset() }
        displayLayer.flushAndRemoveImage()
        // Release the audio session + flush the renderer whenever the stream
        // stops (disappear, background, camera switch). `muted` is preserved, so
        // the view's post-start `setMuted(muted)` re-arms audio if still unmuted.
        teardownAudio()
        displaying = false
        failed = false
    }

    private func connect() {
        guard !stopped, let provider else { return }
        task?.cancel()
        session?.finishTasksAndInvalidate()
        demuxQueue.async { [demuxer] in demuxer.reset() }
        displaying = false
        // Drop any audio buffered from the prior connection and re-anchor the
        // synchronizer clock to the reconnected stream's first sample (its PTS
        // timeline restarts), so audio isn't stuck waiting on a stale clock.
        if !muted {
            audioAnchored = false
            audioRenderer.flush()
        }
        let gen = generation
        // Mint a FRESH scoped-token stream URL for this connect (tokens are
        // short-lived; a persistent stream may reconnect after the last expired).
        Task { @MainActor in
            guard let url = await provider(), !self.stopped, self.generation == gen else {
                if !self.stopped, self.generation == gen { self.scheduleReconnect() }
                return
            }
            let cfg = URLSessionConfiguration.ephemeral
            // Generous first-byte budget: go2rtc may take several seconds to
            // cold-start an RTSP pull + first keyframe, longer for a full wall.
            cfg.timeoutIntervalForRequest = 30
            cfg.networkServiceType = .video
            cfg.httpShouldUsePipelining = true
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            self.session = s
            var req = URLRequest(url: url)
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding") // never gzip a live stream
            let t = s.dataTask(with: req)
            self.task = t
            t.resume()
        }
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        guard !stopped else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
        if !displaying {
            displaying = true
            failed = false
            reconnectAttempts = 0
        }
    }

    /// The stream ended or errored — back off briefly and reconnect.
    private func scheduleReconnect() {
        guard !stopped else { return }
        failed = true
        reconnectAttempts += 1
        // Exponential-ish backoff PLUS random jitter so tiles that dropped together
        // don't reconnect in lockstep (a synchronized herd that keeps colliding).
        let backoff = min(Double(reconnectAttempts) * 0.6, 5.0)
        let delay = backoff + Double.random(in: 0...0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.connect()
        }
    }

    deinit {
        task?.cancel()
        session?.invalidateAndCancel()
    }
}

extension Fmp4StreamController: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        demuxQueue.async { [demuxer] in demuxer.feed(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Any completion of a live stream is unexpected (it should run forever) —
        // unless we cancelled it ourselves on stop().
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        Task { @MainActor in self.scheduleReconnect() }
    }
}

// MARK: - SwiftUI host for the display layer

private struct SampleBufferLayerView: PlatformViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    #if os(macOS)
    func makeNSView(context: Context) -> HostView {
        let v = HostView(); v.hosted = layer; return v
    }
    func updateNSView(_ view: HostView, context: Context) {
        if view.hosted !== layer { view.hosted = layer }
    }
    #else
    func makeUIView(context: Context) -> HostView {
        let v = HostView(); v.backgroundColor = .black; v.hosted = layer; return v
    }
    func updateUIView(_ view: HostView, context: Context) {
        if view.hosted !== layer { view.hosted = layer }
    }
    #endif

    #if os(macOS)
    final class HostView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        var hosted: AVSampleBufferDisplayLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted, let layer { hosted.frame = bounds; layer.addSublayer(hosted) }
            }
        }
        override func layout() {
            super.layout()
            hosted?.frame = bounds
        }
    }
    #else
    final class HostView: UIView {
        var hosted: AVSampleBufferDisplayLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { hosted.frame = bounds; layer.addSublayer(hosted) }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
    #endif
}

// MARK: - Snapshot backdrop (shown until the first frame decodes)

private struct Fmp4SnapshotBackdrop: View {
    let url: URL?
    @State private var image: PlatformImage?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(CrumbColors.tealAccent)
            }
        }
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        pollTask?.cancel()
        guard let url else { return }
        pollTask = Task { @MainActor in
            for _ in 0..<3 {
                if Task.isCancelled { return }
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.timeoutInterval = 5
                if let (data, _) = try? await URLSession.crumbMedia.data(for: req), let img = PlatformImage(data: data) {
                    image = img; return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
