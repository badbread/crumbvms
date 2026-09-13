// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.export

/**
 * Pure time-range helpers shared by the playback in/out bracket and the Export
 * screen. Kept free of Compose and Android types so the arithmetic is unit
 * testable, and so the playback screen and the export screen can never drift on
 * what a "selection" means.
 *
 * The model mirrors the desktop client's `playback_timeline_controller`
 * (`selStartMs`/`selEndMs` as epoch millis, no snapping) and the iOS
 * `setExportEdge` / `exportRange` pair: the two edges are stored exactly as the
 * operator placed them and are only ordered when read, so dragging one handle
 * past the other never swaps which handle the finger is holding.
 */
object ExportRange {

    /** Smallest range the server will accept (`start` must be strictly before `end`). */
    const val MIN_DURATION_MS = 1_000L

    /** Nudge step for the Export screen's fine stepper: ONE second. */
    const val NUDGE_STEP_MS = 1_000L

    /** Quick-range chip lengths, in minutes, mirroring the desktop export builder. */
    val QUICK_RANGE_MINUTES = listOf(1, 5, 10, 15)

    /** Fallback export window when nothing is bracketed: the hour ending at the playhead. */
    const val FALLBACK_WINDOW_MS = 3_600_000L

    /** Order two raw edges into `(start, end)`. */
    fun normalize(a: Long, b: Long): Pair<Long, Long> =
        if (a <= b) a to b else b to a

    /**
     * Place one edge of the bracket, seeding the missing edge from the playhead so
     * a range is always visible as soon as the first edge is marked (iOS
     * `setExportEdge`). [nowMs] clamps a mark into the past, since there is no
     * footage in the future.
     *
     * @param currentStart Existing raw start edge, or null when unset.
     * @param currentEnd Existing raw end edge, or null when unset.
     * @param isStart True to place the IN point, false for the OUT point.
     */
    fun setEdge(
        currentStart: Long?,
        currentEnd: Long?,
        isStart: Boolean,
        ms: Long,
        playheadMs: Long,
        nowMs: Long,
    ): Pair<Long, Long> {
        val t = minOf(ms, nowMs)
        return if (isStart) {
            t to (currentEnd ?: maxOf(t, playheadMs))
        } else {
            (currentStart ?: minOf(t, playheadMs)) to t
        }
    }

    /**
     * The range an export entry point should carry: the bracketed selection when
     * both edges are set, otherwise the hour ending at the playhead (the prior
     * Android default, and what iOS `exportRange()` falls back to).
     */
    fun forExport(selStartMs: Long?, selEndMs: Long?, playheadMs: Long): Pair<Long, Long> {
        if (selStartMs != null && selEndMs != null) {
            val (a, b) = normalize(selStartMs, selEndMs)
            if (b - a >= MIN_DURATION_MS) return a to b
        }
        return (playheadMs - FALLBACK_WINDOW_MS) to playheadMs
    }

    /** A "Last N minutes" quick range ending at [nowMs]. */
    fun quickRange(nowMs: Long, minutes: Int): Pair<Long, Long> =
        (nowMs - minutes * 60_000L) to nowMs

    /** True when the server would accept this range (`start` strictly before `end`). */
    fun isValid(startMs: Long, endMs: Long): Boolean = endMs - startMs >= MIN_DURATION_MS

    /** Clamp a proposed start so it stays at least [MIN_DURATION_MS] before [endMs]. */
    fun clampStart(proposedMs: Long, endMs: Long): Long =
        minOf(proposedMs, endMs - MIN_DURATION_MS)

    /** Clamp a proposed end so it stays at least [MIN_DURATION_MS] after [startMs]. */
    fun clampEnd(proposedMs: Long, startMs: Long): Long =
        maxOf(proposedMs, startMs + MIN_DURATION_MS)

    /** "1h 2m 3s" / "2m 3s" / "3s" — always precise to the second. */
    fun formatDuration(totalSec: Long): String {
        val safe = if (totalSec < 0) 0L else totalSec
        val h = safe / 3600
        val m = (safe % 3600) / 60
        val s = safe % 60
        return when {
            h > 0 -> "${h}h ${m}m ${s}s"
            m > 0 -> "${m}m ${s}s"
            else -> "${s}s"
        }
    }

    /** Duration label for a millisecond range, rounded down to the second. */
    fun durationLabel(startMs: Long, endMs: Long): String =
        formatDuration((endMs - startMs) / 1_000L)
}
