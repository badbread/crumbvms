// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.player

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import kotlin.math.abs

private const val MIN_SCALE = 1.0f
private const val MAX_SCALE = 5.0f

/** A horizontal swipe (at 1x) must travel at least this fraction of the view
 *  width to count as a camera switch, with a floor so tiny views still need a
 *  deliberate swipe. */
private const val SWIPE_WIDTH_FRACTION = 0.15f
private const val SWIPE_MIN_PX = 120f

/**
 * Snapshot of the digital-zoom transform, surfaced to a parent via
 * [ZoomableVideoSurface]'s `onTransformChange`. The visible viewport (in view-space
 * pixels) is `[offsetX, offsetX + viewW/scale] × [offsetY, offsetY + viewH/scale]`.
 * At [scale] == 1 the whole frame is visible (offset is 0).
 */
data class ViewTransform(
    val scale: Float,
    val offsetX: Float,
    val offsetY: Float,
)

/**
 * Hoistable zoom/pan state for [ZoomableVideoSurface]. By default the surface
 * owns an internal one (so it resets whenever the surface leaves the
 * composition, e.g. Live camera switches). A caller that wants the zoom to
 * SURVIVE the surface unmounting/remounting, e.g. playback scrubbing across a
 * quiet gap on a motion camera, where `currentSegment` briefly nulls and flips
 * the video off-screen, hoists this above that boundary and passes it in, then
 * [reset]s it on an actual camera change. (#386)
 */
@Stable
class ZoomableSurfaceState {
    var zoom by mutableFloatStateOf(1f)
    var offset by mutableStateOf(Offset.Zero)

    /** Return to fully zoomed out (1x, no pan). */
    fun reset() {
        zoom = 1f
        offset = Offset.Zero
    }
}

/** Remember a [ZoomableSurfaceState] across recomposition. */
@Composable
fun rememberZoomableSurfaceState(): ZoomableSurfaceState = remember { ZoomableSurfaceState() }

/**
 * Wraps a video composable (a [PlayerSurface] using TextureView) and adds
 * client-side digital zoom + pan, plus an optional horizontal swipe-to-switch:
 *   - two-finger pinch to zoom (1x–5x), pivoting around the fingers
 *   - one-finger drag to pan while zoomed, clamped so the video never reveals
 *     blank edges
 *   - double-tap to reset to 1x
 *   - **one-finger horizontal swipe while fully zoomed out (1x)** → [onSwipeCamera]
 *     (-1 = previous, +1 = next). Suppressed once zoomed in (the drag pans) and
 *     while [suppressPan] is set (the PTZ wheel owns single-touch).
 *
 * All pointer handling is unified into a single [awaitEachGesture] loop so the
 * pinch/pan math and the swipe decision share one event stream and consumption
 * model (two competing `pointerInput`s would fight over the same single-finger
 * drag). The zoom/pan math is the canonical multitouch formula: gestures are
 * measured in un-scaled coordinates, the layer uses a top-left [TransformOrigin],
 * and `offset` is tracked in CONTENT space with `translation = -offset * zoom`.
 *
 * REQUIREMENT: the inner [PlayerSurface] must pass `textureView = true`. A
 * SurfaceView ignores [graphicsLayer] transforms (separate hardware layer).
 *
 * @param suppressPan when true (e.g. the PTZ wheel is up), one-finger pan AND the
 *   swipe are suppressed so single-touch goes to the overlay; pinch still works.
 * @param onSwipeCamera invoked on a qualifying horizontal swipe at 1x; the arg is
 *   -1 (swipe right → previous) or +1 (swipe left → next). Null disables it.
 * @param onTransformChange invoked whenever the zoom/pan transform changes (and once
 *   on reset), reporting the current [ViewTransform]. Lets a parent (e.g. the
 *   playback snapshot) crop the captured frame to the on-screen viewport. The
 *   transform model: visible content (view-space px) spans
 *   `[offset.x, offset.x + viewW/scale] × [offset.y, offset.y + viewH/scale]`.
 */
