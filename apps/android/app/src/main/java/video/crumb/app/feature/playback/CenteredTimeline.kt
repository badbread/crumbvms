// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.VectorPainter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import video.crumb.app.data.DetectionEvent
import video.crumb.app.data.DetectionIcons
import video.crumb.app.data.RecordedSpan
import video.crumb.app.ui.Time
import video.crumb.app.ui.theme.TextSecondary
import video.crumb.app.ui.theme.TimelineColors
import java.time.Instant
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Motion-bar thresholds, matched to the recorder's NEW motion_score scale
 * ("largest connected blob fraction": a person ≈ 0.3–7% of frame, distant
 * ≈ 0.3–0.8%). These mirror the desktop client.
 *
 * - [MOTION_FLOOR] (0.25% blob): below this → no bar (noise gate).
 * - [MOTION_CEIL]  (5% blob): at/above this → a full-height bar.
 *
 * They are ABSOLUTE constants, deliberately NOT derived from the in-view buckets,
 * so a given moment's bar height stays the same as the user scrolls/zooms the
 * timeline (an adaptive in-view scale would make the bars jump while scrolling).
 */
private const val MOTION_FLOOR = 0.0025f
private const val MOTION_CEIL = 0.05f

/**
 * Detection-glyph badge colours (N3 contrast fix). Each timeline detection icon
 * gets a dark backing disc + a soft halo so it stays clearly visible against the
 * busy blue motion band and any segment colour underneath it.
 */
private val ICON_HALO = Color(0xCC0E0F12)   // soft dark halo (matches TimelineColors.track)
private val ICON_DISC = Color(0xF21A1C22)   // near-opaque dark disc directly behind the glyph

/**
 * commercial-VMS-mobile-style **centered-playhead** timeline.
 *
 * The playhead is a fixed vertical line at the horizontal center; time scrolls
 * *through* it. Dragging horizontally moves time under the center line (drag
 * right = go back in time, content follows the finger). **Pinching** zooms the
 * time scale (1 min … data-window span). Motion is shown subtly as a thin amber
 * underline within the recorded band.
 *
 * @param spans Recorded spans (any covering the visible range render).
 * @param motionBuckets Per-bucket motion magnitude over [motionStartMs, motionEndMs]
 *   (from `/timeline/intensity`). Drawn as a BLUE activity histogram inside the
 *   recorded band (dim ribbon → bright azure cap by magnitude, matching the
 *   desktop) — this is what shows WHERE motion is. Empty → no motion overlay.
 * @param motionStartMs Epoch-millis the first motion bucket starts at.
 * @param motionEndMs Epoch-millis the last motion bucket ends at.
 * @param detectionEvents Detection events from `GET /events` for the current camera.
 *   Rendered as colored point markers above the motion layer. Empty → layer invisible,
 *   rendering is identical to having no events. Additive and non-fatal.
 * @param playheadMs Current playback position (rendered at the center).
 * @param spanMs Visible time span across the full width (pinch-to-zoom).
 * @param onScrubStart Called once when a gesture begins.
 * @param onScrub Called continuously with the new playhead time.
 * @param onScrubEnd Called once on release with the final playhead time.
 * @param onSpanChange Called when a pinch changes the visible span.
 */
