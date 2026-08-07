// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import org.junit.Assert.assertEquals
import org.junit.Test
import video.crumb.app.data.PlateRead

/**
 * Unit tests for the plate report's full sighting-log logic: pagination row-count
 * math ([paginateSightingRows]), the "showing N of M" honesty decision
 * ([sightingLogSummary]), camera-label resolution ([sightingCameraLabel]), and
 * newest-first ordering ([sightingsNewestFirst]). The PDF raster itself is a
 * visual call; these lock the pure logic that decides what it must contain.
 */
class PlateReportLogTest {

    private fun read(id: String, cameraId: String, ts: String) =
        PlateRead(id = id, cameraId = cameraId, ts = ts, plate = "7XYZ42")

    // ── pagination ────────────────────────────────────────────────────────────

    @Test
    fun `no rows paginates to no pages`() {
        assertEquals(emptyList<Int>(), paginateSightingRows(0, 30, 50))
    }

    @Test
    fun `every row fits on page one when capacity is ample`() {
        // 27 sightings (the maintainer's case) fit under a roomy page-1 tail.
        assertEquals(listOf(27), paginateSightingRows(27, 34, 54))
    }

    @Test
    fun `overflow flows onto continuation pages using the later capacity`() {
        // 10 fit on page 1, the rest flow 20-per continuation page.
        assertEquals(listOf(10, 20, 20, 5), paginateSightingRows(55, 10, 20))
    }

    @Test
    fun `exact multiple does not emit a trailing empty page`() {
        assertEquals(listOf(10, 20, 20), paginateSightingRows(50, 10, 20))
    }

    @Test
    fun `a full first page then a single continuation row`() {
        assertEquals(listOf(10, 1), paginateSightingRows(11, 10, 20))
    }

    @Test
    fun `pathologically small capacity still makes progress one row per page`() {
        // Clamped to at least 1 so we never loop forever on a tiny page.
        assertEquals(listOf(1, 1, 1), paginateSightingRows(3, 0, 0))
    }

    @Test
    fun `total page count equals the number of per-page entries`() {
        val pages = paginateSightingRows(100, 30, 54)
        // 30 on page 1, then 54, then 16 → 3 pages.
        assertEquals(listOf(30, 54, 16), pages)
        assertEquals(3, pages.size)
        assertEquals(100, pages.sum())
    }

    // ── summary honesty ─────────────────────────────────────────────────────────

    @Test
    fun `summary reads the plain count when nothing is hidden`() {
        assertEquals("27 sightings", sightingLogSummary(shown = 27, total = 27))
    }

    @Test
    fun `summary is singular for exactly one sighting`() {
        assertEquals("1 sighting", sightingLogSummary(shown = 1, total = 1))
    }

    @Test
    fun `summary discloses the fetch cap when the true total is larger`() {
        // 153 on the server, only the 100 most recent fetched → say so.
        assertEquals(
            "153 sightings (showing the 100 most recent)",
            sightingLogSummary(shown = 100, total = 153),
        )
    }

    @Test
    fun `summary falls back to shown when the total is unknown`() {
        // dossierTotal 0 (older/edge response) but rows are in hand.
        assertEquals("5 sightings", sightingLogSummary(shown = 5, total = 0))
    }

    // ── camera label ────────────────────────────────────────────────────────────

    @Test
    fun `camera label prefers the display name`() {
        assertEquals("Front Gate", sightingCameraLabel("cam-1", mapOf("cam-1" to "Front Gate")))
    }

    @Test
    fun `camera label falls back to the id when unnamed`() {
        assertEquals("cam-9", sightingCameraLabel("cam-9", emptyMap()))
    }

    @Test
    fun `camera label falls back to the id when the name is blank`() {
        assertEquals("cam-9", sightingCameraLabel("cam-9", mapOf("cam-9" to "  ")))
    }

    // ── ordering ────────────────────────────────────────────────────────────────

    @Test
    fun `sightings order newest first`() {
        val a = read("a", "cam-1", "2026-08-01T10:00:00Z")
        val b = read("b", "cam-1", "2026-08-06T10:00:00Z")
        val c = read("c", "cam-1", "2026-08-03T10:00:00Z")
        val ordered = sightingsNewestFirst(listOf(a, b, c))
        assertEquals(listOf("b", "c", "a"), ordered.map { it.id })
    }

    @Test
    fun `unparseable timestamps sort to the end rather than throwing`() {
        val good = read("good", "cam-1", "2026-08-06T10:00:00Z")
        val bad = read("bad", "cam-1", "not-a-timestamp")
        val ordered = sightingsNewestFirst(listOf(bad, good))
        assertEquals(listOf("good", "bad"), ordered.map { it.id })
    }
}
