// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Centered-playhead scrub timeline — a faithful port of the Android
/// `CenteredTimeline`. The playhead is fixed at center; time scrolls through it.
/// Drag = pan time (right → earlier). Pinch = zoom the visible span (1 min … 6 h).
///
/// Critically, dragging only emits `onScrub` (cheap: update playhead + filmstrip);
/// the expensive segment resolve happens once on `onScrubEnd`. The previous
/// version resolved every tick, which caused the scrub stutter.
struct CenteredTimelineView: View {

    let spans: [RecordedSpan]
    let motionBuckets: [Float]
    let motionStartMs: Int64
    let motionEndMs: Int64
    let detectionEvents: [DetectionEvent]
    let bookmarks: [Int64]
    let playheadMs: Int64
    let spanMs: Int64
    let onScrubStart: () -> Void
    let onScrub: (Int64) -> Void
    let onScrubEnd: (Int64) -> Void
    let onSpanChange: (Int64) -> Void

    // Export-range selection (desktop "mark for export", macOS right-click). Left
    // nil by callers that don't offer it (e.g. the multi-camera playback wall).
    var exportSelStartMs: Int64? = nil
    var exportSelEndMs: Int64? = nil
    var onSetExportStart: ((Int64) -> Void)? = nil
    var onSetExportEnd: ((Int64) -> Void)? = nil
    var onExportSelection: (() -> Void)? = nil
    var onClearExportSelection: (() -> Void)? = nil

    // Gesture bases captured at gesture start.
    @State private var dragBaseMs: Int64?
    @State private var pinchBaseSpan: Int64?

    private let minSpanMs: Int64 = 60_000
    private let maxSpanMs: Int64 = 6 * 3_600_000

    // motion thresholds (absolute, matched to recorder blob-fraction scale)
    private let motionFloor: Float = 0.0025
    private let motionCeil: Float = 0.05
    private let motionThreshold: Float = 0.006

    // MARK: - M5: precomputed spans/detections
    //
    // `draw(ctx:size:)` runs on every `Canvas` redraw — i.e. every scrub tick,
    // every pinch-zoom frame, every playhead-advance tick during playback.
    // Re-running `parseISO8601` over the full `spans`/`detectionEvents` arrays
    // on EVERY one of those redraws (as the old computed properties did) is
    // wasted, non-trivial work repeated dozens of times a second. Instead,
    // parse once whenever the *source* arrays actually change (`.task(id:)`,
    // keyed off cheap identity — Array<RecordedSpan>/[DetectionEvent] aren't
    // Equatable here, so we key off count — swap to a stronger key if spans
    // ever mutate in place without changing count) and cache the result.
    @State private var parsedSpans: [(Int64, Int64)] = []
    @State private var parsedDetections: [(Int64, DetectionEvent)] = []
    /// Detection events with a resolved `[start, end]` span (only those with an
    /// `end_ts`) — drives the active-event highlight band under the playhead.
    @State private var parsedEventSpans: [(Int64, Int64, DetectionEvent)] = []
    @State private var distinctIconKeys: [String] = []

    /// Cheap (O(1), no full-array scan) change key for `spans` — count plus
    /// the first and last span's raw start string. Good enough to distinguish
    /// "genuinely new data" from "same array, SwiftUI just re-diffed" without
    /// the cost of hashing/parsing the whole array on every body evaluation.
    private var spansIdentity: String {
        "\(spans.count)|\(spans.first?.start ?? "")|\(spans.last?.end ?? "")"
    }

    /// Same idea as `spansIdentity`, for `detectionEvents`.
    private var detectionsIdentity: String {
        "\(detectionEvents.count)|\(detectionEvents.first?.ts ?? "")|\(detectionEvents.last?.ts ?? "")"
    }

    private func recomputeParsedSpans() {
        parsedSpans = spans.compactMap { s in
            guard let a = parseISO8601(s.start), let b = parseISO8601(s.end) else { return nil }
            return (Int64(a.timeIntervalSince1970 * 1000), Int64(b.timeIntervalSince1970 * 1000))
        }
    }

