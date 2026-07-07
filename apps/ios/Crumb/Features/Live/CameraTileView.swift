// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

struct CameraTileView: View {

    let camera: CameraDto
    let status: CameraStatusEntry?
    let detectionKeys: [String]
    /// Resolves this tile's own scoped (~15 min-token) snapshot-backdrop URL —
    /// replaces a pre-built `frameUrl: URL?` now that minting the token
    /// requires an async `GET /media-token` round trip (see
    /// `MediaUrls.cameraFrameUrl`). Re-resolved whenever `camera.id` changes.
    let mediaUrls: MediaUrls
    /// When true, show ~1fps snapshots instead of live WebRTC (low-bandwidth mode).
    let lowBandwidth: Bool
    /// When true (default) the tile locks to 16:9; when false it fills its
    /// container (used by custom layouts whose panes are arbitrary aspect ratios).
    var lockAspect: Bool = true
    let onTap: () -> Void

    @State private var frameUrl: URL?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if lowBandwidth {
                // Own long-lived poll loop (low-bandwidth mode) — re-resolves
                // its own scoped URL every tick rather than reusing the
                // `frameUrl` snapshot-backdrop state above, since a ~1.2s
                // poll easily outlives the ~15 min scoped-token TTL.
                SnapshotTile(cameraId: camera.id, mediaUrls: mediaUrls)
            } else {
                #if canImport(WebRTC)
                // iOS: native WebRTC sub-stream (sub-second), snapshot backdrop until first frame.
                // [iOS] C3 fix: `LiveViewModel.loadCameras()` publishes `cameras`
                // before `resolveStreams` finishes, so this tile can first render
                // with `whepURL == nil` (the `WebRTCManager` init falls back to the
                // `http://invalid.local` placeholder) and never retry once the real
                // URL resolves a moment later — the `@StateObject` manager is only
                // built once, at this view's first construction. Keying identity on
                // the URL forces SwiftUI to tear down and rebuild the view (and thus
                // the manager) whenever whepURL changes from nil → real or between
                // cameras, mirroring the macOS Fmp4VideoView's `.onChange(of:
                // streamURL)` rebuild-on-change behavior.
                WebRTCVideoView(cameraId: camera.id, mediaUrls: mediaUrls, hasSub: camera.hasSubStream, fill: true)
                #else
                // macOS: the cross-platform fMP4 / VideoToolbox player (no WebRTC).
                // Wall tiles pull the SUB stream when present (lighter); the stream
                // URL is minted per connect through the authenticated /live proxy.
                Fmp4VideoView(
                    streamKey: "\(camera.id):\(camera.hasSubStream ? "sub" : "main")",
                    streamProvider: { await mediaUrls.liveFmp4URL(cameraId: camera.id, sub: camera.hasSubStream) },
                    snapshotURL: frameUrl
                )
                #endif
            }

            // Detection / motion badge (top-left): classified object icons take
            // precedence; otherwise a red motion-sensor glyph (radiating waves) —
            // matches Android, never a person look.
            if !detectionKeys.isEmpty || status?.recentMotion == true {
                HStack(spacing: 3) {
                    if !detectionKeys.isEmpty {
                        ForEach(detectionKeys.prefix(3), id: \.self) { key in
                            Image(systemName: DetectionIcons.sfSymbol(for: key))
                                .font(.system(size: 12))
                                .foregroundColor(DetectionIcons.color(for: key))
                        }
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 12))
                            .foregroundColor(CrumbColors.recDot)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(.black.opacity(0.72))
                .cornerRadius(4)
                .padding(6)
            }

            // REC dot (top-right): small red dot, only while actually recording.
            if status?.recording == true {
                Circle()
                    .fill(CrumbColors.recDot)
                    .frame(width: 6, height: 6)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            VStack {
                Spacer()
                Text(camera.name)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55))
                    .cornerRadius(4)
                    .padding(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(TileFrame(lockAspect: lockAspect))
        .clipped()
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: camera.id) {
            frameUrl = await mediaUrls.cameraFrameUrl(camera.id)
        }
    }
}

/// Locks a tile to 16:9 (grid walls) or lets it fill its container (custom panes).
private struct TileFrame: ViewModifier {
    let lockAspect: Bool
    func body(content: Content) -> some View {
        if lockAspect {
            content.aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Snapshot tile (low-bandwidth mode)

private struct SnapshotTile: View {
    let cameraId: String
    let mediaUrls: MediaUrls
    @State private var image: PlatformImage?
    @State private var pollTask: Task<Void, Never>?
    @State private var hasErrored = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if hasErrored {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash.fill")
                        .font(.title3)
                        .foregroundColor(CrumbColors.textTertiary)
                    Text("offline")
                        .font(.caption2)
                        .foregroundColor(CrumbColors.textTertiary)
                }
            } else {
                ProgressView().tint(CrumbColors.tealAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            var first = true
            while !Task.isCancelled {
                // Re-resolved every poll tick (P0-SESSIONS): this loop runs
                // indefinitely at ~1.2s cadence while low-bandwidth mode is
                // on, far outliving the ~15 min scoped-token TTL. `MediaTokenCache`
                // makes the common case (token still fresh) a cheap hit.
                guard let url = await mediaUrls.cameraFrameUrl(cameraId) else {
                    if first { hasErrored = true }
                    first = false
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.timeoutInterval = 5
                if let (data, resp) = try? await URLSession.crumbMedia.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let img = PlatformImage(data: data) {
                    image = img
                    hasErrored = false
                } else if first {
                    hasErrored = true
                }
                first = false
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}

