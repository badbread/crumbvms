// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure side of the scrub sprite strips: header parsing, 1 s tile lookup,
 * the tile crop rectangle, LRU, TTL'd negative results, and which segments to
 * warm ahead of the finger.
 */
class ScrubSpritesTest {

    private fun headers(
        start: Long = 40_000,
        end: Long = 44_000,
        tiles: Int = 4,
        interval: Long = 1_000,
    ) = mapOf(
        // Mixed case on purpose: header names are case-insensitive.
        "X-Crumb-Sprite-Start-Ms" to "$start",
        "x-crumb-sprite-end-ms" to "$end",
        "x-crumb-sprite-interval-ms" to "$interval",
        "x-crumb-sprite-tiles" to "$tiles",
        "x-crumb-sprite-columns" to "$tiles",
        "x-crumb-sprite-tile-width" to "160",
    )

    private fun sprite(start: Long = 40_000, end: Long = 44_000) =
        ScrubSprite(SpriteLayout.fromHeaders(headers(start, end))!!, "img@$start")

    @Test
    fun parsesLayoutHeaders() {
        val l = SpriteLayout.fromHeaders(headers())!!
        assertEquals(SpriteLayout(40_000, 44_000, 1_000, 4, 4), l)
        assertEquals(1, l.rows)
    }

    @Test
    fun rejectsMissingOrNonsensicalLayouts() {
        assertNull(SpriteLayout.fromHeaders(headers() - "x-crumb-sprite-tiles"))
        assertNull(SpriteLayout.fromHeaders(headers(start = 5, end = 5)))
        assertNull(SpriteLayout.fromHeaders(headers(interval = 0)))
        assertNull(SpriteLayout.fromHeaders(headers(tiles = 0)))
        assertNull(SpriteLayout.fromHeaders(emptyMap()))
    }

    @Test
    fun oneTilePerSecondClampedIntoTheStrip() {
        val l = SpriteLayout.fromHeaders(headers())!!
        assertEquals(0, l.tileFor(40_000))
        assertEquals(0, l.tileFor(40_999))
        assertEquals(1, l.tileFor(41_000))
        assertEquals(3, l.tileFor(43_999))
        assertEquals(0, l.tileFor(1))
        assertEquals(3, l.tileFor(99_000))
        assertFalse("end is exclusive", l.covers(44_000))
    }

    @Test
    fun tileRectWalksTheStrip() {
        val l = SpriteLayout.fromHeaders(headers())!!
        assertArrayEquals(intArrayOf(0, 0, 160, 90), l.tileRect(0, 640, 90))
        assertArrayEquals(intArrayOf(480, 0, 160, 90), l.tileRect(3, 640, 90))
    }

    @Test
    fun lookupFindsTheCoveringSpriteAndTile() {
        val c = ScrubSpriteCache<String>()
        val s = sprite()
        c.put(41_500, s)
        val hit = c.lookup(42_100)!!
        assertSame(s, hit.sprite)
        assertEquals(2, hit.index)
        assertNull(c.lookup(44_000))
    }

    @Test
    fun evictsLeastRecentlyUsedPastCapacity() {
        val c = ScrubSpriteCache<String>(capacity = 2)
        c.put(0, sprite(0, 4_000))
        c.put(4_000, sprite(4_000, 8_000))
        assertNotNull(c.lookup(1_000)) // touch the first
        c.put(8_000, sprite(8_000, 12_000))
        assertEquals(2, c.size)
        assertNull(c.lookup(5_000))
        assertNotNull(c.lookup(1_000))
        assertNotNull(c.lookup(9_000))
    }

    @Test
    fun missIsRememberedPerCellOnlyForItsTtl() {
        var now = 1_000_000L
        val c = ScrubSpriteCache<String>(now = { now })
        c.put(41_000, null)
        assertTrue(c.isKnownMiss(40_000))
        assertTrue(c.isKnownMiss(43_999))
        assertFalse(c.isKnownMiss(44_000))
        now += SPRITE_MISS_TTL_MS + 1
        assertFalse(c.isKnownMiss(42_000))
    }

    @Test
    fun probesAheadFollowTheFinger() {
        val c = ScrubSpriteCache<String>()
        val s = sprite()
        c.put(40_000, s)
        assertEquals(listOf(44_000L, 48_000L), c.probesAhead(s.layout, forward = true))
        assertEquals(listOf(39_999L, 35_999L), c.probesAhead(s.layout, forward = false))
        c.put(44_000, sprite(44_000, 48_000))
        c.put(48_000, null)
        assertEquals(emptyList<Long>(), c.probesAhead(s.layout, forward = true))
    }
}
