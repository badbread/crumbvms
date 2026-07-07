// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Multi-camera **playback wall** — the Playback tab landing (port of Android
/// `PlaybackWallScreen`). A grid of camera snapshot tiles over a single shared
/// scrub timeline. Scrubbing updates every tile to its recorded frame nearest the
/// cursor; tapping a tile opens that camera in full single-camera playback seeded
/// at the cursor time.
struct PlaybackWallView: View {

    let container: AppContainer
    let cameras: [CameraDto]
    let columns: Int
    /// `(cameraId, startTime)` — startTime nil = open at latest footage.
    let onOpenPlayback: (String, Date?) -> Void

    @State private var spans: [RecordedSpan] = []
    @State private var motionBuckets: [Float] = []
    @State private var windowStartMs: Int64 = 0
    @State private var windowEndMs: Int64 = 0
    @State private var cursorMs: Int64 = 0
    @State private var atLatest = true
    @State private var visibleSpanMs: Int64 = 60 * 60_000
    @State private var previewMs: Int64?
    @State private var showJump = false
    @State private var loadTask: Task<Void, Never>?

    private let windowHours: Int64 = 12
    private let recenterHalfMs: Int64 = 6 * 3_600_000

    var body: some View {
        VStack(spacing: 0) {
            grid
            controls
        }
        .task { await initialLoad() }
        .sheet(isPresented: $showJump) {
            JumpToDateTimeDialog(initial: Date(timeIntervalSince1970: Double(cursorMs) / 1000)) { date in
                let target = Int64(date.timeIntervalSince1970 * 1000)
                cursorMs = target; atLatest = false; previewMs = target
                recenter(on: target)
            }
        }
    }

