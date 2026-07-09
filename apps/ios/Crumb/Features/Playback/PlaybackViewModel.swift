// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Single-camera recorded-playback state machine — a faithful port of the
/// Android `PlaybackViewModel`. Works in epoch-milliseconds internally (like
/// Android) to keep the timeline math identical.
@MainActor
final class PlaybackViewModel: ObservableObject {

    // ── published state (mirrors Android PlaybackUiState) ───────────────────────
    @Published var loading = true
    @Published var error: String?
    @Published var cameraId: String
    @Published var cameraName: String?
    @Published var spans: [RecordedSpan] = []
    @Published var windowStartMs: Int64 = 0
    @Published var windowEndMs: Int64 = 0
    @Published var playheadMs: Int64 = 0
    @Published var currentSegment: ResolvedSegment?
    @Published var currentSegmentURL: URL?
    @Published var segmentOffsetMs: Int64 = 0
    @Published var playing = false
    @Published var speed: Float = 1
    @Published var scrubbing = false
    @Published var scrubFrameURL: URL?
    @Published var noFootageAtPlayhead = false
    @Published var visibleSpanMs: Int64 = 60 * 60_000
    @Published var motionBuckets: [Float] = []
    @Published var motionStartMs: Int64 = 0
    @Published var motionEndMs: Int64 = 0
    @Published var detectionEvents: [DetectionEvent] = []

    let container: AppContainer
    private var filmstrip: [FilmstripFrame] = []
    private var pendingSeedMs: Int64

    private var seekTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var filmstripTask: Task<Void, Never>?
    private var scrubFrameTask: Task<Void, Never>?

    // tuning (mirrors Android)
    private let defaultWindowHours: Int64 = 6
    private let minSpanMs: Int64 = 60_000
    private var maxSpanMs: Int64 { defaultWindowHours * 3_600_000 }
    private let motionBucketsCount = 1440
    private let motionBucketThreshold: Float = 0.006
    private let speedSteps: [Float] = [0.5, 1, 2, 4, 8]
    private let filmstripDebounceMs: UInt64 = 300

    init(cameraId: String, container: AppContainer, startTime: Date? = nil) {
        self.cameraId = cameraId
        self.container = container
        self.pendingSeedMs = startTime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        startCamera(cameraId, preserveTime: false)
    }

