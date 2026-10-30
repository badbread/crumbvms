// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the shared export-range arithmetic: the in/out bracket on the
 * playback timeline and the Export screen's clip window both run through
 * [ExportRange], so a regression here would desync the two.
 */
class ExportRangeTest {

    private val now = 1_700_000_000_000L

    // ── normalize ────────────────────────────────────────────────────────────

    @Test
    fun `normalize orders an inverted pair`() {
        assertEquals(100L to 500L, ExportRange.normalize(500L, 100L))
    }

    @Test
    fun `normalize leaves an ordered pair alone`() {
        assertEquals(100L to 500L, ExportRange.normalize(100L, 500L))
    }

    @Test
    fun `normalize is stable for equal edges`() {
        assertEquals(100L to 100L, ExportRange.normalize(100L, 100L))
    }

    // ── setEdge ──────────────────────────────────────────────────────────────

    @Test
    fun `setting the in point seeds the out point from the playhead`() {
        val playhead = now - 10_000L
        val (start, end) = ExportRange.setEdge(
            currentStart = null,
            currentEnd = null,
            isStart = true,
            ms = now - 60_000L,
            playheadMs = playhead,
            nowMs = now,
        )
        assertEquals(now - 60_000L, start)
        assertEquals(playhead, end)
    }

    @Test
    fun `setting the out point seeds the in point from the playhead`() {
        val playhead = now - 60_000L
        val (start, end) = ExportRange.setEdge(
            currentStart = null,
            currentEnd = null,
            isStart = false,
            ms = now - 10_000L,
            playheadMs = playhead,
            nowMs = now,
        )
        assertEquals(playhead, start)
        assertEquals(now - 10_000L, end)
    }

    @Test
    fun `setting one edge leaves the other edge untouched`() {
        val (start, end) = ExportRange.setEdge(
            currentStart = 1_000L,
            currentEnd = 9_000L,
            isStart = true,
            ms = 3_000L,
            playheadMs = 5_000L,
            nowMs = now,
        )
        assertEquals(3_000L, start)
        assertEquals(9_000L, end)
    }

    @Test
    fun `a mark in the future is clamped to now`() {
        val (_, end) = ExportRange.setEdge(
            currentStart = now - 60_000L,
            currentEnd = now - 10_000L,
            isStart = false,
            ms = now + 90_000L,
            playheadMs = now - 10_000L,
            nowMs = now,
        )
        assertEquals(now, end)
    }

    @Test
    fun `dragging an edge past the other does not swap the raw edges`() {
        // The raw edges stay as placed; ordering happens only on read, so the
        // finger keeps holding the handle it grabbed.
        val (start, end) = ExportRange.setEdge(
            currentStart = 1_000L,
            currentEnd = 5_000L,
            isStart = true,
            ms = 9_000L,
            playheadMs = 5_000L,
            nowMs = now,
        )
        assertEquals(9_000L, start)
        assertEquals(5_000L, end)
        assertEquals(5_000L to 9_000L, ExportRange.normalize(start, end))
    }

    // ── forExport ────────────────────────────────────────────────────────────

    @Test
    fun `forExport uses the bracketed selection when one exists`() {
        val range = ExportRange.forExport(
            selStartMs = now - 30_000L,
            selEndMs = now - 5_000L,
            playheadMs = now,
        )
        assertEquals((now - 30_000L) to (now - 5_000L), range)
    }

    @Test
    fun `forExport orders an inverted selection`() {
        val range = ExportRange.forExport(
            selStartMs = now - 5_000L,
            selEndMs = now - 30_000L,
            playheadMs = now,
        )
        assertEquals((now - 30_000L) to (now - 5_000L), range)
    }

    @Test
    fun `forExport falls back to the hour ending at the playhead`() {
        val range = ExportRange.forExport(selStartMs = null, selEndMs = null, playheadMs = now)
        assertEquals((now - 3_600_000L) to now, range)
    }

    @Test
    fun `forExport ignores a degenerate selection`() {
        // A single tap that placed both edges on the same instant is not a range.
        val range = ExportRange.forExport(selStartMs = now, selEndMs = now, playheadMs = now)
        assertEquals((now - 3_600_000L) to now, range)
    }

    // ── quick ranges ─────────────────────────────────────────────────────────

    @Test
    fun `quick ranges end now and run back the requested minutes`() {
        for (minutes in ExportRange.QUICK_RANGE_MINUTES) {
            val (start, end) = ExportRange.quickRange(now, minutes)
            assertEquals(now, end)
            assertEquals(minutes * 60_000L, end - start)
            assertTrue(ExportRange.isValid(start, end))
        }
    }

    @Test
    fun `the quick range chips match the desktop builder`() {
        assertEquals(listOf(1, 5, 10, 15), ExportRange.QUICK_RANGE_MINUTES)
    }

    // ── validation + clamping ────────────────────────────────────────────────

    @Test
    fun `a range shorter than one second is rejected`() {
        assertFalse(ExportRange.isValid(now, now))
        assertFalse(ExportRange.isValid(now, now + 999L))
        assertTrue(ExportRange.isValid(now, now + 1_000L))
    }

    @Test
    fun `an inverted range is rejected`() {
        assertFalse(ExportRange.isValid(now, now - 60_000L))
    }

    @Test
    fun `clampStart keeps the start strictly before the end`() {
        assertEquals(now - 1_000L, ExportRange.clampStart(now + 5_000L, now))
        // A start already well before the end is untouched.
        assertEquals(now - 60_000L, ExportRange.clampStart(now - 60_000L, now))
    }

    @Test
    fun `clampEnd keeps the end strictly after the start`() {
        assertEquals(now + 1_000L, ExportRange.clampEnd(now - 5_000L, now))
        assertEquals(now + 60_000L, ExportRange.clampEnd(now + 60_000L, now))
    }

    // ── duration formatting ──────────────────────────────────────────────────

    @Test
    fun `durations are precise to the second`() {
        assertEquals("0s", ExportRange.formatDuration(0))
        assertEquals("45s", ExportRange.formatDuration(45))
        assertEquals("2m 3s", ExportRange.formatDuration(123))
        assertEquals("1h 2m 3s", ExportRange.formatDuration(3_723))
    }

    @Test
    fun `a negative duration renders as zero rather than a minus sign`() {
        assertEquals("0s", ExportRange.formatDuration(-5))
    }

    @Test
    fun `durationLabel truncates milliseconds down to the second`() {
        assertEquals("1m 1s", ExportRange.durationLabel(now, now + 61_999L))
    }
}
