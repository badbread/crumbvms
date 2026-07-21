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
    /// Bumped on every `seekTo` resolution (success or failure), even when
    /// `currentSegmentURL` lands on the SAME URL as before (a scrub that stays
    /// within the current ~4s segment reuses its cached token/URL). The view's
    /// `.onChange` keys off this instead of `currentSegmentURL` so a within-
    /// segment reseek isn't silently dropped — `Equatable`'s `onChange` never
    /// fires for a value that didn't change.
    @Published var seekGeneration = 0
    @Published var segmentOffsetMs: Int64 = 0
    @Published var playing = false
    @Published var speed: Float = 1
    @Published var scrubbing = false
    @Published var scrubFrameURL: URL?
    /// Set when the next contiguous segment has been resolved ahead of the
    /// current one's end, so the player can prefetch + queue it for gapless
    /// boundary playback (issue #23). The view forwards it to
    /// `SegmentPlayer.enqueueNext`.
    @Published var prefetchNext: PrefetchSignal?
    @Published var noFootageAtPlayhead = false
    @Published var visibleSpanMs: Int64 = 60 * 60_000
    @Published var motionBuckets: [Float] = []
    /// Per-camera motion histograms for the whole camera set — the timeline draws
    /// every camera's bars in its own color, the selected one prominent. Empty
    /// falls back to the single-tone `motionBuckets`.
    @Published var motionByCamera: [(id: String, buckets: [Float])] = []
    @Published var motionStartMs: Int64 = 0
    @Published var motionEndMs: Int64 = 0
    /// Cameras whose motion the timeline shows (defaults to just the current one).
    private var timelineCameraIds: [String] = []
    @Published var detectionEvents: [DetectionEvent] = []

    let container: AppContainer
    /// Filmstrip frames with their `ts` PARSED ONCE to epoch-ms. `onScrub` runs a
    /// nearest-frame lookup on every drag tick; parsing the ISO8601 strings per
    /// tick over the whole ±1h window (~1800 frames) janked the scrub (issue #28).
    /// Parsed on load instead — same idea as the timeline's M5 span precompute.
    private var filmstrip: [(ms: Int64, url: String)] = []
    private var pendingSeedMs: Int64

    private var seekTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var filmstripTask: Task<Void, Never>?
    private var scrubFrameTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?

    // ── gapless prefetch (issue #23) ────────────────────────────────────────────
    /// The next segment resolved ahead of the boundary, promoted to
    /// `currentSegment` by `commitAdvance()` once the player gaplessly advances.
    private var prefetchedSegment: ResolvedSegment?
    /// `segmentId` of the current segment we've already prefetched a next for,
    /// so `onPlaybackTick` only resolves it once per segment.
    private var prefetchedForSegmentId: String?

    // ── quality (low-bitrate playback) ──────────────────────────────────────────
    /// The user/auto choice wants the low-bitrate `/segments/{id}/low.mp4`
    /// transcode instead of the raw segment. Driven by `setLowQuality` from the
    /// view (which resolves the Full/Data-saver/Auto preference + metered state).
    private var lowQuality = false
    /// The fallback LATCH: once a `/low.mp4` request fails with an expected
    /// error (404 on an older server, or a segment it can't transcode), stop
    /// requesting the low variant for the rest of this session and serve the raw
    /// segment instead. Session-global + in-memory (mirrors Android's
    /// `lowUnavailable`); cleared by re-selecting a low mode (`setLowQuality(true)`)
    /// so a later retry gets another chance. Never persisted.
    private var lowUnavailable = false

    /// Append `/low.mp4` to a raw segment path when the low variant is both
    /// wanted and not latched-off — the single choke point every segment/prefetch
    /// URL passes through. `segmentUrl` is `ResolvedSegment.url` (`/segments/{id}`).
    private func qualityPath(_ segmentUrl: String) -> String {
        (lowQuality && !lowUnavailable) ? "\(segmentUrl)/low.mp4" : segmentUrl
    }

    /// What the player needs to prefetch + queue the next segment. `Equatable`
    /// so `@Published` republishes only on a genuinely new next segment.
    struct PrefetchSignal: Equatable {
        let url: URL
        let startMs: Int64
        /// Raw segment path (`ResolvedSegment.url`) for the retag token refresh.
        let path: String
    }

    // tuning (mirrors Android)
    private let defaultWindowHours: Int64 = 6
    private let minSpanMs: Int64 = 60_000
    private var maxSpanMs: Int64 { defaultWindowHours * 3_600_000 }
    private let motionBucketsCount = 1440
    private let motionBucketThreshold: Float = 0.006
    private let speedSteps: [Float] = [0.5, 1, 2, 4, 8]
    private let filmstripDebounceMs: UInt64 = 300
    /// How far before the current segment's end to resolve + queue the next one.
    /// Segments are ~4 s (`SEGMENT_SECONDS`), so this leaves the queued item time
    /// to probe + buffer before the boundary while staying inside the segment.
    private let prefetchLeadMs: Int64 = 2_500

    init(cameraId: String, container: AppContainer, startTime: Date? = nil, cameras: [CameraDto] = []) {
        self.cameraId = cameraId
        self.container = container
        self.pendingSeedMs = startTime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        self.timelineCameraIds = cameras.isEmpty ? [cameraId] : cameras.map(\.id)
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

    /// Must match the server's `MAX_INTENSITY_BATCH` (services/api/src/timeline.rs):
    /// the batch route 400s above this many camera ids, so we chunk. (#373)
    private static let maxIntensityBatch = 64

    private func loadIntensity(_ startMs: Int64, _ endMs: Int64) async {
        let ids = timelineCameraIds.isEmpty ? [cameraId] : timelineCameraIds
        let startISO = iso(startMs), endISO = iso(endMs)

        // Use the batch endpoint: one request per <=64-camera chunk instead of one
        // request per camera. The old per-camera fan-out issued N requests into the
        // shared rate limiter on every scrub re-center, so a large wall 429'd and
        // dropped motion bars. Falls back to the per-camera route on 404 (a server
        // predating the batch endpoint) or 400. (#373)
        var byId: [String: [Float]] = [:]
        var batchUnsupported = false
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i ..< min(i + Self.maxIntensityBatch, ids.count)])
            i += Self.maxIntensityBatch
            do {
                let resp = try await container.api.timelineIntensityBatch(
                    cameraIds: chunk, start: startISO, end: endISO, buckets: motionBucketsCount)
                for (id, buckets) in resp.cameras { byId[id] = buckets }
            } catch APIError.http(let statusCode, _) where statusCode == 404 || statusCode == 400 {
                batchUnsupported = true
                break
            } catch {
                // Transient failure for this chunk: leave its cameras zeroed (matches
                // the old per-camera `try?` behavior); the next scrub retries.
            }
        }

        if batchUnsupported {
            // Pre-batch server: fall back to the per-camera fan-out. Each Task
            // inherits the main actor and frees it on await, so requests overlap.
            let handles: [(String, Task<[Float]?, Never>)] = ids.map { id in
                (id, Task {
                    (try? await self.container.api.timelineIntensity(
                        cameraId: id, start: startISO, end: endISO, buckets: self.motionBucketsCount))?.buckets
                })
            }
            byId = [:]
            for (id, handle) in handles {
                if let buckets = await handle.value { byId[id] = buckets }
            }
        }

        guard !Task.isCancelled else { return }
        // Preserve the requested order (the server's map is unordered).
        let result: [(id: String, buckets: [Float])] = ids.compactMap { id in
            byId[id].map { (id: id, buckets: $0) }
        }
        motionByCamera = result
        motionBuckets = result.first(where: { $0.id == cameraId })?.buckets ?? result.first?.buckets ?? []
        motionStartMs = startMs
        motionEndMs = endMs
    }

    private func loadEvents(_ startMs: Int64, _ endMs: Int64) async {
        let resp = try? await container.api.events(cameraIds: cameraId, start: iso(startMs), end: iso(endMs), limit: 2000)
        guard !Task.isCancelled else { return }
        detectionEvents = (resp?.events ?? []).filter { !$0.iconKey.isEmpty && $0.iconKey != "motion" }
    }

    // ── segment resolution ──────────────────────────────────────────────────────

    func seekTo(_ tsMs: Int64) {
        playheadMs = tsMs
        resetPrefetch() // any queued next belonged to the old position
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            guard let self else { return }
            do {
                let segment = try await container.api.play(cameraId: cameraId, ts: iso(tsMs))
                guard !Task.isCancelled else { return }
                let startMs = parseMs(segment.start)
                let url = await container.mediaUrls().scopedURL(cameraId: cameraId, qualityPath(segment.url))
                guard !Task.isCancelled else { return }
                guard let url else {
                    // Media-token mint failed (transient — offline blip, session
                    // hiccup). Treat it like any other seek failure instead of
                    // leaving `currentSegment` set with a nil URL: that combination
                    // left playback silently black with no error and no retry,
                    // because the error/Retry UI below only shows when
                    // `currentSegment == nil`.
                    currentSegment = nil
                    currentSegmentURL = nil
                    segmentOffsetMs = 0
                    self.error = "Couldn't load this clip. Check your connection and retry."
                    noFootageAtPlayhead = false
                    seekGeneration += 1
                    return
                }
                currentSegment = segment
                currentSegmentURL = url
                segmentOffsetMs = max(tsMs - startMs, 0)
                error = nil
                noFootageAtPlayhead = false
                seekGeneration += 1
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
                seekGeneration += 1
            }
        }
    }

    /// Set the low-quality intent (from the view's resolved Full/Data-saver/Auto
    /// + metered computation). Mirrors Android's `setLowQuality`: re-selecting a
    /// low mode clears the fallback latch so it gets another chance.
    func setLowQuality(_ low: Bool) {
        if low { lowUnavailable = false } // re-selecting low clears the latch (retry)
        guard low != lowQuality else { return }
        lowQuality = low
        resetPrefetch()                                  // queued next used the old variant
        if currentSegment != nil { seekTo(playheadMs) }  // re-resolve at the new variant
    }

    /// Latch the low path off for the rest of the session after a `/low.mp4`
    /// request failed with an expected error, then re-resolve the playhead onto
    /// the raw segment. Mirrors Android's `noteLowQualityFailed`.
    private func noteLowQualityFailed() {
        guard lowQuality, !lowUnavailable else { return }
        lowUnavailable = true
        resetPrefetch()
        seekTo(playheadMs)
    }

    /// The player failed. If it was on a `/low.mp4` variant, classify the failure
    /// with a tiny probe: an expected hard error (404 on an older server / a
    /// segment it can't transcode, or another 4xx/5xx) latches the low path off
    /// for the session and re-resolves onto the raw segment; anything else — a
    /// transient blip, an expired token (401), or the first-hit transcode the
    /// player timed out on but the server has since cached — just re-resolves,
    /// which retries the (now-ready) low variant. Non-low failures re-resolve
    /// directly, exactly as before.
    func onPlayerError() {
        if lowQuality, !lowUnavailable, let url = currentSegmentURL,
           url.absoluteString.contains("/low.mp4") {
            let target = url
            Task { [weak self] in
                guard let self else { return }
                if await Self.lowVariantIsUnavailable(target) {
                    self.noteLowQualityFailed()
                } else {
                    self.seekTo(self.playheadMs)
                }
            }
            return
        }
        seekTo(playheadMs)
    }

    /// Probe a `/low.mp4` URL to distinguish a hard "can't serve this" failure
    /// (→ latch) from a transient one (→ retry). Returns true only for an expected
    /// hard status — 404 (older server without the endpoint, or a segment it
    /// can't handle) or another 4xx/5xx — and NOT 401 (token refresh) nor a
    /// network error. A 2-byte ranged GET, so it's near-free and rides the same
    /// media session; the generous timeout tolerates the server transcoding on
    /// the first hit before it responds.
    private static func lowVariantIsUnavailable(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        guard let (_, resp) = try? await URLSession.crumbMedia.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return false // network error → transient, don't latch
        }
        switch http.statusCode {
        case 200...299, 304: return false // low variant serves fine
        case 401:            return false // expired token → re-resolve, not a latch
        default:             return true  // 404 / other 4xx / 5xx → latch off
        }
    }

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
        maybePrefetchNext(tsMs)
    }

    // ── gapless prefetch (issue #23) ────────────────────────────────────────────

    /// As the current segment nears its end, resolve the next one and hand it to
    /// the player to queue — but only when it's immediately CONTIGUOUS (the end
    /// falls inside a recorded span). A recording gap keeps the old
    /// resolve-and-seek path, which isn't gapless anyway. Resolves at most once
    /// per current segment.
    private func maybePrefetchNext(_ tsMs: Int64) {
        guard playing, let seg = currentSegment else { return }
        let endMs = parseMs(seg.end)
        guard tsMs >= endMs - prefetchLeadMs else { return }
        guard prefetchedForSegmentId != seg.segmentId else { return }
        let contiguous = spans.contains { parseMs($0.start) <= endMs && endMs < parseMs($0.end) }
        guard contiguous else { return }
        prefetchedForSegmentId = seg.segmentId

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            guard let next = try? await container.api.play(cameraId: cameraId, ts: iso(endMs + 1)) else { return }
            // Bail if we seeked/switched away, or it resolved to the same segment.
            guard !Task.isCancelled, currentSegment?.segmentId == seg.segmentId,
                  next.segmentId != seg.segmentId else { return }
            guard let url = await container.mediaUrls().scopedURL(cameraId: cameraId, qualityPath(next.url)) else { return }
            guard !Task.isCancelled, currentSegment?.segmentId == seg.segmentId else { return }
            prefetchedSegment = next
            prefetchNext = PrefetchSignal(url: url, startMs: parseMs(next.start), path: next.url)
        }
    }

    /// The player gaplessly advanced to the prefetched next segment — promote it
    /// to `currentSegment` (updating the playhead base) without a re-resolve.
    /// Falls back to the normal end-of-segment path if the prefetch is somehow
    /// gone (shouldn't happen — the player only advances when it queued one).
    func commitAdvance() {
        guard let next = prefetchedSegment, let signal = prefetchNext else {
            onSegmentEnded()
            return
        }
        currentSegment = next
        let startMs = parseMs(next.start)
        segmentOffsetMs = 0
        playheadMs = startMs
        error = nil
        noFootageAtPlayhead = false
        currentSegmentURL = signal.url
        // The view now keys the feed on `seekGeneration`, not the URL, so bump it
        // here so `feed(url)` re-fires: the player recognises the just-advanced URL
        // and no-ops it, which is what CLEARS `SegmentPlayer.justAdvanced`. Without
        // this bump the latch stays set, and the first within-segment seek after a
        // gapless advance is silently swallowed during playback.
        seekGeneration += 1
        resetPrefetch() // let the NEW current segment queue its own next
    }

    private func resetPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedSegment = nil
        prefetchedForSegmentId = nil
        prefetchNext = nil
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
        if let nearest = filmstrip.min(by: { abs($0.ms - tsMs) < abs($1.ms - tsMs) }) {
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
                filmstrip = frames.map { (self.parseMs($0.ts), $0.url) }
                if scrubbing, let nearest = filmstrip.min(by: { abs($0.ms - playheadMs) < abs($1.ms - playheadMs) }) {
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
