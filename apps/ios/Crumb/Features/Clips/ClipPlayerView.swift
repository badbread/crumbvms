// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import AVFoundation

/// Full-screen clip player with **motion-highlight auto-zoom** (the
/// `feat/clip-motion-highlight` feature, ported from Android `ClipZoomSurface`).
///
/// For a motion clip with a `motionBbox`, the player eases into the motion region
/// for `highlightSeconds`, holds, then eases back to the full frame — unless the
/// user takes over with a pinch/pan. Detection clips and bbox-less clips just play
/// full-frame.
struct ClipPlayerView: View {

    let clip: ClipDescriptor
    let mediaUrls: MediaUrls
    let highlightSeconds: Int
    /// "View on timeline" — jump to playback for this clip's camera at its start.
    var onViewInTimeline: ((String, Date) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = ClipPlayer()
    /// Resolved lazily via a scoped (~15 min) media token — see `mediaUrls.clipVideoUrl`.
    /// `nil` while resolving OR if the mint failed; `loading` distinguishes the two
    /// so a failed mint doesn't flash "Video unavailable" during the brief resolve.
    @State private var videoURL: URL?
    @State private var resolving = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if resolving {
                ProgressView().tint(CrumbColors.tealAccent)
            } else if videoURL != nil {
                GeometryReader { geo in
                    // Size the zoom surface to the actual VIDEO rect (aspect-fit in
                    // the screen) so the motion-bbox — normalized to the video frame
                    // — maps correctly instead of to the letterboxed full screen.
                    let aspect = player.videoAspect ?? (16.0 / 9.0)
                    let rect = aspectFitRect(aspect: aspect, in: geo.size)
                    ClipZoomSurface(
                        player: player,
                        bbox: clip.kind == "motion" ? clip.motionBbox : nil,
                        highlightSeconds: highlightSeconds,
                        size: rect.size
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.system(size: 44)).foregroundColor(CrumbColors.textSecondary)
                    Text("Video unavailable").foregroundColor(CrumbColors.textSecondary)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white.opacity(0.85)).padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: clip.kind == "motion" ? "waveform.path.ecg" : DetectionIcons.sfSymbol(for: clip.iconKey))
                        .foregroundColor(clip.kind == "motion" ? CrumbColors.motionDot : DetectionIcons.color(for: clip.iconKey))
                    Text(clip.cameraName.isEmpty ? clip.label : clip.cameraName)
                        .font(.caption).foregroundColor(.white)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.6)))

                if let onViewInTimeline {
                    Button {
                        onViewInTimeline(clip.cameraId, clip.startDate ?? Date())
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("View on timeline")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundColor(CrumbColors.tealAccent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 28)
        }
        .task(id: clip.id) {
            resolving = true
            videoURL = await mediaUrls.clipVideoUrl(clip.id, cameraId: clip.cameraId)
            resolving = false
            player.start(url: videoURL)
        }
        .onDisappear { player.stop() }
        .macModalSize(width: 1024, height: 680)
    }
}

/// Aspect-fit rect of a `aspect` (w/h) video centered in `size`.
private func aspectFitRect(aspect: CGFloat, in size: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0, aspect > 0 else { return CGRect(origin: .zero, size: size) }
    if size.width / size.height > aspect {
        let h = size.height, w = h * aspect
        return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
    } else {
        let w = size.width, h = w / aspect
        return CGRect(x: 0, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: - zoomable surface with auto-zoom

private struct ClipZoomSurface: View {
    @ObservedObject var player: ClipPlayer
    let bbox: [Float]?
    let highlightSeconds: Int
    let size: CGSize

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero        // top-left of the viewport, in points
    @State private var lastOffset: CGSize = .zero
    @State private var lastZoom: CGFloat = 1
    @State private var userTookOver = false
    @State private var autoTask: Task<Void, Never>?

    var body: some View {
        PlayerLayerView(player: player.player)
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: -offset.width * zoom, y: -offset.height * zoom)
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnify)
            .simultaneousGesture(pan)
            // Start (and on each loop, restart) the auto-zoom only once frames are
            // actually displaying — synced to the visible motion, not the load.
            .onChange(of: player.displaying) { isDisplaying in
                if isDisplaying { startAutoZoom() }
            }
            .onAppear { if player.displaying { startAutoZoom() } }
            .onDisappear { autoTask?.cancel() }
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                userTookOver = true; autoTask?.cancel()
                zoom = max(1, min(lastZoom * v, 5))
                clamp()
            }
            .onEnded { _ in lastZoom = zoom; lastOffset = offset }
    }
    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1 else { return }
                userTookOver = true; autoTask?.cancel()
                offset = CGSize(width: lastOffset.width - v.translation.width / zoom,
                                height: lastOffset.height - v.translation.height / zoom)
                clamp()
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func clamp() {
        let maxX = max(size.width * (1 - 1 / zoom), 0)
        let maxY = max(size.height * (1 - 1 / zoom), 0)
        offset = CGSize(width: min(max(offset.width, 0), maxX), height: min(max(offset.height, 0), maxY))
    }

    private func startAutoZoom() {
        guard let bb = bbox, bb.count == 4, highlightSeconds > 0, size.width > 0, size.height > 0 else { return }
        let region = max(bb[2], bb[3])
        guard region > 0, region <= 0.7 else { return }
        let target = min(4, max(1.4, CGFloat(0.9 / region)))
        let cx = CGFloat(bb[0] + bb[2] / 2), cy = CGFloat(bb[1] + bb[3] / 2)
        func offsetFor(_ s: CGFloat) -> CGSize {
            let maxX = max(size.width * (1 - 1 / s), 0)
            let maxY = max(size.height * (1 - 1 / s), 0)
            return CGSize(width: min(max(size.width * (cx - 0.5 / s), 0), maxX),
                          height: min(max(size.height * (cy - 0.5 / s), 0), maxY))
        }
        let tgt = offsetFor(target)

        autoTask?.cancel()
        autoTask = Task { @MainActor in
            guard !userTookOver else { return }
            withAnimation(.easeInOut(duration: 0.45)) { zoom = target; offset = tgt; lastZoom = target; lastOffset = tgt }
            try? await Task.sleep(nanoseconds: UInt64(highlightSeconds) * 1_000_000_000)
            guard !userTookOver, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { zoom = 1; offset = .zero; lastZoom = 1; lastOffset = .zero }
        }
    }
}

// MARK: - AVPlayer

@MainActor
final class ClipPlayer: ObservableObject {
    let player = AVPlayer()
    /// Flips true the moment real frames are on screen (playing + time advancing),
    /// and resets to false on each loop. The auto-zoom keys off this so it starts
    /// in sync with the visible motion instead of firing during the load (which
    /// would zoom a black frame and miss the action).
    @Published private(set) var displaying = false
    /// The decoded video's aspect ratio (w/h), known once frames flow. The zoom
    /// surface sizes itself to this so the motion-bbox (normalized to the VIDEO
    /// frame) maps correctly — not to the letterboxed full screen.
    @Published private(set) var videoAspect: CGFloat?

    private var loopObserver: NSObjectProtocol?
    private var timeObserver: Any?

    func start(url: URL?) {
        guard let url else { return }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.displaying = false
            self.player.seek(to: .zero) { _ in self.player.play() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.06, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            if self.videoAspect == nil, let ps = self.player.currentItem?.presentationSize, ps.width > 0, ps.height > 0 {
                self.videoAspect = ps.width / ps.height
            }
            if !self.displaying, self.player.timeControlStatus == .playing, time.seconds > 0.03 {
                self.displaying = true
            }
        }
        player.play()
    }
    func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