@Composable
fun CenteredTimeline(
    spans: List<RecordedSpan>,
    motionBuckets: List<Float>,
    motionStartMs: Long,
    motionEndMs: Long,
    detectionEvents: List<DetectionEvent> = emptyList(),
    bookmarks: List<Long>,
    playheadMs: Long,
    spanMs: Long,
    onScrubStart: () -> Unit,
    onScrub: (Long) -> Unit,
    onScrubEnd: (Long) -> Unit,
    onSpanChange: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val textMeasurer = rememberTextMeasurer()
    // remembered so they aren't reallocated on every playhead tick (review B2).
    val gridStyle = remember { TextStyle(color = TextSecondary, fontSize = 9.sp) }
    val headStyle = remember { TextStyle(color = Color.White, fontSize = 11.sp) }

    // Latest values readable inside the (Unit-keyed) gesture loop.
    val playhead = rememberUpdatedState(playheadMs)
    val span = rememberUpdatedState(spanMs)

    // Detection-event glyphs, drawn on the timeline tinted per type (created here
    // in composable scope; the Canvas draws them via VectorPainter.draw).
    //
    // Per-label icon_key means there are many possible glyphs, but they all come
    // from the bounded set in DetectionIcons.icon(). We pre-create a painter for
    // each DISTINCT ImageVector in that set (a fixed, stable composable call
    // count) and resolve key → ImageVector → painter at draw time. Unknown keys
    // fall back to the generic painter.
    val genericPainter = rememberVectorPainter(Icons.Default.HelpOutline)
    // rememberVectorPainter is a fixed-count composable call (allIcons is stable);
    // the MAP, however, was rebuilt on every recomposition (4×/sec) — so build the
    // painters as a list, then remember the zip→map (review B2).
    val painters = DetectionIcons.allIcons.map { rememberVectorPainter(it) }
    val painterByVector: Map<ImageVector, VectorPainter> =
        remember(painters) { DetectionIcons.allIcons.zip(painters).toMap() }
    val painterForKey: (String) -> VectorPainter = { key ->
        painterByVector[DetectionIcons.icon(key)] ?: genericPainter
    }

    // Memoize the parsed detection timestamps OUT of the draw loop: this was
    // re-parsing up to ~2000 ISO strings (+ a fresh list + sort) on every draw
    // frame — the epoch-ms never change once the data arrives (review B1).
    val orderedDetections: List<Pair<Long, DetectionEvent>> = remember(detectionEvents) {
        detectionEvents
            .mapNotNull { ev ->
                runCatching { java.time.Instant.parse(ev.ts).toEpochMilli() }
                    .getOrNull()?.let { it to ev }
            }
            .sortedBy { it.first }
    }
    // Parse span start/end once per data change too (was Time.parseToMillis per
    // span per draw — review B1).
    val parsedSpans: List<Triple<Long, Long, RecordedSpan>> = remember(spans) {
        spans.map { Triple(Time.parseToMillis(it.start), Time.parseToMillis(it.end), it) }
    }

    Box(modifier = modifier.fillMaxWidth()) {
        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        onScrubStart()
                        var acc = playhead.value
                        var sp = span.value
                        val now = System.currentTimeMillis()
                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.count { it.pressed }
                            val zoom = event.calculateZoom()
                            if (zoom != 1f && zoom > 0f) {
                                sp = (sp / zoom).roundToLong()
                                    .coerceIn(60_000L, 6L * 3600_000L)
                                onSpanChange(sp)
                            }
                            // Only a single-finger drag scrubs. While PINCHING (two
                            // or more fingers) the incidental centroid drift that
                            // `calculatePan()` reports must NOT move the playhead —
                            // otherwise zooming also slides the current time, which
                            // is maddening. The centered playhead therefore stays
                            // fixed on the time the pinch started on; only the span
                            // (zoom) changes.
                            if (pressed < 2) {
                                val pan = event.calculatePan()
                                if (pan.x != 0f && size.width > 0) {
                                    // Drag right → earlier in time (content follows finger).
                                    val deltaMs = (-pan.x / size.width.toFloat() * sp).roundToLong()
                                    acc = (acc + deltaMs).coerceIn(0L, now)
                                    onScrub(acc)
                                }
                            }
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                            if (event.changes.none { it.pressed }) break
                        }
                        onScrubEnd(acc)
                    }
                },
        ) {
            val w = size.width
            val h = size.height
            val visStart = playheadMs - spanMs / 2
            val visEnd = playheadMs + spanMs / 2
            val visDur = (visEnd - visStart).coerceAtLeast(1L)
            fun xOf(ts: Long): Float = ((ts - visStart).toFloat() / visDur) * w

            val bandH = h * 0.42f
            val bandTop = (h - bandH) / 2f

            // The Trail band (mirrors the desktop TL palette): a slate baseline =
            // recording present, a faint blue base over recorded regions, and a BLUE
            // two-tone for motion density (dim ribbon → bright azure cap). Motion is
            // deliberately NOT red here — we moved it to blue to match the desktop.
            val baseH = (bandH * 0.14f).coerceAtLeast(2.5f)    // recording baseline thickness

            // 1. Empty track
            drawRect(color = TimelineColors.track, topLeft = Offset(0f, bandTop), size = Size(w, bandH))

            // 2. Recorded spans → faint blue base band + SLATE recording baseline.
            // Uses pre-parsed millis (review B1) — no ISO parse per draw.
            for ((s0, s1, _) in parsedSpans) {
                if (s1 < visStart || s0 > visEnd) continue
                val x1 = xOf(s0).coerceIn(0f, w)
                val x2 = xOf(s1).coerceIn(0f, w)
                val bw = (x2 - x1).coerceAtLeast(1.5f)
                // Faint blue base over the whole recorded region.
                drawRect(color = TimelineColors.motionBand, topLeft = Offset(x1, bandTop), size = Size(bw, bandH))
                // Slate "recording present" line along the bottom edge.
                drawRect(
                    color = TimelineColors.recording,
                    topLeft = Offset(x1, bandTop + bandH - baseH),
                    size = Size(bw, baseH),
                )
            }

            // 2b. Motion DENSITY marks (blue two-tone): one bar per bucket, height ∝
            // motion magnitude, rising from just above the slate baseline. Weak motion
            // = a dim blue ribbon (the "something moved" floor), strong/sustained =
            // a bright azure cap (the "event") — interpolated by magnitude so the bar
            // both grows AND brightens, matching the desktop's MOTION_LOW→MOTION read.
            if (motionBuckets.isNotEmpty() && motionEndMs > motionStartMs) {
                val n = motionBuckets.size
                val bucketDurMs = (motionEndMs - motionStartMs).toFloat() / n
                val motionMaxH = bandH - baseH                 // marks sit above the baseline
                for (i in 0 until n) {
                    val v = motionBuckets[i]
                    // ABSOLUTE thresholds matched to the recorder's NEW motion_score =
                    // "largest connected blob fraction" (a person ≈ 0.3–7% of frame,
                    // distant ≈ 0.3–0.8%). Below the floor → no bar; at/above the
                    // ceiling (~5% blob) → full height. These are fixed constants, NOT
                    // derived from the in-view buckets, so a bar's height never changes
                    // as you scroll the timeline.
                    if (v < MOTION_FLOOR) continue
                    val bt0 = motionStartMs + (i * bucketDurMs).toLong()
                    val bt1 = bt0 + bucketDurMs.toLong()
                    if (bt1 < visStart || bt0 > visEnd) continue
                    val x1 = xOf(bt0).coerceIn(0f, w)
                    val x2 = xOf(bt1).coerceIn(0f, w)
                    val bw = (x2 - x1).coerceAtLeast(1f)
                    // Map [floor, ceiling] → [min visible, full]. A small minimum keeps
                    // a just-above-floor blob visible without the old "everything is
                    // 22%" flattening.
                    val frac = ((v - MOTION_FLOOR) / (MOTION_CEIL - MOTION_FLOOR))
                        .coerceIn(0f, 1f)
                    val norm = 0.12f + 0.88f * frac
                    val mh = motionMaxH * norm
                    // Two-tone: dim blue ribbon at the floor → bright azure cap at the
                    // ceiling, so a bar both grows AND brightens with intensity.
                    val markColor = lerp(TimelineColors.motionLow, TimelineColors.motion, frac)
                    drawRect(
                        color = markColor,
                        topLeft = Offset(x1, bandTop + bandH - baseH - mh),
                        size = Size(bw, mh),
                    )
                }
            }

            // 2c. Bookmarks → gold downward triangle markers at the top of the band.
            // Reuse ONE Path (reset per marker) instead of allocating N per draw (B4).
            val bmTri = Path()
            for (bm in bookmarks) {
                if (bm < visStart || bm > visEnd) continue
                val bx = xOf(bm)
                bmTri.reset()
                bmTri.moveTo(bx, bandTop + 7f)
                bmTri.lineTo(bx - 5f, bandTop - 4f)
                bmTri.lineTo(bx + 5f, bandTop - 4f)
                bmTri.close()
                // Dark outline behind the gold so the marker reads against bright
                // motion bars too (N3 contrast pass).
                drawPath(
                    bmTri,
                    color = ICON_HALO,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.5f),
                )
                drawPath(bmTri, color = TimelineColors.bookmark)
            }

            // 2d. Detection event icons — point markers, one per event, ABOVE motion
            // spikes, BELOW the playhead. Layer is invisible when the list is empty
            // (additive: emits nothing, timeline looks identical without detection).
            if (detectionEvents.isNotEmpty()) {
                // Glyph size scales with zoom: closer zoom → bigger icon. The glyph
                // sits at the top of the band (above the motion marks below).
                val iconSize = when {
                    spanMs <= 5 * 60_000L -> 16.dp.toPx()    // ≤5 min zoom
                    spanMs <= 60 * 60_000L -> 13.dp.toPx()   // ≤1 h zoom
                    else -> 11.dp.toPx()                      // >1 h (48 h max)
                }
                val iconTop = bandTop + 1f
                // Time-ordered (pre-parsed/sorted, review B1) so collision-thinning
                // works left-to-right: skip any glyph overlapping the previous one.
                var lastX = Float.NEGATIVE_INFINITY
                for ((tsMs, event) in orderedDetections) {
                    val x = xOf(tsMs)
                    if (x < 0f || x > w) continue
                    if (x - lastX < iconSize) continue   // would overlap the previous glyph
                    lastX = x
                    val color = iconColorForKey(event.iconKey)
                    val painter = painterForKey(event.iconKey)
                    // CONTRAST: timeline glyphs were drawn as a single per-type tint and
                    // washed out against the (dark blue/azure) motion band below them. So
                    // give every glyph a high-contrast badge that reads against ANY
                    // segment colour:
                    //   1. a dark backing disc (kills the busy motion bars behind it),
                    //   2. a bright outline ring (the type colour, lightened),
                    //   3. the glyph itself drawn in near-white,
                    //   4. then a thin type-colour glyph on top for the colour cue.
                    val cx2 = x
                    val cy2 = iconTop + iconSize / 2f
                    val r = iconSize / 2f
                    // 1. dark backing disc + halo so the badge separates from the band.
                    drawCircle(color = ICON_HALO, radius = r + 2f, center = Offset(cx2, cy2))
                    drawCircle(color = ICON_DISC, radius = r + 0.5f, center = Offset(cx2, cy2))
                    // 2. bright type-colour outline ring.
                    drawCircle(
                        color = lerp(color, Color.White, 0.35f),
                        radius = r + 0.5f,
                        center = Offset(cx2, cy2),
                        style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.6f),
                    )
                    // The glyph is drawn at ~78% of the badge so it sits inside the ring.
                    val gSize = iconSize * 0.78f
                    val gLeft = x - gSize / 2f
                    val gTop = cy2 - gSize / 2f
                    // 3. near-white base glyph for maximum legibility…
                    translate(left = gLeft, top = gTop) {
                        with(painter) {
                            draw(
                                size = Size(gSize, gSize),
                                colorFilter = ColorFilter.tint(Color.White),
                            )
                        }
                    }
                    // 4. …then a thin type-colour glyph on top so the colour still reads.
                    translate(left = gLeft, top = gTop) {
                        with(painter) {
                            draw(
                                size = Size(gSize, gSize),
                                alpha = 0.55f,
                                colorFilter = ColorFilter.tint(lerp(color, Color.White, 0.2f)),
                            )
                        }
                    }
                }
            }

            // 3. Grid ticks + labels (auto interval for the visible span)
            drawCenteredGrid(visStart, visEnd, visDur, w, h, bandTop, textMeasurer, gridStyle)

            // 4. Fixed centered playhead + floating time label
            val cx = w / 2f
            drawLine(
                color = TimelineColors.playhead,
                start = Offset(cx, bandTop - 10f),
                end = Offset(cx, bandTop + bandH + 6f),
                strokeWidth = 2.5f,
            )
            val tri = Path().apply {
                moveTo(cx, bandTop)
                lineTo(cx - 6f, bandTop - 10f)
                lineTo(cx + 6f, bandTop - 10f)
                close()
            }
            drawPath(tri, color = TimelineColors.playhead)
            // Date + time label centered above the playhead (day must be visible).
            val label = Time.dateTime(Instant.ofEpochMilli(playheadMs))
            val measured = textMeasurer.measure(label, headStyle, overflow = TextOverflow.Clip)
            val lx = (cx - measured.size.width / 2f).coerceIn(0f, w - measured.size.width.toFloat())
            drawText(measured, topLeft = Offset(lx, 0f))
        }
    }
}

