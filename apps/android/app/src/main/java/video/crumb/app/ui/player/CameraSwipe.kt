package video.crumb.app.ui.player

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import kotlin.math.abs

/**
 * Decides whether a finished one-finger drag is a camera-switch swipe. Returns +1
 * (next camera, swiped left), -1 (previous, swiped right) or null if the drag is
 * too short or not dominantly horizontal. Shared by [ZoomableVideoSurface] and
 * [cameraSwipe] so the video and placeholder states feel identical.
 */
internal fun cameraSwipeDirection(totalPanX: Float, totalPanY: Float, widthPx: Int): Int? {
    if (widthPx <= 0) return null
    val threshold = (widthPx * SWIPE_WIDTH_FRACTION).coerceAtLeast(SWIPE_MIN_PX)
    if (abs(totalPanX) > threshold && abs(totalPanX) > abs(totalPanY) * 1.3f) {
        return if (totalPanX < 0f) 1 else -1
    }
    return null
}

/**
 * Horizontal swipe-to-switch-camera for states that have no [ZoomableVideoSurface]
 * (loading, error, "No footage"), so you can always swipe away from them (#622).
 * Gestures whose moves were consumed by a child (a button, or the video surface
 * panning/zooming) are ignored, so this is safe to apply around the video too.
 */
internal fun Modifier.cameraSwipe(onSwipeCamera: ((Int) -> Unit)?): Modifier {
    if (onSwipeCamera == null) return this
    return pointerInput(onSwipeCamera) {
        awaitEachGesture {
            var total = Offset.Zero
            var maxPointers = 0
            var consumed = false
            awaitFirstDown(requireUnconsumed = false)
            do {
                val event = awaitPointerEvent()
                maxPointers = maxOf(maxPointers, event.changes.count { it.pressed })
                if (event.changes.any { it.isConsumed }) consumed = true
                total += event.calculatePan()
            } while (event.changes.any { it.pressed })
            if (!consumed && maxPointers < 2) {
                cameraSwipeDirection(total.x, total.y, size.width)?.let(onSwipeCamera)
            }
        }
    }
}
