// SPDX-License-Identifier: AGPL-3.0-or-later

#if canImport(WebRTC)
import Foundation
import Network
import WebRTC

/// Owns a single WebRTC peer connection to one go2rtc camera stream via the
/// WHEP (WebRTC-HTTP Egress Protocol) signaling flow.
///
/// Flow (proven against go2rtc 1.9.14):
/// 1. Create an `RTCPeerConnection` with a recvonly video transceiver.
/// 2. Generate an SDP offer advertising **both H.265 and H.264** so go2rtc can
///    match the camera's native codec.
/// 3. POST the offer to `…/api/webrtc?src=<go2rtcName>` with `Content-Type:
///    application/sdp`. go2rtc replies `201` + the SDP answer.
/// 4. Set the answer as the remote description; the video track starts flowing.
///
/// Resilience:
/// - A **frame-arrival watchdog** (a counting renderer attached alongside the
///   Metal view) detects a frozen feed even while ICE stays "connected", and a
///   negotiated-but-never-decoded stream (an H.265 main this native build can't
///   decode) — surfacing `.incompatibleCodec` instead of a permanent black frame.
/// - Reconnect is **idempotent**: a single `signalingTask` and an `isNegotiating`
///   latch prevent overlapping `negotiate()` runs from leaking peer connections.
///
/// One manager == one camera tile. The wall creates N of these; fullscreen one.
@MainActor
final class WebRTCManager: NSObject, ObservableObject {

