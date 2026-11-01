// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import video.crumb.app.ui.theme.monoStyle
import androidx.compose.ui.geometry.CornerRadius
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
 * @param minSpanMs Minimum pinch-zoomed-in span (max zoom-in), clamped inside the
 *   gesture itself so [onSpanChange] never sees a value outside the host's range.
 * @param maxSpanMs Maximum pinch-zoomed-out span (max zoom-out) — must match the
 *   host's own data-window width (e.g. the playback wall's 12 h vs. single-camera
 *   playback's 6 h), or pinch-out silently stops working before the host's actual
 *   range is reached.
 * @param onScrubStart Called once when a gesture begins.
 * @param onScrub Called continuously with the new playhead time.
 * @param onScrubEnd Called once on release with the final playhead time.
 * @param onSpanChange Called when a pinch changes the visible span.
 * @param exportSelStartMs Raw IN edge of the export bracket (epoch-millis), or null
 *   when nothing is marked. Edges are stored as the operator placed them and only
 *   ordered when drawn, mirroring the desktop selection model.
 * @param exportSelEndMs Raw OUT edge of the export bracket, or null.
 * @param onSetExportStart Called while dragging the IN handle. Null (with
 *   [onSetExportEnd]) disables edge-dragging entirely, which is what the
 *   multi-camera playback wall wants.
 * @param onSetExportEnd Called while dragging the OUT handle.
 * @param timeChip When true (single-camera playback) the playhead time is drawn as a
 *   12 sp mono chip centred above the playhead (P5). The playback wall passes false
 *   and shows the time on its control row instead (W4).
 * @param reserveMarkerBand When true, a 16 dp band above the bars is reserved for the
 *   detection glyphs (P6) so they no longer overlap the bar area. On short (landscape)
 *   timelines the band shares its row with the time chip.
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
    minSpanMs: Long = 60_000L,
    maxSpanMs: Long = 6L * 3600_000L,
    onScrubStart: () -> Unit,
    onScrub: (Long) -> Unit,
    onScrubEnd: (Long) -> Unit,
    onSpanChange: (Long) -> Unit,
    exportSelStartMs: Long? = null,
    exportSelEndMs: Long? = null,
    onSetExportStart: ((Long) -> Unit)? = null,
    onSetExportEnd: ((Long) -> Unit)? = null,
    timeChip: Boolean = false,
    reserveMarkerBand: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val textMeasurer = rememberTextMeasurer()
    val chipStyle = remember { monoStyle(12.sp).copy(color = Color.White) }
    // remembered so they aren't reallocated on every playhead tick (review B2).
    val gridStyle = remember { TextStyle(color = TextSecondary, fontSize = 9.sp) }

    // Latest values readable inside the (Unit-keyed) gesture loop.
    val playhead = rememberUpdatedState(playheadMs)
    val span = rememberUpdatedState(spanMs)
    // Export bracket, likewise readable from the gesture loop without re-keying it.
    val selStart = rememberUpdatedState(exportSelStartMs)
    val selEnd = rememberUpdatedState(exportSelEndMs)
    val setSelStart = rememberUpdatedState(onSetExportStart)
    val setSelEnd = rememberUpdatedState(onSetExportEnd)

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
                    // Touch grab radius for an export handle. Desktop uses 7 px
                    // against a mouse cursor; a fingertip needs a wider target, so
                    // this is expressed in dp and converted per-device.
                    val grabPx = 16.dp.toPx()
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)

                        // Time under an x offset for the CURRENT window. Only valid
                        // while the playhead is NOT moving, which is exactly the
                        // export-handle drag (it never scrubs).
                        fun timeAt(x: Float): Long {
                            val w = size.width.toFloat()
                            if (w <= 0f) return playhead.value
                            val frac = (x / w).coerceIn(0f, 1f)
                            return playhead.value - span.value / 2 +
                                (frac * span.value).roundToLong()
                        }

                        // Which export edge (if any) the finger landed on. Nearest
                        // wins when the two handles overlap; mirrors iOS
                        // `exportEdge(near:)`.
                        val edgeSetter: ((Long) -> Unit)? = run {
                            val s = selStart.value
                            val e = selEnd.value
                            val setS = setSelStart.value
                            val setE = setSelEnd.value
                            val w = size.width.toFloat()
                            if (s == null || e == null || setS == null || setE == null ||
                                w <= 0f || span.value <= 0L
                            ) {
                                return@run null
                            }
                            val visStart = playhead.value - span.value / 2
                            fun xOf(ts: Long): Float =
                                ((ts - visStart).toFloat() / span.value.toFloat()) * w
                            val dS = abs(xOf(s) - down.position.x)
                            val dE = abs(xOf(e) - down.position.x)
                            if (minOf(dS, dE) > grabPx) null else if (dS <= dE) setS else setE
                        }

                        if (edgeSetter != null) {
                            // Handle drag: resize the bracket instead of scrubbing.
                            // The playhead stays exactly where it is, so nothing but
                            // the marked edge moves.
                            val nowMs = System.currentTimeMillis()
                            edgeSetter(timeAt(down.position.x).coerceIn(0L, nowMs))
                            down.consume()
                            while (true) {
                                val event = awaitPointerEvent()
                                event.changes.firstOrNull { it.pressed }?.let { change ->
                                    edgeSetter(timeAt(change.position.x).coerceIn(0L, nowMs))
                                }
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                                if (event.changes.none { it.pressed }) break
                            }
                            return@awaitEachGesture
                        }

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
                                    .coerceIn(minSpanMs, maxSpanMs)
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

            // Top inset: the time chip row (18 dp) and the detection marker band (16 dp).
            // Stacked when the timeline is tall enough, sharing one row when it is short.
            val chipH = if (timeChip) 18.dp.toPx() else 0f
            val markerH = if (reserveMarkerBand) 16.dp.toPx() else 0f
            val stacked = h >= 80.dp.toPx()
            val topInset = if (stacked) chipH + markerH else maxOf(chipH, markerH)
            val markerTop = if (stacked) chipH else 0f
            val labelsH = 12.dp.toPx()
            val bandH = if (topInset > 0f) (h - topInset - labelsH).coerceAtLeast(8.dp.toPx()) else h * 0.42f
            val bandTop = if (topInset > 0f) topInset else (h - bandH) / 2f

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
                    // W5: 1.5 dp rounded bar tops.
                    drawRoundRect(
                        color = markColor,
                        topLeft = Offset(x1, bandTop + bandH - baseH - mh),
                        size = Size(bw, mh),
                        cornerRadius = CornerRadius(1.5.dp.toPx(), 1.5.dp.toPx()),
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
                val iconSize = if (reserveMarkerBand) {
                    16.dp.toPx()                              // P6: fixed 16 dp glyphs in their own band
                } else when {
                    spanMs <= 5 * 60_000L -> 16.dp.toPx()    // ≤5 min zoom
                    spanMs <= 60 * 60_000L -> 13.dp.toPx()   // ≤1 h zoom
                    else -> 11.dp.toPx()                      // >1 h (48 h max)
                }
                val iconTop = if (reserveMarkerBand) markerTop + (markerH - iconSize) / 2f else bandTop + 1f
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
                        style = androidx.compose.ui.graphics.drawscope.Stroke(width = if (reserveMarkerBand) 1.5.dp.toPx() else 1.6f),
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

            // 2e. Export in/out bracket — a translucent amber wash over the marked
            // region with a solid amber handle at each edge (the same "mark for
            // export" region the desktop and iOS clients draw). Edges are ordered
            // here, not in state, so dragging one past the other is harmless.
            val selA = exportSelStartMs
            val selB = exportSelEndMs
            if (selA != null && selB != null) {
                val a = minOf(selA, selB)
                val b = maxOf(selA, selB)
                if (b >= visStart && a <= visEnd) {
                    val xa = xOf(a).coerceIn(0f, w)
                    val xb = xOf(b).coerceIn(0f, w)
                    drawRect(
                        color = TimelineColors.exportFill,
                        topLeft = Offset(xa, bandTop),
                        size = Size((xb - xa).coerceAtLeast(1f), bandH),
                    )
                    for (hx in listOf(xOf(a), xOf(b))) {
                        if (hx < 0f || hx > w) continue
                        drawRect(
                            color = TimelineColors.exportHandle,
                            topLeft = Offset(hx - 1.5f, bandTop - 6f),
                            size = Size(3f, bandH + 12f),
                        )
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
            // P5: date + time as a 12 sp mono chip centred above the playhead. (The
            // playhead is fixed at the centre, so the chip stays put while time scrolls
            // under it.) Drawn last so it sits over any glyph at the centre.
            if (timeChip) {
                val label = Time.dateTimeCompact(Instant.ofEpochMilli(playheadMs))
                val measured = textMeasurer.measure(label, chipStyle, overflow = TextOverflow.Clip)
                val padX = 8.dp.toPx()
                val chipW = measured.size.width + padX * 2
                val chipTop = 0f
                val chipHeight = chipH - 2.dp.toPx()
                val chipLeft = (cx - chipW / 2f).coerceIn(0f, (w - chipW).coerceAtLeast(0f))
                drawRoundRect(
                    color = TimelineColors.track,
                    topLeft = Offset(chipLeft, chipTop),
                    size = Size(chipW, chipHeight),
                    cornerRadius = CornerRadius(6.dp.toPx(), 6.dp.toPx()),
                )
                drawText(
                    measured,
                    topLeft = Offset(chipLeft + padX, chipTop + (chipHeight - measured.size.height) / 2f),
                )
            }
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