    func mediaUrls() -> MediaUrls { container.mediaUrls() }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func iso(_ ms: Int64) -> String { iso8601String(Date(timeIntervalSince1970: Double(ms) / 1000)) }
    private func parseMs(_ s: String) -> Int64 {
        guard let d = parseISO8601(s) else { return 0 }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    // ── camera start / switch ───────────────────────────────────────────────────

    private func startCamera(_ camId: String, preserveTime: Bool) {
        cameraId = camId
        seekTask?.cancel()
        filmstripTask?.cancel()

        if preserveTime && playheadMs > 0 {
            cameraName = nil
            detectionEvents = []
            loadCameraName()
            loadTimeline(windowStartMs, windowEndMs, gotoLatest: false)
            seekTo(playheadMs)
        } else {
            let now = nowMs()
            let seed = pendingSeedMs > 0 ? pendingSeedMs : nil
            pendingSeedMs = 0
            let halfMs = defaultWindowHours * 3_600_000 / 2
            if let seed {
                windowStartMs = max(seed - halfMs, 0)
                windowEndMs = min(seed + halfMs, now)
                playheadMs = seed
            } else {
                windowStartMs = now - defaultWindowHours * 3_600_000
                windowEndMs = now
                playheadMs = now
            }
            cameraName = nil
            detectionEvents = []
            loadCameraName()
            loadTimeline(windowStartMs, windowEndMs, gotoLatest: seed == nil)
            if let seed { seekTo(seed) }
        }
    }

    func switchCamera(_ camId: String) {
        guard camId != cameraId else { return }
        startCamera(camId, preserveTime: currentSegment != nil)
    }

    private func loadCameraName() {
        Task {
            if let cams = try? await container.api.visibleCameras() {
                cameraName = cams.first(where: { $0.id == cameraId })?.name ?? cameraId
            } else {
                cameraName = cameraId
            }
        }
    }

    // ── timeline load (spans + intensity + events) ──────────────────────────────

    private func loadTimeline(_ startMs: Int64, _ endMs: Int64, gotoLatest: Bool) {
        timelineTask?.cancel()
        loading = true
        error = nil
        timelineTask = Task { [weak self] in
            guard let self else { return }
            async let spansR: Void = self.loadSpans(startMs, endMs, gotoLatest: gotoLatest)
            async let intenR: Void = self.loadIntensity(startMs, endMs)
            async let evR: Void = self.loadEvents(startMs, endMs)
            _ = await (spansR, intenR, evR)
        }
    }

    private func loadSpans(_ startMs: Int64, _ endMs: Int64, gotoLatest: Bool) async {
        do {
            let resp = try await container.api.timeline(cameraIds: [cameraId], start: iso(startMs), end: iso(endMs))
            guard !Task.isCancelled else { return }
            spans = resp.spans
            loading = false
            if gotoLatest, !resp.spans.isEmpty {
                let latest = resp.spans.map { parseMs($0.end) }.max() ?? endMs
                seekTo(min(max(latest - 1500, 0), endMs))
            }
        } catch {
            guard !Task.isCancelled else { return }
            loading = false
            self.error = error.userMessage
        }
    }

    private func loadIntensity(_ startMs: Int64, _ endMs: Int64) async {
        if let resp = try? await container.api.timelineIntensity(cameraId: cameraId, start: iso(startMs), end: iso(endMs), buckets: motionBucketsCount) {
            guard !Task.isCancelled else { return }
            motionBuckets = resp.buckets
            motionStartMs = startMs
            motionEndMs = endMs
        }
    }

    private func loadEvents(_ startMs: Int64, _ endMs: Int64) async {
        let resp = try? await container.api.events(cameraIds: cameraId, start: iso(startMs), end: iso(endMs), limit: 2000)
        guard !Task.isCancelled else { return }
        detectionEvents = (resp?.events ?? []).filter { !$0.iconKey.isEmpty && $0.iconKey != "motion" }
    }

    // ── segment resolution ──────────────────────────────────────────────────────

    func seekTo(_ tsMs: Int64) {
        playheadMs = tsMs
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            guard let self else { return }
            do {
                let segment = try await container.api.play(cameraId: cameraId, ts: iso(tsMs))
                guard !Task.isCancelled else { return }
                let startMs = parseMs(segment.start)
                currentSegment = segment
                currentSegmentURL = await container.mediaUrls().scopedURL(cameraId: cameraId, segment.url)
                guard !Task.isCancelled else { return }
                segmentOffsetMs = max(tsMs - startMs, 0)
                error = nil
                noFootageAtPlayhead = false
            } catch {
                guard !Task.isCancelled else { return }
                currentSegment = nil
                currentSegmentURL = nil
                segmentOffsetMs = 0
                if error.isNotFound {
                    self.error = nil
                    noFootageAtPlayhead = true
                } else {
                    self.error = error.userMessage
                    noFootageAtPlayhead = false
                }
            }
        }
    }

    func onPlayerError() { seekTo(playheadMs) }

    func onSegmentEnded() {
        guard let seg = currentSegment else { return }
        let endMs = parseMs(seg.end)
        let stillInSpan = spans.contains { parseMs($0.start) <= endMs && endMs < parseMs($0.end) }
        if stillInSpan {
            seekTo(endMs + 1)
            return
        }
        let nextStart = spans.map { parseMs($0.start) }.filter { $0 > endMs }.min()
        if let nextStart {
            seekTo(nextStart)
        } else {
            playing = false
        }
    }

    /// Smooth playhead advance from the player's position (does NOT re-resolve).
    func onPlaybackTick(_ tsMs: Int64) {
        guard !scrubbing else { return }
        playheadMs = tsMs
    }

    // ── motion navigation (rising-edge over the histogram) ──────────────────────

    private func bucketTimeMs(_ i: Int) -> Int64? {
        let n = motionBuckets.count
        guard n > 0, motionEndMs > motionStartMs else { return nil }
        let durMs = Double(motionEndMs - motionStartMs) / Double(n)
        return motionStartMs + Int64((Double(i) + 0.5) * durMs)
    }

    func jumpToNextMotion() {
        guard !motionBuckets.isEmpty else { return }
        for i in motionBuckets.indices {
            if motionBuckets[i] <= motionBucketThreshold { continue }
            let isEventStart = i == 0 || motionBuckets[i - 1] <= motionBucketThreshold
            if !isEventStart { continue }
            if let t = bucketTimeMs(i), t > playheadMs + 1000 { seekTo(t); return }
        }
    }

    func jumpToPrevMotion() {
        guard !motionBuckets.isEmpty else { return }
        for i in motionBuckets.indices.reversed() {
            if motionBuckets[i] <= motionBucketThreshold { continue }
            let isEventStart = i == 0 || motionBuckets[i - 1] <= motionBucketThreshold
            if !isEventStart { continue }
            if let t = bucketTimeMs(i), t < playheadMs - 1000 { seekTo(t); return }
        }
    }

