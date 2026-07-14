// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import android.graphics.Bitmap
import android.graphics.Rect
import coil.size.Size
import coil.transform.Transformation
import kotlin.math.roundToInt

/**
 * Shared license-plate bounding-box geometry + a Coil crop transformation.
 *
 * A [PlateRead.bbox] is the plate's location within its sibling detection-event
 * snapshot, as normalized `[x, y, w, h]` fractions (0..1) of the image's
 * width/height. Both the on-screen Plates thumbnails ([PlateCropTransformation],
 * applied via Coil) and the single-plate PDF report (`PlatesPdf.kt`'s
 * `cropToBbox`) resolve that box to pixels through [bboxToRect] so the math lives
 * in exactly one place.
 */

/**
 * Resolve a normalized `[x, y, w, h]` (0..1) [bbox] to a pixel [Rect] within a
 * [width]×[height] image. Coordinates are clamped into the image so a slightly
 * out-of-range box never throws; returns null when [bbox] is absent/malformed or
 * the dimensions are non-positive (the caller then falls back to the full image).
 */
fun bboxToRect(bbox: List<Double>?, width: Int, height: Int): Rect? {
    if (bbox == null || bbox.size < 4 || width <= 0 || height <= 0) return null
    val left = (bbox[0] * width).roundToInt().coerceIn(0, width - 1)
    val top = (bbox[1] * height).roundToInt().coerceIn(0, height - 1)
    val cw = (bbox[2] * width).roundToInt().coerceIn(1, width - left)
    val ch = (bbox[3] * height).roundToInt().coerceIn(1, height - top)
    return Rect(left, top, left + cw, top + ch)
}

/**
 * Coil [Transformation] that crops a loaded snapshot to a plate [bbox]
 * (normalized `[x, y, w, h]`), so the plate fills the thumbnail without a second
 * network round-trip — the snapshot the card already loads is reused.
 *
 * Memory-safe by construction: Coil applies the request's target size *before*
 * transformations, so [transform] runs on the already-downsampled decode (peak
 * memory is that bounded bitmap) and the returned crop is smaller still. When the
 * box can't be resolved it returns the input unchanged, matching the report's
 * "fall back to the full snapshot" behavior.
 */
class PlateCropTransformation(private val bbox: List<Double>) : Transformation {
    override val cacheKey: String = "plate-crop:${bbox.joinToString(",")}"

    override suspend fun transform(input: Bitmap, size: Size): Bitmap {
        val rect = bboxToRect(bbox, input.width, input.height) ?: return input
        // Whole-image box → skip the copy (and Coil's input recycling of it).
        if (rect.left == 0 && rect.top == 0 &&
            rect.width() == input.width && rect.height() == input.height
        ) {
            return input
        }
        return Bitmap.createBitmap(input, rect.left, rect.top, rect.width(), rect.height())
    }
}