    private func recomputeParsedDetections() {
        parsedDetections = detectionEvents.compactMap { e in
            guard let d = parseISO8601(e.ts) else { return nil }
            return (Int64(d.timeIntervalSince1970 * 1000), e)
        }.sorted { $0.0 < $1.0 }
        parsedEventSpans = detectionEvents.compactMap { e in
            guard let end = e.endTs, let s = parseISO8601(e.ts), let en = parseISO8601(end) else { return nil }
            let sMs = Int64(s.timeIntervalSince1970 * 1000), eMs = Int64(en.timeIntervalSince1970 * 1000)
            guard eMs > sMs else { return nil }
            return (sMs, eMs, e)
        }
        distinctIconKeys = Array(Set(detectionEvents.map(\.iconKey))).sorted()
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            } symbols: {
                ForEach(distinctIconKeys, id: \.self) { key in
                    Image(systemName: DetectionIcons.sfSymbol(for: key))
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .tag(key)
                }
            }
            // M5: parse spans/detections once per data change, not once per
            // draw. `.task(id:)` cancels+reruns only when the id changes. Keyed
            // on count + first/last raw timestamp (cheap — O(1), no full-array
            // scan) rather than count alone, so a same-count reload after a
            // window shift (e.g. jump-to-time) is still detected as a change.
            .task(id: spansIdentity) { recomputeParsedSpans() }
            .task(id: detectionsIdentity) { recomputeParsedDetections() }
            .onAppear {
                if parsedSpans.isEmpty { recomputeParsedSpans() }
                if parsedDetections.isEmpty { recomputeParsedDetections() }
            }
            .contentShape(Rectangle())
            #if os(macOS)
            // Mouse: drag to pan, scroll-wheel to zoom the visible span — handled
            // in an AppKit overlay since SwiftUI exposes no scroll-wheel hook and a
            // mouse can't pinch.
            .overlay(
                TimelineMouseView(
                    onPanStart: {
                        if dragBaseMs == nil { dragBaseMs = playheadMs; onScrubStart() }
                    },
                    onPan: { dx in pan(dx: dx, width: geo.size.width, commit: false) },
                    onPanEnd: { dx in pan(dx: dx, width: geo.size.width, commit: true) },
                    onZoom: { delta in zoom(by: delta) },
                    playheadMs: playheadMs,
                    spanMs: spanMs,
                    exportSelStartMs: exportSelStartMs,
                    exportSelEndMs: exportSelEndMs,
                    onSetExportStart: onSetExportStart,
                    onSetExportEnd: onSetExportEnd,
                    onExportSelection: onExportSelection,
                    onClearExportSelection: onClearExportSelection
                )
            )
            #else
            .gesture(dragGesture(width: geo.size.width))
            .simultaneousGesture(pinchGesture())
            #endif
        }
    }

    /// Pan helper shared by the macOS mouse overlay (drag right → earlier).
    private func pan(dx: CGFloat, width: CGFloat, commit: Bool) {
        guard let base = dragBaseMs, width > 0 else { return }
        let deltaMs = Int64(-dx / width * CGFloat(spanMs))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let v = min(max(base + deltaMs, 0), now)
        if commit { dragBaseMs = nil; onScrubEnd(v) } else { onScrub(v) }
    }

    /// Scroll-wheel zoom: scroll up/away → zoom in (smaller span), clamped.
    private func zoom(by delta: CGFloat) {
        guard delta != 0 else { return }
        let factor = delta > 0 ? 0.9 : (1.0 / 0.9)
        let next = Int64((Double(spanMs) * factor).rounded())
        onSpanChange(min(max(next, minSpanMs), maxSpanMs))
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // A pinch owns the touch sequence → zoom only, never scrub. The
                // two-finger centroid drifts as you pinch, and letting that drive
                // `onScrub` is the "time slides while I zoom" bug: while ≥2 fingers
                // are down (pinchBaseSpan set) we skip the pan→scrub entirely.
                if pinchBaseSpan != nil { return }
                if dragBaseMs == nil {
                    dragBaseMs = playheadMs
                    onScrubStart()
                }
                guard let base = dragBaseMs, width > 0 else { return }
                // Drag right → earlier in time (content follows the finger).
                let deltaMs = Int64(-value.translation.width / width * CGFloat(spanMs))
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                onScrub(min(max(base + deltaMs, 0), now))
            }
            .onEnded { value in
                // Don't commit a scrub the pinch cancelled (dragBaseMs cleared in
                // pinchGesture) or that a pinch is still owning.
                guard pinchBaseSpan == nil, let base = dragBaseMs, width > 0 else {
                    dragBaseMs = nil
                    return
                }
                let deltaMs = Int64(-value.translation.width / width * CGFloat(spanMs))
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let final = min(max(base + deltaMs, 0), now)
                dragBaseMs = nil
                onScrubEnd(final)
            }
    }

    private func pinchGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchBaseSpan == nil {
                    pinchBaseSpan = spanMs
                    // If a one-finger scrub started a frame or two before the
                    // pinch was recognized, cancel it: snap the playhead back to
                    // where the gesture began and end the scrub cleanly, so the
                    // pinch keeps the current time pinned on the time it started
                    // on (Android's fix).
                    if let anchor = dragBaseMs {
                        dragBaseMs = nil
                        onScrubEnd(anchor)
                    }
                }
                guard let base = pinchBaseSpan, value > 0 else { return }
                let next = Int64(Double(base) / value)
                onSpanChange(min(max(next, minSpanMs), maxSpanMs))
            }
            .onEnded { _ in pinchBaseSpan = nil }
    }

    // MARK: - drawing

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let visStart = playheadMs - spanMs / 2
        let visEnd = playheadMs + spanMs / 2
        let visDur = max(visEnd - visStart, 1)
        func xOf(_ ts: Int64) -> CGFloat { CGFloat(Double(ts - visStart) / Double(visDur)) * w }

        let bandH = h * 0.42
        let bandTop = (h - bandH) / 2
        let baseH = max(bandH * 0.14, 2.5)

        // 1. empty track
        ctx.fill(Path(CGRect(x: 0, y: bandTop, width: w, height: bandH)), with: .color(TLColors.track))

        // 2. recorded spans → faint blue base + slate baseline
        for (s0, s1) in parsedSpans {
            if s1 < visStart || s0 > visEnd { continue }
            let x1 = min(max(xOf(s0), 0), w)
            let x2 = min(max(xOf(s1), 0), w)
            let bw = max(x2 - x1, 1.5)
            ctx.fill(Path(CGRect(x: x1, y: bandTop, width: bw, height: bandH)), with: .color(TLColors.motionBand))
            ctx.fill(Path(CGRect(x: x1, y: bandTop + bandH - baseH, width: bw, height: baseH)), with: .color(TLColors.recording))
        }

        // 2b. motion density bars (two-tone blue)
        if !motionBuckets.isEmpty, motionEndMs > motionStartMs {
            let n = motionBuckets.count
            let bucketDur = Double(motionEndMs - motionStartMs) / Double(n)
            let motionMaxH = bandH - baseH
            for i in 0..<n {
                let v = motionBuckets[i]
                if v < motionFloor { continue }
                let bt0 = motionStartMs + Int64(Double(i) * bucketDur)
                let bt1 = bt0 + Int64(bucketDur)
                if bt1 < visStart || bt0 > visEnd { continue }
                let x1 = min(max(xOf(bt0), 0), w)
                let x2 = min(max(xOf(bt1), 0), w)
                let bw = max(x2 - x1, 1)
                let frac = min(max((v - motionFloor) / (motionCeil - motionFloor), 0), 1)
                let norm = 0.12 + 0.88 * frac
                let mh = motionMaxH * CGFloat(norm)
                let color = lerpColor(TLColors.motionLow, TLColors.motion, Double(frac))
                ctx.fill(Path(CGRect(x: x1, y: bandTop + bandH - baseH - mh, width: bw, height: mh)), with: .color(color))
            }
        }

        // 2c. bookmarks → gold downward triangles
        for bm in bookmarks {
            if bm < visStart || bm > visEnd { continue }
            let bx = xOf(bm)
            var tri = Path()
            tri.move(to: CGPoint(x: bx, y: bandTop + 7))
            tri.addLine(to: CGPoint(x: bx - 5, y: bandTop - 4))
            tri.addLine(to: CGPoint(x: bx + 5, y: bandTop - 4))
            tri.closeSubpath()
            ctx.stroke(tri, with: .color(TLColors.iconHalo), lineWidth: 2.5)
            ctx.fill(tri, with: .color(CrumbColors.bookmarkGold))
        }

        // 2c.5 active-event highlight — for any detection event whose [start,end]
        // span contains the playhead, draw a faint colour band + edge lines (the
        // "what event am I inside" readout, desktop parity, #57). Drawn under the
        // glyphs so the badge stays crisp on top.
        for (s0, s1, ev) in parsedEventSpans {
            guard playheadMs >= s0, playheadMs <= s1 else { continue }
            if s1 < visStart || s0 > visEnd { continue }
            let x1 = min(max(xOf(s0), 0), w)
            let x2 = min(max(xOf(s1), 0), w)
            let color = DetectionIcons.color(for: ev.iconKey)
            ctx.fill(Path(CGRect(x: x1, y: bandTop, width: max(x2 - x1, 1), height: bandH)),
                     with: .color(color.opacity(0.16)))
            if xOf(s0) >= 0, xOf(s0) <= w {
                ctx.fill(Path(CGRect(x: x1, y: bandTop, width: 1.2, height: bandH)), with: .color(color.opacity(0.7)))
            }
            if xOf(s1) >= 0, xOf(s1) <= w {
                ctx.fill(Path(CGRect(x: x2 - 1.2, y: bandTop, width: 1.2, height: bandH)), with: .color(color.opacity(0.4)))
            }
        }

        // 2d. detection glyphs (collision-thinned badges)
        if !parsedDetections.isEmpty {
            let iconSize: CGFloat = spanMs <= 5 * 60_000 ? 16 : (spanMs <= 60 * 60_000 ? 13 : 11)
            let iconTop = bandTop + 1
            var lastX = -CGFloat.infinity
            for (tsMs, ev) in parsedDetections {
                let x = xOf(tsMs)
                if x < 0 || x > w { continue }
                if x - lastX < iconSize { continue }
                lastX = x
                let color = DetectionIcons.color(for: ev.iconKey)
                let cy = iconTop + iconSize / 2
                let r = iconSize / 2
                ctx.fill(Path(ellipseIn: CGRect(x: x - r - 2, y: cy - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)), with: .color(TLColors.iconHalo))
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(TLColors.iconDisc))
                ctx.stroke(Path(ellipseIn: CGRect(x: x - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(lerpColor(color, .white, 0.35)), lineWidth: 1.4)
                let gSize = iconSize * 0.74
                if let sym = ctx.resolveSymbol(id: ev.iconKey) {
                    ctx.draw(sym, in: CGRect(x: x - gSize / 2, y: cy - gSize / 2, width: gSize, height: gSize))
                }
            }
        }

        // 2e. export-range selection — translucent amber fill bracketed by two
        // solid amber handles (the desktop "mark for export" region).
        if let s = exportSelStartMs, let e = exportSelEndMs {
            let a = min(s, e), b = max(s, e)
            if b >= visStart && a <= visEnd {
                let xa = min(max(xOf(a), 0), w)
                let xb = min(max(xOf(b), 0), w)
                ctx.fill(Path(CGRect(x: xa, y: bandTop, width: max(xb - xa, 1), height: bandH)), with: .color(TLColors.exportFill))
                for hx in [xOf(a), xOf(b)] where hx >= 0 && hx <= w {
                    ctx.fill(Path(CGRect(x: hx - 1.5, y: bandTop - 6, width: 3, height: bandH + 12)), with: .color(TLColors.exportHandle))
                }
            }
        }

        // 3. grid ticks + labels
        drawGrid(ctx: ctx, visStart: visStart, visEnd: visEnd, visDur: visDur, w: w, h: h, bandTop: bandTop)

        // 4. centered playhead + date label
        let cx = w / 2
        ctx.stroke(
            Path { p in p.move(to: CGPoint(x: cx, y: bandTop - 10)); p.addLine(to: CGPoint(x: cx, y: bandTop + bandH + 6)) },
            with: .color(TLColors.playhead), lineWidth: 2.5
        )
        var ptri = Path()
        ptri.move(to: CGPoint(x: cx, y: bandTop))
        ptri.addLine(to: CGPoint(x: cx - 6, y: bandTop - 10))
        ptri.addLine(to: CGPoint(x: cx + 6, y: bandTop - 10))
        ptri.closeSubpath()
        ctx.fill(ptri, with: .color(TLColors.playhead))

        let label = headLabel(playheadMs)
        let text = ctx.resolve(Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(.white))
        let tsize = text.measure(in: CGSize(width: w, height: 20))
        ctx.draw(text, at: CGPoint(x: min(max(cx, tsize.width / 2), w - tsize.width / 2), y: 8))
    }

    private func drawGrid(ctx: GraphicsContext, visStart: Int64, visEnd: Int64, visDur: Int64, w: CGFloat, h: CGFloat, bandTop: CGFloat) {
        let m: Int64 = 60_000, hr: Int64 = 3_600_000
        let interval: Int64
        switch visDur {
        case ..<(5 * m): interval = m
        case ..<(20 * m): interval = 5 * m
        case ..<(60 * m): interval = 10 * m
        case ..<(3 * hr): interval = 30 * m
        default: interval = hr
        }
        var t = visStart + ((interval - (visStart % interval)) % interval)
        let cx = w / 2
        while t <= visEnd {
            let x = CGFloat(Double(t - visStart) / Double(visDur)) * w
            ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: bandTop - 4)); p.addLine(to: CGPoint(x: x, y: h)) }, with: .color(TLColors.grid), lineWidth: 1)
            let label = clockLabel(t)
            let text = ctx.resolve(Text(label).font(.system(size: 9)).foregroundColor(CrumbColors.textSecondary))
            let tsize = text.measure(in: CGSize(width: 80, height: 14))
            if abs(x - cx) > tsize.width {
                ctx.draw(text, at: CGPoint(x: min(max(x, tsize.width / 2), w - tsize.width / 2), y: h - tsize.height / 2 - 1))
            }
            t += interval
        }
    }

    private func headLabel(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "MMM d  HH:mm:ss"
        return f.string(from: d)
    }
    private func clockLabel(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func lerpColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ua = PlatformColor(a), ub = PlatformColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let f = CGFloat(t)
        return Color(red: Double(r1 + (r2 - r1) * f), green: Double(g1 + (g2 - g1) * f), blue: Double(b1 + (b2 - b1) * f))
    }
}