    func gotoFirst() {
        guard let first = spans.min(by: { parseMs($0.start) < parseMs($1.start) }) else { return }
        jumpToTime(parseMs(first.start))
    }

    func gotoLast() {
        guard let last = spans.max(by: { parseMs($0.end) < parseMs($1.end) }) else { return }
        jumpToTime(max(parseMs(last.end) - 1000, 0))
    }

    // ── transport ───────────────────────────────────────────────────────────────

    func setPlaying(_ p: Bool) { playing = p }

    func setSpeed(_ s: Float) {
        speed = speedSteps.min(by: { abs($0 - s) < abs($1 - s) }) ?? 1
    }

    func jumpToTime(_ epochMs: Int64) {
        let now = nowMs()
        let half = defaultWindowHours * 3_600_000 / 2
        windowStartMs = max(epochMs - half, 0)
        windowEndMs = min(epochMs + half, now)
        playheadMs = epochMs
        loadTimeline(windowStartMs, windowEndMs, gotoLatest: false)
        seekTo(epochMs)
    }

    // ── scrubbing ─────────────────────────────────────────────────────────────────

    func onScrubStart() { scrubbing = true }

    func onScrub(_ tsMs: Int64) {
        playheadMs = tsMs
        if let nearest = filmstrip.min(by: { abs(parseMs($0.ts) - tsMs) < abs(parseMs($1.ts) - tsMs) }) {
            resolveScrubFrameURL(nearest.url)
        }
        loadFilmstrip(tsMs)
    }

    /// Resolve a scrub-frame path to a scoped (~15 min-token) URL. `onScrub` fires
    /// on every scrub tick (a plain sync callback from `CenteredTimelineView`),
    /// so the actual mint/cache lookup happens off to the side in a cancellable
    /// task — cancelling any still-resolving prior request keeps a fast drag
    /// from momentarily flashing a stale frame's URL after a newer scrub tick.
    private func resolveScrubFrameURL(_ path: String) {
        scrubFrameTask?.cancel()
        scrubFrameTask = Task { [weak self] in
            guard let self else { return }
            let url = await container.mediaUrls().scopedURL(cameraId: cameraId, path)
            guard !Task.isCancelled else { return }
            scrubFrameURL = url
        }
    }

    func onScrubEnd(_ tsMs: Int64) {
        scrubbing = false
        playheadMs = tsMs
        scrubFrameURL = nil
        let margin: Int64 = 30 * 60_000
        if tsMs < windowStartMs + margin || tsMs > windowEndMs - margin {
            let now = nowMs()
            let half = defaultWindowHours * 3_600_000 / 2
            windowStartMs = max(tsMs - half, 0)
            windowEndMs = min(tsMs + half, now)
            loadTimeline(windowStartMs, windowEndMs, gotoLatest: false)
        }
        seekTo(tsMs)
    }

    func setVisibleSpan(_ spanMs: Int64) {
        visibleSpanMs = min(max(spanMs, minSpanMs), maxSpanMs)
    }

    private func loadFilmstrip(_ centerMs: Int64) {
        filmstripTask?.cancel()
        filmstripTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: filmstripDebounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            let halfMs: Int64 = 3_600_000
            if let frames = try? await container.api.filmstrip(
                cameraId: cameraId,
                start: iso(max(centerMs - halfMs, 0)),
                end: iso(centerMs + halfMs),
                // Crisp scrub still (matches the wall + server pre-gen width); the
                // list only mints frame URLs, so a bigger width costs nothing until
                // the one nearest frame is actually fetched for the scrub overlay.
                width: MediaUrls.scrubThumbWidth
            ).frames {
                guard !Task.isCancelled else { return }
                filmstrip = frames
                if scrubbing, let nearest = frames.min(by: { abs(parseMs($0.ts) - playheadMs) < abs(parseMs($1.ts) - playheadMs) }) {
                    resolveScrubFrameURL(nearest.url)
                }
            }
        }
    }

    // ── bookmarks ─────────────────────────────────────────────────────────────────

    func addBookmark(description: String?, protectDays: Int?, preSeconds: Int?, postSeconds: Int?) async -> Bool {
        do {
            _ = try await container.api.createBookmark(CreateBookmarkRequest(
                cameraId: cameraId, ts: iso(playheadMs), description: description,
                protectDays: protectDays, protectPreSeconds: preSeconds, protectPostSeconds: postSeconds
            ))
            return true
        } catch {
            self.error = error.userMessage
            return false
        }
    }

    var playheadDate: Date { Date(timeIntervalSince1970: Double(playheadMs) / 1000) }
}