@Composable
fun ZoomableVideoSurface(
    modifier: Modifier = Modifier,
    suppressPan: Boolean = false,
    onSwipeCamera: ((Int) -> Unit)? = null,
    onTransformChange: ((ViewTransform) -> Unit)? = null,
    state: ZoomableSurfaceState = rememberZoomableSurfaceState(),
    content: @Composable () -> Unit,
) {
    // Local working copies seeded from the hoisted [state]. On (re)mount the seed
    // re-reads `state`, so a preserved zoom survives the surface briefly leaving
    // the composition (e.g. playback scrubbing across a motion-camera gap).
    // report() writes changes back so `state` stays authoritative. (#386)
    var zoom by remember { mutableFloatStateOf(state.zoom) }
    var offset by remember { mutableStateOf(state.offset) }   // content-space pan
    var size by remember { mutableStateOf(IntSize.Zero) }

    // Report transform changes (zoom/pan/reset) to the parent for snapshot cropping.
    val transformCb = rememberUpdatedState(onTransformChange)
    fun report() {
        // Keep the hoisted state authoritative so a preserved zoom survives the
        // surface remounting on a segment transition. (#386)
        state.zoom = zoom
        state.offset = offset
        transformCb.value?.invoke(
            ViewTransform(scale = zoom, offsetX = offset.x, offsetY = offset.y),
        )
    }

    Box(
        modifier = modifier
            .onSizeChanged { size = it }
            .pointerInput(suppressPan, onSwipeCamera) {
                awaitEachGesture {
                    // Per-gesture accumulators for the swipe decision.
                    var totalPan = Offset.Zero
                    var maxPointers = 0

                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.count { it.pressed }
                        if (pressed > maxPointers) maxPointers = pressed

                        val zoomChange = event.calculateZoom()
                        val panChange = event.calculatePan()
                        if (zoomChange != 1f || panChange != Offset.Zero) {
                            totalPan += panChange
                            val centroid = event.calculateCentroid(useCurrent = true)
                            val oldScale = zoom
                            val newScale = (zoom * zoomChange).coerceIn(MIN_SCALE, MAX_SCALE)
                            // At 1x a one-finger pan is clamped to a no-op below, so
                            // applying it is harmless; we still accumulate totalPan
                            // for the swipe check on gesture end.
                            //
                            // suppressPan (PTZ controls up) only suppresses pan at 1x —
                            // there, single-touch must reach the PTZ overlay / drive the
                            // camera-swipe. Once ZOOMED IN, a one-finger drag can only
                            // mean "pan the magnified image" (you're navigating a digital
                            // zoom), so allow it even with PTZ controls showing. Pinch
                            // (zoom) is never suppressed.
                            val panSuppressed = suppressPan && oldScale <= 1.001f
                            val panContribution = if (panSuppressed) Offset.Zero else panChange
                            var newOffset = (offset + centroid / oldScale) -
                                (centroid / newScale + panContribution / oldScale)
                            zoom = newScale
                            // Clamp so the zoomed content never exposes blank edges:
                            // visible content spans [offset, offset + size/zoom].
                            val maxX = (size.width * (1f - 1f / newScale)).coerceAtLeast(0f)
                            val maxY = (size.height * (1f - 1f / newScale)).coerceAtLeast(0f)
                            newOffset = Offset(
                                newOffset.x.coerceIn(0f, maxX),
                                newOffset.y.coerceIn(0f, maxY),
                            )
                            offset = newOffset
                            report()   // surface the new transform for snapshot cropping
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                        }
                    } while (event.changes.any { it.pressed })

                    // Gesture ended. A single-finger, dominantly-horizontal drag while
                    // fully zoomed out (and not in PTZ mode) switches cameras. Pinches
                    // (>=2 pointers) and zoomed-in pans are excluded by the guards.
                    val cb = onSwipeCamera
                    if (cb != null && maxPointers < 2 && !suppressPan &&
                        zoom <= 1.001f && size.width > 0
                    ) {
                        val threshold = (size.width * SWIPE_WIDTH_FRACTION).coerceAtLeast(SWIPE_MIN_PX)
                        if (abs(totalPan.x) > threshold && abs(totalPan.x) > abs(totalPan.y) * 1.3f) {
                            cb(if (totalPan.x < 0f) 1 else -1)
                        }
                    }
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = {
                    zoom = 1f
                    offset = Offset.Zero
                    report()
                })
            }
            .graphicsLayer {
                scaleX = zoom
                scaleY = zoom
                translationX = -offset.x * zoom
                translationY = -offset.y * zoom
                transformOrigin = TransformOrigin(0f, 0f)
                clip = true // keep the zoomed video inside its window, not over the UI
            },
    ) {
        content()
    }
}
