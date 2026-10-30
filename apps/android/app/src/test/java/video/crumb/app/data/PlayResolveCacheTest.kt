// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** [PlayResolveCache], behind [CrumbRepository.resolveSegment]. */
class PlayResolveCacheTest {

    private val t0 = Instant.parse("2026-01-01T12:00:00Z").toEpochMilli()

    private fun seg(cam: String, id: String, startS: Long, lenS: Long = 4) = ResolvedSegment(
        cameraId = cam,
        segmentId = id,
        url = "/segments/$id",
        start = Instant.ofEpochMilli(t0 + startS * 1000).toString(),
        end = Instant.ofEpochMilli(t0 + (startS + lenS) * 1000).toString(),
        durationMs = (lenS * 1000).toInt(),
        hasMotion = false,
    )

    private fun at(ms: Long) = t0 + ms

    @Test
    fun `any instant inside a cached segment hits and the end is exclusive`() {
        val c = PlayResolveCache()
        val s = seg("cam", "a", 0)
        c.put("srv", "main", s, at(500))
        assertSame(s, c.lookup("srv", "cam", "main", at(0)))
        assertSame(s, c.lookup("srv", "cam", "main", at(3999)))
        assertNull(c.lookup("srv", "cam", "main", at(4000)))
        assertNull(c.lookup("srv", "cam", "main", at(-1)))
    }

    @Test
    fun `scope camera and stream are all part of the key`() {
        val c = PlayResolveCache()
        c.put("srv|tokA", "main", seg("cam", "a", 0), at(1000))
        assertNull(c.lookup("srv|tokB", "cam", "main", at(1000)))
        assertNull(c.lookup("srv|tokA", "other", "main", at(1000)))
        assertNull(c.lookup("srv|tokA", "cam", "sub", at(1000)))
        assertNotNull(c.lookup("srv|tokA", "cam", "main", at(1000)))
    }

    @Test
    fun `entries expire after the TTL even when read`() {
        var now = 1_000_000L
        val c = PlayResolveCache(nowMs = { now })
        c.put("srv", "main", seg("cam", "a", 0), at(10))
        now += PLAY_RESOLVE_TTL_MS - 1
        assertNotNull(c.lookup("srv", "cam", "main", at(10)))
        now += 1
        assertNull(c.lookup("srv", "cam", "main", at(10)))
        assertEquals(0, c.size)
    }

    @Test
    fun `TTL stays well inside the 15 min media token lifetime`() {
        assertTrue(PLAY_RESOLVE_TTL_MS <= 60_000L)
    }

    @Test
    fun `bounded - evicts the least recently used segment`() {
        val c = PlayResolveCache(capacity = 2)
        c.put("srv", "main", seg("cam", "a", 0), at(0))
        c.put("srv", "main", seg("cam", "b", 4), at(4000))
        assertNotNull(c.lookup("srv", "cam", "main", at(100))) // touch a
        c.put("srv", "main", seg("cam", "c", 8), at(8000))
        assertEquals(2, c.size)
        assertNull(c.lookup("srv", "cam", "main", at(4100)))
        assertEquals("a", c.lookup("srv", "cam", "main", at(100))?.segmentId)
        assertEquals("c", c.lookup("srv", "cam", "main", at(8100))?.segmentId)
    }

    @Test
    fun `a segment that does not cover the asked instant is not cached`() {
        val c = PlayResolveCache()
        c.put("srv", "main", seg("cam", "a", 0), at(5000))
        assertEquals(0, c.size)
        c.put("srv", "main", seg("cam", "bad", 0).copy(start = "garbage"), at(100))
        assertEquals(0, c.size)
    }

    @Test
    fun `invalidate drops one camera or everything`() {
        val c = PlayResolveCache()
        c.put("srv", "main", seg("cam", "a", 0), at(0))
        c.put("srv", "main", seg("other", "b", 0), at(0))
        c.invalidate("cam")
        assertNull(c.lookup("srv", "cam", "main", at(100)))
        assertNotNull(c.lookup("srv", "other", "main", at(100)))
        c.invalidate()
        assertEquals(0, c.size)
    }
}