#if os(macOS)
import AppKit

/// Transparent AppKit overlay that drives the timeline with a mouse: drag pans,
/// scroll-wheel zooms, dragging an export handle resizes the export region.
/// Lives on macOS only; iOS uses SwiftUI drag/pinch gestures.
private struct TimelineMouseView: NSViewRepresentable {
    let onPanStart: () -> Void
    let onPan: (CGFloat) -> Void
    let onPanEnd: (CGFloat) -> Void
    let onZoom: (CGFloat) -> Void
    let playheadMs: Int64
    let spanMs: Int64
    let exportSelStartMs: Int64?
    let exportSelEndMs: Int64?
    let onSetExportStart: ((Int64) -> Void)?
    let onSetExportEnd: ((Int64) -> Void)?
    let onExportSelection: (() -> Void)?
    let onClearExportSelection: (() -> Void)?

    func makeNSView(context: Context) -> MouseNSView { configure(MouseNSView()) }
    func updateNSView(_ v: MouseNSView, context: Context) { _ = configure(v) }

    private func configure(_ v: MouseNSView) -> MouseNSView {
        v.onPanStart = onPanStart; v.onPan = onPan; v.onPanEnd = onPanEnd; v.onZoom = onZoom
        v.playheadMs = playheadMs; v.spanMs = spanMs
        v.exportSelStartMs = exportSelStartMs; v.exportSelEndMs = exportSelEndMs
        v.onSetExportStart = onSetExportStart; v.onSetExportEnd = onSetExportEnd
        v.onExportSelection = onExportSelection; v.onClearExportSelection = onClearExportSelection
        return v
    }

