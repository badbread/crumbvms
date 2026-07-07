// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

/**
 * Cyclical camera navigation in wall order — extracted from the byte-identical
 * wrap-around math that was duplicated in PlaybackScreen + LiveFullscreenScreen
 * (review G2). `dir` = +1 next / -1 prev.
 *
 * Returns the neighbouring camera id (wrapping past either end), `null` when the
 * list is empty, and the first id when `current` isn't in the list.
 */
object CameraNav {
    fun next(ids: List<String>, current: String, dir: Int): String? {
        if (ids.isEmpty()) return null
        val idx = ids.indexOf(current)
        if (idx < 0) return ids.first()
        val nextIdx = (((idx + dir) % ids.size) + ids.size) % ids.size
        return ids[nextIdx]
    }
}
