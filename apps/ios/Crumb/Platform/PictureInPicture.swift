// SPDX-License-Identifier: AGPL-3.0-or-later

import AVKit
import AVFoundation
import SwiftUI

/// M6 parity: Picture-in-Picture support for Crumb's two video-rendering
/// primitives —
///
/// - `AVPlayerLayer` (recorded segment playback, `PlaybackView.SegmentPlayer`
///   / `PlayerLayerView`) uses the simple `AVPictureInPictureController(playerLayer:)`
///   initializer.
/// - `AVSampleBufferDisplayLayer` (live view, `Fmp4VideoView` /
///   `Fmp4StreamController`) has no player to hand over, so it uses the
///   content-source flavor (`AVPictureInPictureController.ContentSource`,
///   iOS 15+/macOS 13+) with a delegate that answers PiP's render/playback
///   queries against the same display layer the normal view already renders
///   into — no separate video pipeline, no extra decode.
///
/// Both platforms support PiP for `AVPlayerLayer`; the sample-buffer-display-
/// layer content-source flavor is iOS-only (macOS doesn't offer PiP for raw
/// sample buffer layers, only for `AVPlayerLayer`/`AVPlayerView` — the mac
/// live wall stays regular full-window video, matching how the desktop Tauri
/// client also has no PiP concept).

// MARK: - AVPlayerLayer-based PiP (recorded playback)

/// Wraps `AVPictureInPictureController` for an `AVPlayerLayer`-backed player.
/// Owns the controller's lifetime; call `attach(to:)` once the hosting layer
/// exists, and `start()`/`stop()` to enter/exit PiP programmatically (in
/// addition to the system's own PiP button, which this makes available).
@MainActor
final class PlayerPictureInPicture: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    private var controller: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?

    /// Attach to the given player layer. Safe to call repeatedly (e.g. on
    /// every `updateUIView`/`updateNSView`) — it's a no-op once already
    /// attached to the same layer.
    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard controller?.playerLayer !== layer else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.delegate = self
        controller = c
        observation = c?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctl, _ in
            Task { @MainActor in self?.isPossible = ctl.isPictureInPicturePossible }
        }
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }
}

extension PlayerPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }
}

/// A small floating PiP toggle button, shown only when PiP is actually
/// possible for the current player (matches the system convention of hiding
/// the affordance rather than disabling it).
struct PictureInPictureButton: View {
    @ObservedObject var pip: PlayerPictureInPicture

    var body: some View {
        if pip.isPossible {
            Button {
                if pip.isActive { pip.stop() } else { pip.start() }
            } label: {
                Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(9)
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .accessibilityLabel(pip.isActive ? "Exit Picture in Picture" : "Enter Picture in Picture")
        }
    }
}

#if os(iOS)

// MARK: - AVSampleBufferDisplayLayer-based PiP (live view, iOS only)

/// Content-source PiP for the live `Fmp4VideoView`'s `AVSampleBufferDisplayLayer`.
/// There's no `AVPlayer` to answer PiP's playback queries, so this acts as the
/// `AVPictureInPictureSampleBufferPlaybackDelegate` itself: live video has no
/// meaningful pause/seek/rate, so those queries answer with "always playing,
/// can't be paused" — PiP just mirrors the live layer's content.
@MainActor
final class LivePictureInPicture: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    private var controller: AVPictureInPictureController?
    private let renderingQueue = DispatchQueue(label: "video.crumb.pip.rendering")

    /// Attach to the display layer that's already rendering the live stream
    /// (the same one `Fmp4StreamController.displayLayer` feeds — no separate
    /// decode/pipeline is created for PiP).
    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        if let controller {
            controller.contentSource = source
        } else {
            let c = AVPictureInPictureController(contentSource: source)
            c.delegate = self
            controller = c
            isPossible = true
        }
    }

    func start() {
        guard let controller, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    func detach() {
        controller?.contentSource = nil
        controller = nil
        isPossible = false
    }
}

extension LivePictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }
}

extension LivePictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // Live video: nothing to pause — PiP always shows the current feed.
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // An unbounded/live range: `.positiveInfinity` duration signals "live".
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        // No seeking in a live feed.
    }
}

#endif