    final class MouseNSView: NSView {
        var onPanStart: () -> Void = {}
        var onPan: (CGFloat) -> Void = { _ in }
        var onPanEnd: (CGFloat) -> Void = { _ in }
        var onZoom: (CGFloat) -> Void = { _ in }
        var playheadMs: Int64 = 0
        var spanMs: Int64 = 0
        var exportSelStartMs: Int64?
        var exportSelEndMs: Int64?
        var onSetExportStart: ((Int64) -> Void)?
        var onSetExportEnd: ((Int64) -> Void)?
        var onExportSelection: (() -> Void)?
        var onClearExportSelection: (() -> Void)?

        private var hasExportSelection: Bool { exportSelStartMs != nil && exportSelEndMs != nil }

        private var startX: CGFloat = 0
        private var menuTimeMs: Int64 = 0
        /// Which export edge a left-drag is resizing: the callback for the edge
        /// grabbed at mouseDown (start or end), captured so the same edge keeps
        /// following the mouse even if the handles cross mid-drag. nil = pan.
        private var resizeEdge: ((Int64) -> Void)?

        /// Pixels of grab slack around an export handle (the drawn handle is 3px).
        private static let handleTolerance: CGFloat = 6

        override func scrollWheel(with event: NSEvent) {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            if d != 0 { onZoom(d) }
        }