// ─── Detection event icon helpers ────────────────────────────────────────────

/**
 * Returns the [Color] for a per-label detection [iconKey] (== the label slug),
 * delegating to the shared [DetectionIcons] so the timeline and the live wall
 * stay in lockstep. Unknown labels resolve to the neutral generic colour.
 */
private fun iconColorForKey(iconKey: String): Color = DetectionIcons.color(iconKey)

/** Pick a readable grid interval for the visible span, then draw ticks + labels. */
private fun DrawScope.drawCenteredGrid(
    visStart: Long,
    visEnd: Long,
    visDur: Long,
    w: Float,
    h: Float,
    bandTop: Float,
    textMeasurer: TextMeasurer,
    style: TextStyle,
) {
    val m = 60_000L
    val hr = 3600_000L
    val interval = when {
        visDur <= 5 * m -> m
        visDur <= 20 * m -> 5 * m
        visDur <= 60 * m -> 10 * m
        visDur <= 3 * hr -> 30 * m
        else -> hr
    }
    // First grid tick at or after visStart, snapped to an interval multiple.
    var t = visStart + ((interval - (visStart % interval)) % interval)
    while (t <= visEnd) {
        val x = ((t - visStart).toFloat() / visDur) * w
        drawLine(
            color = TimelineColors.grid,
            start = Offset(x, bandTop - 4f),
            end = Offset(x, bandTop + (h - bandTop)),
            strokeWidth = 1f,
        )
        val label = Time.clockShort(Instant.ofEpochMilli(t))
        val measured = textMeasurer.measure(label, style, overflow = TextOverflow.Clip)
        val lx = (x - measured.size.width / 2f).coerceIn(0f, w - measured.size.width.toFloat())
        val ly = h - measured.size.height - 1f
        if (abs(x - w / 2f) > measured.size.width) { // don't collide with the center label
            drawText(measured, topLeft = Offset(lx, ly))
        }
        t += interval
    }
}
