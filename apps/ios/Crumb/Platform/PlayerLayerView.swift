// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AVFoundation

/// Cross-platform SwiftUI view that hosts an `AVPlayerLayer` for a given
/// `AVPlayer` — used by single-camera playback and clip playback. Shares one
/// implementation across iOS (UIView with `layerClass`) and macOS (layer-backed
/// NSView), so the player views stay platform-free.
struct PlayerLayerView: PlatformViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// M6: called once the hosting view's `AVPlayerLayer` exists, so a caller
    /// (e.g. `PlaybackView`) can attach `PlayerPictureInPicture` to it.
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    #if os(macOS)
    func makeNSView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView(); v.attach(player, gravity); onLayer?(v.playerLayer); return v
    }
    func updateNSView(_ view: PlayerLayerHostView, context: Context) { view.attach(player, gravity) }
    #else
    func makeUIView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView(); v.attach(player, gravity); onLayer?(v.playerLayer); return v
    }
    func updateUIView(_ view: PlayerLayerHostView, context: Context) { view.attach(player, gravity) }
    #endif
}

#if os(macOS)
final class PlayerLayerHostView: NSView {
    /// M6: exposed (not `private`) so `PlayerLayerView.onLayer` can hand it to
    /// `PlayerPictureInPicture.attach(to:)`.
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); playerLayer.frame = bounds }
    func attach(_ player: AVPlayer, _ gravity: AVLayerVideoGravity) {
        if playerLayer.player !== player { playerLayer.player = player }
        playerLayer.videoGravity = gravity
    }
}
#else
final class PlayerLayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    /// M6: exposed (not `private`) so `PlayerLayerView.onLayer` can hand it to
    /// `PlayerPictureInPicture.attach(to:)`.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    func attach(_ player: AVPlayer, _ gravity: AVLayerVideoGravity) {
        if playerLayer.player !== player { playerLayer.player = player }
        playerLayer.videoGravity = gravity
    }
}
#endif