    /// The remote video track, published so the SwiftUI view can attach it to a
    /// renderer the moment it arrives.
    @Published private(set) var videoTrack: RTCVideoTrack?
    /// True once the first frame has been decoded and rendered.
    @Published private(set) var hasFirstFrame = false
    /// Human-readable connection state for debugging / fallback decisions.
    @Published private(set) var state: ConnectionState = .idle

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        /// Negotiated, but no decodable frame ever arrived and no usable fallback
        /// exists — almost always an H.265 stream the native renderer can't decode.
        /// Surfaced instead of a black frame that would read as "live".
        case incompatibleCodec
    }

    // Shared factory — expensive to create, safe to reuse across connections.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    private var peerConnection: RTCPeerConnection?
    /// Async providers that mint a fresh, authenticated (scoped-token) WHEP URL
    /// for each signaling POST — the API's `/live/{id}/webrtc` proxy is JWT-gated
    /// and reconnects may happen after the last token expired.
    private let primaryProvider: () async -> URL?
    private let fallbackProvider: (() async -> URL?)?
    private var hasFallback: Bool { fallbackProvider != nil }
    /// Once the primary (main, possibly H.265) yields no decodable frames, we pin
    /// to the fallback (H.264 sub) so reconnects don't keep retrying the dead codec.
    private var usingFallback = false
    private var signalingTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var teardownCalled = false
    /// Guards against overlapping `negotiate()` runs (the source of leaked PCs).
    private var isNegotiating = false

    // ── Frame-arrival watchdog ────────────────────────────────────────────────
    private let frameTick = FrameTickRenderer()
    private var watchdogTask: Task<Void, Never>?
    private var lastSeenFrameCount: UInt64 = 0
    private var stalledChecks = 0

    // ── Connectivity monitor (C4) ─────────────────────────────────────────────
    /// Independent of the backoff timer: when the OS reports the network path
    /// transitioned to `.satisfied` while we're mid-reconnect, jump straight to an
    /// immediate retry instead of waiting out whatever backoff delay is queued —
    /// the common case being "phone left the LAN's Wi-Fi and came back".
    private var pathMonitor: NWPathMonitor?
    private var pathWasSatisfied = true

    /// Resolve a fresh WHEP URL for the current attempt (primary, or the fallback
    /// once pinned). Awaited before each signaling POST so the token is never stale.
    private func resolveWhepURL() async -> URL? {
        if usingFallback, let fallbackProvider { return await fallbackProvider() }
        return await primaryProvider()
    }

    /// - Parameters:
    ///   - primaryProvider: Mints the primary WHEP URL (main, possibly H.265).
    ///   - fallbackProvider: Mints the alternate (H.264 sub) URL, tried automatically
    ///     if the primary negotiates but never produces a decodable frame. `nil`
    ///     disables fallback (that case then surfaces `.incompatibleCodec`).
    init(primaryProvider: @escaping () async -> URL?, fallbackProvider: (() async -> URL?)? = nil) {
        self.primaryProvider = primaryProvider
        self.fallbackProvider = fallbackProvider
        super.init()
    }

    func connect() {
        // Reset the teardown latch so a tile that scrolled off-screen (which
        // called disconnect()) reconnects cleanly when it scrolls back into view.
        teardownCalled = false
        reconnectAttempts = 0
        usingFallback = false
        startPathMonitor()
        guard peerConnection == nil, !isNegotiating else { return }
        state = .connecting
        scheduleReconnect(immediate: true)
    }

    func disconnect() {
        teardownCalled = true
        signalingTask?.cancel(); signalingTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        stopPathMonitor()
        videoTrack = nil
        peerConnection?.close(); peerConnection = nil
        hasFirstFrame = false
        state = .idle
    }

    /// [iOS] C4 fix (companion to the uncapped `scheduleReconnect` below): watch
    /// for the network path coming back up while we're mid-outage and short-circuit
    /// straight to an immediate reconnect attempt, rather than waiting out the
    /// current backoff delay (up to 15s) before noticing connectivity is back.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                let wasDown = !self.pathWasSatisfied
                self.pathWasSatisfied = satisfied
                guard satisfied, wasDown, !self.teardownCalled else { return }
                // Connectivity just came back after being down. If we're not
                // already streaming, force an immediate reconnect.
                if !self.hasFirstFrame {
                    self.reconnectAttempts = 0
                    self.peerConnection?.close(); self.peerConnection = nil
                    self.scheduleReconnect(immediate: true)
                }
            }
        }
        monitor.start(queue: .main)
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathWasSatisfied = true
    }

    /// Called by the renderer when the first decoded frame establishes a size.
    func markFirstFrame() {
        guard !hasFirstFrame else { return }
        hasFirstFrame = true
        state = .connected
    }

    // MARK: - Negotiation

    private func negotiate() async {
        guard !teardownCalled, !isNegotiating else { return }
        isNegotiating = true
        defer { isNegotiating = false }

        // Idempotent: tear down any prior PC before creating a new one so a racing
        // reconnect can never orphan an RTCPeerConnection.
        peerConnection?.close()
        peerConnection = nil

        let config = RTCConfiguration()
        // LAN-first: no STUN/TURN needed. host candidates resolve directly.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            state = .failed("Failed to create peer connection")
            return
        }
        peerConnection = pc

        // recvonly VIDEO only. We deliberately do NOT request audio: libwebrtc's
        // iOS audio device module initializes the duplex Voice-Processing I/O unit,
        // which forces a microphone-permission prompt even for receive-only
        // playback. A camera viewer must never ask for the mic.
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: videoInit)

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "false",
            ],
            optionalConstraints: nil
        )

        do {
            let offer = try await pc.offer(for: offerConstraints)
            try await pc.setLocalDescription(offer)

            // Wait for ICE gathering to complete (gatherOnce → fast on LAN), so the
            // offer we POST contains host candidates. go2rtc doesn't trickle.
            await waitForIceGathering(pc)
            guard !Task.isCancelled, !teardownCalled else { return }

            guard let localSDP = pc.localDescription?.sdp else {
                state = .failed("No local SDP")
                return
            }

            let answerSDP = try await postOffer(localSDP)
            guard !Task.isCancelled, !teardownCalled else { return }

            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            try await pc.setRemoteDescription(answer)
            guard !Task.isCancelled, !teardownCalled else { return }

            // Negotiated — frames should begin. Arm the watchdog to catch a stream
            // that connects but never decodes (codec) or freezes mid-stream.
            startWatchdog()
        } catch {
            guard !Task.isCancelled, !teardownCalled else { return }

            // Hard SDP/codec negotiation failure → switch to the fallback once and
            // retry immediately. (A successfully-negotiated-but-undecodable H.265
            // stream is caught later by the watchdog, not here.)
            if !usingFallback, hasFallback, isCodecMismatch(error) {
                usingFallback = true
                reconnectAttempts = 0
                scheduleReconnect(immediate: true)
                return
            }

            state = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private func isCodecMismatch(_ error: Error) -> Bool {
        guard case WebRTCError.signaling(let msg) = error else { return false }
        return msg.localizedCaseInsensitiveContains("codecs not matched")
            || msg.localizedCaseInsensitiveContains("500")
    }

    /// POST the SDP offer to go2rtc's WHEP endpoint, return the answer SDP.
    private func postOffer(_ sdp: String) async throws -> String {
        guard let url = await resolveWhepURL() else {
            throw WebRTCError.signaling("could not build authenticated WHEP URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.setValue("application/sdp", forHTTPHeaderField: "Accept")
        req.httpBody = sdp.data(using: .utf8)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw WebRTCError.signaling("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WebRTCError.signaling("go2rtc \(http.statusCode): \(body)")
        }
        guard let answer = String(data: data, encoding: .utf8), !answer.isEmpty else {
            throw WebRTCError.signaling("Empty answer SDP")
        }
        return answer
    }

    private func waitForIceGathering(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        // Poll briefly — on a LAN this completes in well under a second.
        for _ in 0..<40 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pc.iceGatheringState == .complete { return }
        }
    }

    /// Single funnel for every reconnect path (initial connect, ICE failure,
    /// signaling error, watchdog). Cancels any in-flight signaling task first so
    /// only one negotiation is ever scheduled.
    ///
    /// [iOS] C4 fix: previously hard-stopped after 10 attempts (`state = .failed`,
    /// nothing ever rearmed it) while the UI kept showing "Reconnecting…" forever —
    /// a prolonged outage (camera reboot, NVR restart, brief LAN partition lasting
    /// longer than ~10 backoff cycles) permanently wedged the tile even after
    /// connectivity returned; only leaving/re-entering the view (which recreates
    /// the manager) recovered it. Retry indefinitely instead, capping only the
    /// backoff delay — matches the fMP4 player's infinite-retry behavior
    /// (Fmp4Player.swift `scheduleReconnect`, which never gives up either).
    private func scheduleReconnect(immediate: Bool = false) {
        guard !teardownCalled else { return }
        if !immediate {
            reconnectAttempts += 1
        }
        let delay = immediate ? 0 : min(Double(1 << min(reconnectAttempts, 4)), 15.0)
        signalingTask?.cancel()
        signalingTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            await self.negotiate()
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        lastSeenFrameCount = frameTick.frameCount
        stalledChecks = 0
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.checkStall()
            }
        }
    }

    private func checkStall() {
        guard !teardownCalled, peerConnection != nil else { return }
        let current = frameTick.frameCount
        if current != lastSeenFrameCount {
            lastSeenFrameCount = current
            stalledChecks = 0
            return
        }
        // No new decoded frames since the last tick.
        stalledChecks += 1
        if hasFirstFrame {
            // Was rendering, now frozen (~3s) while still "connected" → reconnect.
            if stalledChecks >= 2 {
                stalledChecks = 0
                forceReconnect()
            }
        } else {
            // Negotiated but never produced a decodable frame (~6s) → codec issue.
            if stalledChecks >= 4 {
                stalledChecks = 0
                handleNoDecodableFrames()
            }
        }
    }

    /// A previously-live feed froze. Reset and reconnect from scratch.
    private func forceReconnect() {
        guard !teardownCalled else { return }
        hasFirstFrame = false
        videoTrack = nil
        state = .connecting
        reconnectAttempts = 0
        watchdogTask?.cancel(); watchdogTask = nil
        peerConnection?.close(); peerConnection = nil
        scheduleReconnect(immediate: true)
    }

    /// Negotiation succeeded but nothing decoded. Try the fallback once; if there
    /// is none, surface an explicit incompatible-codec state.
    private func handleNoDecodableFrames() {
        watchdogTask?.cancel(); watchdogTask = nil
        if !usingFallback, hasFallback {
            usingFallback = true
            reconnectAttempts = 0
            peerConnection?.close(); peerConnection = nil
            scheduleReconnect(immediate: true)
        } else {
            state = .incompatibleCodec
            signalingTask?.cancel(); signalingTask = nil
            peerConnection?.close(); peerConnection = nil
            videoTrack = nil
        }
    }

    deinit {
        peerConnection?.close()
        pathMonitor?.cancel()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected, .completed:
                if case .connected = state {} else if case .incompatibleCodec = state {} else { state = .connected }
                reconnectAttempts = 0
            case .failed, .disconnected:
                if !teardownCalled {
                    state = .failed("ICE \(newState.rawValue)")
                    scheduleReconnect()
                }
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        Task { @MainActor in
            if let video = track as? RTCVideoTrack {
                self.videoTrack = video
                // Attach the counting renderer alongside the Metal view so the
                // watchdog sees decoded frames independent of any UI renderer.
                video.add(self.frameTick)
            }
        }
    }

    // Unused but required by the protocol.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// A lightweight `RTCVideoRenderer` attached alongside the Metal view purely to
/// count decoded frames, so the manager's watchdog can detect a frozen stream.
/// `renderFrame` is called off the main thread, so the counter is lock-guarded.
private final class FrameTickRenderer: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var count: UInt64 = 0

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock(); count &+= 1; lock.unlock()
    }

    var frameCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

enum WebRTCError: LocalizedError {
    case signaling(String)
    var errorDescription: String? {
        switch self {
        case .signaling(let m): return m
        }
    }
}
#endif