        /// Time at an x offset for the CURRENT view window (only valid while not
        /// panning — the window follows the playhead, which a pan itself moves).
        private func timeAt(x: CGFloat) -> Int64 {
            let w = bounds.width
            guard w > 0 else { return playheadMs }
            let frac = max(0, min(1, x / w))
            return (playheadMs - spanMs / 2) + Int64(Double(frac) * Double(spanMs))
        }

        /// The export-edge setter whose handle sits within grab range of `x`,
        /// or nil when none does. Nearest wins when the two handles overlap.
        private func exportEdge(near x: CGFloat) -> ((Int64) -> Void)? {
            guard let s = exportSelStartMs, let e = exportSelEndMs,
                  onSetExportStart != nil, onSetExportEnd != nil,
                  bounds.width > 0, spanMs > 0 else { return nil }
            let visStart = playheadMs - spanMs / 2
            func xOf(_ ts: Int64) -> CGFloat {
                CGFloat(Double(ts - visStart) / Double(spanMs)) * bounds.width
            }
            let dS = abs(xOf(s) - x), dE = abs(xOf(e) - x)
            if min(dS, dE) > Self.handleTolerance { return nil }
            return dS <= dE ? onSetExportStart : onSetExportEnd
        }

        override func mouseDown(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            // Grabbing an export handle resizes the region instead of panning.
            if let edge = exportEdge(near: x) {
                resizeEdge = edge
                edge(clampToNow(timeAt(x: x)))
                return
            }
            startX = x
            onPanStart()
        }
        override func mouseDragged(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            if let edge = resizeEdge {
                edge(clampToNow(timeAt(x: x)))
                return
            }
            onPan(x - startX)
        }
        override func mouseUp(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            if let edge = resizeEdge {
                edge(clampToNow(timeAt(x: x)))
                resizeEdge = nil
                return
            }
            onPanEnd(x - startX)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func clampToNow(_ ms: Int64) -> Int64 {
            min(max(ms, 0), Int64(Date().timeIntervalSince1970 * 1000))
        }

        // Resize cursor while hovering an export handle, so it reads as draggable.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for ta in trackingAreas { removeTrackingArea(ta) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil
            ))
        }
        override func mouseMoved(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            if resizeEdge != nil || exportEdge(near: x) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        // Right-click → "mark for export" menu, with the bracket edge placed at the
        // clicked time (matching the desktop client).
        override func rightMouseDown(with event: NSEvent) {
            guard onSetExportStart != nil else { super.rightMouseDown(with: event); return }
            let w = bounds.width
            guard w > 0 else { return }
            let x = convert(event.locationInWindow, from: nil).x
            let frac = max(0, min(1, x / w))
            menuTimeMs = (playheadMs - spanMs / 2) + Int64(Double(frac) * Double(spanMs))

            let menu = NSMenu()
            menu.autoenablesItems = false
            let start = NSMenuItem(title: "Set export start here", action: #selector(miSetStart), keyEquivalent: "")
            start.target = self; menu.addItem(start)
            let end = NSMenuItem(title: "Set export end here", action: #selector(miSetEnd), keyEquivalent: "")
            end.target = self; menu.addItem(end)
            menu.addItem(.separator())
            let exp = NSMenuItem(title: "Export selection…", action: #selector(miExport), keyEquivalent: "")
            exp.target = self; exp.isEnabled = hasExportSelection; menu.addItem(exp)
            let clr = NSMenuItem(title: "Clear selection", action: #selector(miClear), keyEquivalent: "")
            clr.target = self; clr.isEnabled = hasExportSelection; menu.addItem(clr)

            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func miSetStart() { onSetExportStart?(menuTimeMs) }
        @objc private func miSetEnd() { onSetExportEnd?(menuTimeMs) }
        @objc private func miExport() { onExportSelection?() }
        @objc private func miClear() { onClearExportSelection?() }
    }
}
#endif

private enum TLColors {
    static let track = Color(hex: 0x16181D)
    static let motionBand = Color(red: 0.12, green: 0.18, blue: 0.32).opacity(0.55)
    static let recording = Color(hex: 0x5B6B8C)
    static let motion = Color(hex: 0x2196F3)
    static let motionLow = Color(hex: 0x16385C)
    static let playhead = Color(hex: 0x4DB6AC)
    static let grid = Color.white.opacity(0.13)
    static let iconHalo = Color(red: 0.05, green: 0.06, blue: 0.07, opacity: 0.8)
    static let iconDisc = Color(red: 0.10, green: 0.11, blue: 0.13, opacity: 0.95)
    static let exportHandle = Color(hex: 0xE8A33D)
    static let exportFill = Color(hex: 0xE8A33D).opacity(0.22)
}
