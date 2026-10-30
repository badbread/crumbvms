// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import video.crumb.app.data.ResolvedSegment
import java.time.Instant

/**
 * The pure decision behind the in-segment live drag: a scrub position inside
 * the loaded segment is served by a local seek (offset into the segment);
 * anything else (outside it, nothing loaded, a resolve already in flight)
 * falls back to the filmstrip overlay plus a resolve on release.
 */
class LiveScrubOffsetTest {

    private val startMs = Instant.parse("2026-01-01T00:00:00Z").toEpochMilli()

    private fun seg(
        start: String = "2026-01-01T00:00:00Z",
        end: String = "2026-01-01T00:00:04Z",
        durationMs: Int = 4_000,
    ) = ResolvedSegment(
        cameraId = "cam",
        segmentId = "s1",
        url = "/segments/s1",
        start = start,
        end = end,
        durationMs = durationMs,
        hasMotion = false,
    )

    private fun offset(
        segment: ResolvedSegment?,
        tsMs: Long,
        userSeek: Boolean = false,
        jump: Boolean = false,
    ) = liveScrubOffsetMs(segment, tsMs, userSeekInProgress = userSeek, jumpInProgress = jump)

    @Test
    fun insideTheLoadedSegmentIsALocalSeek() {
        assertEquals(0L, offset(seg(), startMs))
        assertEquals(1_500L, offset(seg(), startMs + 1_500))
        assertEquals(3_999L, offset(seg(), startMs + 3_999))
    }

    @Test
    fun outsideTheSegmentFallsBack() {
        assertNull(offset(seg(), startMs - 1))
        // end is exclusive: that instant belongs to the next segment
        assertNull(offset(seg(), startMs + 4_000))
        assertNull(offset(seg(), startMs + 60_000))
    }

    @Test
    fun nothingLoadedFallsBack() {
        assertNull(offset(null, startMs))
    }

    @Test
    fun aResolveInFlightFallsBack() {
        // The loaded segment is stale while a user seek or motion jump resolves.
        assertNull(offset(seg(), startMs + 1_000, userSeek = true))
        assertNull(offset(seg(), startMs + 1_000, jump = true))
    }

    @Test
    fun unparseableEndUsesTheDuration() {
        val s = seg(end = "garbage", durationMs = 2_000)
        assertEquals(1_999L, offset(s, startMs + 1_999))
        assertNull(offset(s, startMs + 2_000))
    }

    @Test
    fun unusableBoundsFallBack() {
        assertNull(offset(seg(start = "garbage"), startMs))
        assertNull(offset(seg(end = "garbage", durationMs = 0), startMs))
    }

    @Test
    fun offsetTimestampsParse() {
        val s = seg(start = "2026-01-01T01:00:00+01:00", end = "2026-01-01T01:00:04+01:00")
        assertEquals(2_000L, offset(s, startMs + 2_000))
    }
}