    @ViewBuilder private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: max(columns, 1))
        ScrollView {
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(cameras) { cam in
                    PlaybackTile(
                        camera: cam,
                        mediaUrls: container.mediaUrls(),
                        scrubTsISO: previewMs.map { iso($0) },
                        onTap: { onOpenPlayback(cam.id, atLatest ? nil : Date(timeIntervalSince1970: Double(cursorMs) / 1000)) }
                    )
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Button {
                    goLatest()
                } label: {
                    Text("Latest").font(.caption.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(atLatest ? CrumbColors.teal.opacity(0.3) : CrumbColors.surfaceVariant)
                        .foregroundColor(atLatest ? CrumbColors.tealAccent : .white)
                        .clipShape(Capsule())
                }
                Text(atLatest ? "Tap a camera to play its latest footage"
                              : "Play from \(formatTime(Date(timeIntervalSince1970: Double(cursorMs)/1000), style: .clockLong))")
                    .font(.caption2).foregroundColor(CrumbColors.textSecondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { showJump = true } label: {
                    Image(systemName: "calendar.badge.clock").foregroundColor(CrumbColors.textSecondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)

            CenteredTimelineView(
                spans: spans, motionBuckets: motionBuckets,
                motionStartMs: windowStartMs, motionEndMs: windowEndMs,
                detectionEvents: [], bookmarks: [],
                playheadMs: cursorMs, spanMs: visibleSpanMs,
                onScrubStart: {},
                onScrub: { ts in cursorMs = ts; atLatest = false; previewMs = ts },
                onScrubEnd: { ts in
                    cursorMs = ts; atLatest = false; previewMs = ts
                    let margin: Int64 = 30 * 60_000
                    if ts < windowStartMs + margin || ts > windowEndMs - margin { recenter(on: ts) }
                },
                onSpanChange: { visibleSpanMs = min(max($0, 60_000), windowHours * 3_600_000) }
            )
            .frame(height: 64)
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(CrumbColors.surface)
    }

    // MARK: - data

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func iso(_ ms: Int64) -> String { iso8601String(Date(timeIntervalSince1970: Double(ms) / 1000)) }

    private func initialLoad() async {
        let now = nowMs()
        windowStartMs = now - windowHours * 3_600_000
        windowEndMs = now
        cursorMs = now
        await load(windowStartMs, windowEndMs, snapLatest: true)
    }

    private func goLatest() {
        let now = nowMs()
        windowStartMs = now - windowHours * 3_600_000
        windowEndMs = now
        previewMs = nil
        Task { await load(windowStartMs, windowEndMs, snapLatest: true) }
    }

    private func recenter(on centerMs: Int64) {
        let now = nowMs()
        windowStartMs = max(centerMs - recenterHalfMs, 0)
        windowEndMs = min(centerMs + recenterHalfMs, now)
        Task { await load(windowStartMs, windowEndMs, snapLatest: false) }
    }

    private func load(_ startMs: Int64, _ endMs: Int64, snapLatest: Bool) async {
        let ids = cameras.map(\.id)
        guard !ids.isEmpty else { return }
        // spans across all cameras
        if let resp = try? await container.api.timeline(cameraIds: ids, start: iso(startMs), end: iso(endMs)) {
            spans = resp.spans
            if snapLatest {
                let latest = resp.spans.compactMap { parseISO8601($0.end).map { Int64($0.timeIntervalSince1970 * 1000) } }.max()
                cursorMs = latest.map { max($0 - 1500, startMs) } ?? endMs
                atLatest = true
            }
        }
        // combined motion (per-bucket max across cameras). Snapshot the non-isolated
        // API + precompute the ISO strings before fanning out, so the off-main task
        // closures don't capture the @MainActor view/container.
        let buckets = 720
        let api = container.api
        let startISO = iso(startMs)
        let endISO = iso(endMs)
        await withTaskGroup(of: [Float].self) { group in
            for id in ids {
                group.addTask {
                    (try? await api.timelineIntensity(cameraId: id, start: startISO, end: endISO, buckets: buckets).buckets) ?? []
                }
            }
            var combined = [Float](repeating: 0, count: buckets)
            for await b in group {
                for i in 0..<min(b.count, buckets) where b[i] > combined[i] { combined[i] = b[i] }
            }
            motionBuckets = combined
        }
    }
}

// MARK: - tile

private struct PlaybackTile: View {
    let camera: CameraDto
    let mediaUrls: MediaUrls
    /// RFC-3339 timestamp at the scrubbed cursor (nil = "Latest" / not
    /// scrubbing). Resolved to a scoped media URL inside this tile (per
    /// camera) rather than pre-built by the parent, since minting the
    /// `?token=` now requires an async `GET /media-token` round trip.
    let scrubTsISO: String?
    let onTap: () -> Void

    @State private var image: PlatformImage?
    @State private var liveTask: Task<Void, Never>?
    @State private var scrubTask: Task<Void, Never>?

    var body: some View {
        // Base establishes a strict 16:9 cell; the image fills it as an overlay and
        // is clipped to that frame so a non-16:9 snapshot can't bleed into neighbours.
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().tint(CrumbColors.tealAccent)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(camera.name).font(.caption2.bold()).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.55)).cornerRadius(4).padding(6)
            }
            .clipped()
            .cornerRadius(8)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onAppear { loadLive() }
            .onChange(of: scrubTsISO) { tsISO in loadScrub(tsISO) }
    }

    /// The frozen live still — the reference image shown at "Latest".
    private func loadLive() {
        guard image == nil else { return }
        liveTask?.cancel()
        liveTask = Task { @MainActor in
            for _ in 0..<5 {
                if Task.isCancelled { return }
                if let url = await mediaUrls.cameraFrameUrl(camera.id),
                   let (data, _) = try? await URLSession.crumbMedia.data(from: url), let img = PlatformImage(data: data) {
                    image = img; return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// On scrub, swap to the recorded frame at the cursor. If extraction fails
    /// (no footage / on-demand not ready), KEEP the current image — never blank.
    private func loadScrub(_ tsISO: String?) {
        scrubTask?.cancel()
        guard let tsISO else { return }
        scrubTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000) // debounce continuous scrub
            guard !Task.isCancelled else { return }
            guard let url = await mediaUrls.historicalFrameUrl(cameraId: camera.id, tsISO: tsISO) else { return }
            guard !Task.isCancelled else { return }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 6
            if let (data, resp) = try? await URLSession.crumbMedia.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let img = PlatformImage(data: data) {
                image = img
            }
        }
    }
}
