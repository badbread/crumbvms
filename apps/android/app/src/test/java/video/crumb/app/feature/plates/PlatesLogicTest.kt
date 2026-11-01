// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import video.crumb.app.data.PlateAliasCreated
import video.crumb.app.data.PlateCameraCount
import video.crumb.app.data.PlateRead
import video.crumb.app.data.PlateStatsDto
import video.crumb.app.data.PlateStatsResponse
import java.time.Instant
import java.time.ZoneId

/**
 * Pure-logic tests for the Plates tab redesign: Hide regulars, crop sizing,
 * the filter chip strip, merge duplicates, visits, the profile video window,
 * chart helpers and the plate-correction helpers.
 */
class PlatesLogicTest {

    private val utc = ZoneId.of("UTC")

    private fun read(
        id: String,
        plate: String,
        ts: String = "2026-10-30T12:00:00Z",
        cam: String = "cam-1",
        conf: Float? = 0.9f,
        name: String? = null,
        bbox: List<Double>? = null,
    ) = PlateRead(id = id, cameraId = cam, ts = ts, plate = plate, confidence = conf, displayName = name, bbox = bbox)

    private fun stats(
        plate: String,
        total: Int = 10,
        seen30d: Int = 10,
        today: Int = 0,
        hours: List<Int> = List(24) { 0 },
        cameras: List<PlateCameraCount> = emptyList(),
    ) = PlateStatsDto(
        plate = plate,
        total = total,
        seen30d = seen30d,
        hours = hours,
        days30 = List(29) { 0 } + today,
        cameras = cameras,
    )

    // ── regulars ────────────────────────────────────────────────────────────

    @Test
    fun `a plate seen often before today is a regular`() {
        assertTrue(stats("A", total = 12, seen30d = 12, today = 1).isRegularPlate(5))
        assertFalse(stats("A", total = 12, seen30d = 4, today = 0).isRegularPlate(5))
    }

    @Test
    fun `a plate whose reads are all from today is new, never regular`() {
        val s = stats("A", total = 6, seen30d = 6, today = 6)
        assertTrue(s.isNewPlate())
        assertFalse(s.isRegularPlate(5))
    }

    @Test
    fun `hide regulars drops regulars but keeps watchlisted, unknown and rare plates`() {
        val reads = listOf(
            read("1", "REGULAR"),
            read("2", "WATCHED"),
            read("3", "RARE"),
            read("4", "NOHISTORY"),
        )
        val st = mapOf(
            "REGULAR" to stats("REGULAR", total = 30, seen30d = 30),
            "WATCHED" to stats("WATCHED", total = 30, seen30d = 30),
            "RARE" to stats("RARE", total = 2, seen30d = 2),
        )
        val kept = withoutRegularReads(reads, watched = { it == "WATCHED" }, stats = { st[it] }, minReads = 5)
        assertEquals(listOf("2", "3", "4"), kept.map { it.id })
    }

    @Test
    fun `hide regulars follows the server threshold`() {
        val s = stats("A", total = 8, seen30d = 8)
        assertTrue(isHiddenRegular(false, s, minReads = 5))
        assertFalse(isHiddenRegular(false, s, minReads = 9))
    }

    @Test
    fun `rail priority is watchlist then new then regular`() {
        val fresh = stats("A", total = 2, seen30d = 2, today = 2)
        val reg = stats("B", total = 20, seen30d = 20)
        assertEquals(PlateRail.WATCHLIST, plateRail(true, fresh))
        assertEquals(PlateRail.NEW, plateRail(false, fresh))
        assertEquals(PlateRail.REGULAR, plateRail(false, reg))
        assertEquals(PlateRail.NONE, plateRail(false, null))
    }

    // ── crop sizing ─────────────────────────────────────────────────────────

    @Test
    fun `crop aspect estimate scales the box by the frame aspect`() {
        // A box 0.2 wide and 0.1 tall on a 16:9 frame is (0.2 * 16) / (0.1 * 9) = 3.56.
        val a = cropAspectEstimate(listOf(0.4, 0.5, 0.2, 0.1))
        assertNotNull(a)
        assertEquals(3.56f, a!!, 0.01f)
    }

    @Test
    fun `crop aspect estimate is null without a usable box`() {
        assertNull(cropAspectEstimate(null))
        assertNull(cropAspectEstimate(listOf(0.1, 0.1)))
        assertNull(cropAspectEstimate(listOf(0.1, 0.1, 0.0, 0.2)))
    }

    @Test
    fun `absurd crop aspects are clamped to something a plate can be`() {
        assertEquals(6f, clampCropAspect(40f), 0f)
        assertEquals(1f, clampCropAspect(0.2f), 0f)
        assertEquals(DEFAULT_PLATE_ASPECT, clampCropAspect(Float.NaN), 0f)
    }

    @Test
    fun `a wide plate fills the slot by width and is short`() {
        val (w, h) = fitCropBox(4.7f, slotW = 104f, slotH = 56f)
        assertEquals(104f, w, 0.01f)
        assertEquals(22.1f, h, 0.1f)
    }

    @Test
    fun `a us plate is two to one inside the slot`() {
        val (w, h) = fitCropBox(2f, slotW = 104f, slotH = 56f)
        assertEquals(104f, w, 0.01f)
        assertEquals(52f, h, 0.01f)
    }

    @Test
    fun `a tall crop shrinks to the slot height and keeps its aspect`() {
        val (w, h) = fitCropBox(1.2f, slotW = 104f, slotH = 56f)
        assertEquals(56f, h, 0.01f)
        assertEquals(67.2f, w, 0.1f)
        assertEquals(1.2f, w / h, 0.01f)
    }

    // ── filters and chips ───────────────────────────────────────────────────

    private val cams = mapOf("a" to "Front gate", "b" to "Driveway", "c" to "Side street")

    private fun chips(
        selected: Set<String> = cams.keys,
        hours: Long = 24L,
        anchor: Long? = null,
        match: String = "contains",
        hide: Boolean = false,
    ) = activeFilterChips(cams, selected, hours, anchor, anchor?.let { "Oct 29, 14:00" }, match, hide) { "$it hours" }

    @Test
    fun `all defaults means no chips and no badge`() {
        assertTrue(chips().isEmpty())
        assertEquals(0, activeFilterCount(chips()))
    }

    @Test
    fun `each non default filter gets one chip`() {
        val c = chips(selected = setOf("a"), hours = 168, anchor = 1L, match = "fuzzy", hide = true)
        assertEquals(
            listOf(FilterKind.CAMERAS, FilterKind.RANGE, FilterKind.ENDS_AT, FilterKind.MATCH, FilterKind.HIDE_REGULARS),
            c.map { it.kind },
        )
        assertEquals(5, activeFilterCount(c))
        assertEquals("Front gate", c[0].label)
        assertEquals("Ends Oct 29, 14:00", c[2].label)
    }

    @Test
    fun `several cameras read as a count`() {
        assertEquals("2 of 3 cameras", chips(selected = setOf("a", "b")).single().label)
    }

    @Test
    fun `an end time is ignored for all time`() {
        assertTrue(chips(hours = 0, anchor = 5L).none { it.kind == FilterKind.ENDS_AT })
    }

    @Test
    fun `tapping a camera with everything on narrows to that one`() {
        assertEquals(setOf("b"), toggleCameraSelection(listOf("a", "b", "c"), setOf("a", "b", "c"), "b"))
    }

    @Test
    fun `camera chips toggle and never end up empty`() {
        val all = listOf("a", "b", "c")
        assertEquals(setOf("b", "a"), toggleCameraSelection(all, setOf("b"), "a"))
        assertEquals(setOf("a", "b"), toggleCameraSelection(all, setOf("a", "b"), "c").minus("c"))
        assertEquals(setOf("b"), toggleCameraSelection(all, setOf("a", "b"), "a"))
        // Removing the last selected camera snaps back to all cameras.
        assertEquals(all.toSet(), toggleCameraSelection(all, setOf("b"), "b"))
    }

    @Test
    fun `the timeline view is gone and a stored timeline falls back to list`() {
        assertEquals(PlatesViewMode.LIST, PlatesViewMode.fromKey("timeline"))
        assertEquals(PlatesViewMode.GALLERY, PlatesViewMode.fromKey("gallery"))
        assertEquals(PlatesViewMode.GROUPED, PlatesViewMode.fromKey("grouped"))
        assertEquals(PlatesViewMode.LIST, PlatesViewMode.fromKey(null))
    }

    @Test
    fun `feed summary notes the cap and the hidden regulars`() {
        assertEquals("142 reads", feedSummary(142, 142, 142, 0))
        assertEquals("1 read", feedSummary(1, 1, 1, 0))
        assertEquals("Latest 200 of 1204 reads", feedSummary(200, 200, 1204, 0))
        assertEquals("142 reads, 58 from regulars hidden", feedSummary(84, 142, 142, 58))
    }

    // ── time labels ─────────────────────────────────────────────────────────

    private fun ms(iso: String) = Instant.parse(iso).toEpochMilli()

    @Test
    fun `row time is relative within the hour and a clock time after`() {
        val now = ms("2026-10-30T12:00:00Z")
        assertEquals("just now", rowTimeLabel(now - 20_000, now, utc))
        assertEquals("2 min ago", rowTimeLabel(now - 125_000, now, utc))
        assertEquals("9:41 AM", rowTimeLabel(ms("2026-10-30T09:41:00Z"), now, utc))
        assertEquals("9:41 PM", clockLabel(ms("2026-10-29T21:41:00Z"), utc))
    }

    @Test
    fun `day headers say today and yesterday`() {
        val now = ms("2026-10-30T12:00:00Z")
        assertEquals("Today", dayLabel(ms("2026-10-30T01:00:00Z"), now, utc))
        assertEquals("Yesterday", dayLabel(ms("2026-10-29T23:00:00Z"), now, utc))
        assertEquals("Mon, Oct 26", dayLabel(ms("2026-10-26T10:00:00Z"), now, utc))
    }

    @Test
    fun `hour labels use am and pm`() {
        assertEquals("12 am", hourLabel(0))
        assertEquals("9 am", hourLabel(9))
        assertEquals("12 pm", hourLabel(12))
        assertEquals("11 pm", hourLabel(23))
    }

    // ── merge duplicates ────────────────────────────────────────────────────

    @Test
    fun `reads of one pass on one camera merge into the best read`() {
        val reads = listOf(
            read("3", "9GXV498", ts = "2026-10-30T12:00:10Z", conf = 0.95f),
            read("2", "9GXVL98", ts = "2026-10-30T12:00:06Z", conf = 0.7f),
            read("1", "9GXVL98", ts = "2026-10-30T12:00:02Z", conf = 0.6f),
        )
        val groups = collapsePlateReads(reads)
        assertEquals(1, groups.size)
        assertEquals("3", groups[0].representative.id)
        assertEquals(3, groups[0].count)
        assertEquals(listOf("3", "2", "1"), groups[0].members.map { it.id })
    }

    @Test
    fun `different cameras or far apart reads do not merge`() {
        val reads = listOf(
            read("4", "ABC123", ts = "2026-10-30T12:05:00Z"),
            read("3", "ABC123", ts = "2026-10-30T12:00:05Z", cam = "cam-2"),
            read("2", "ABC123", ts = "2026-10-30T12:00:00Z"),
            read("1", "ZZZ999", ts = "2026-10-30T12:00:01Z"),
        )
        assertEquals(4, collapsePlateReads(reads).size)
    }

    @Test
    fun `similar plates are the same car but short different plates are not`() {
        assertTrue(platesSimilar("9GXVL98", "9GXV498"))
        assertFalse(platesSimilar("ABC123", "XYZ789"))
        assertFalse(platesSimilar("", "ABC"))
    }

    // ── grouped by plate ────────────────────────────────────────────────────

    @Test
    fun `grouping keeps the newest read first and orders groups by last seen`() {
        val reads = listOf(
            read("4", "B", ts = "2026-10-30T12:04:00Z"),
            read("3", "A", ts = "2026-10-30T12:03:00Z"),
            read("2", "B", ts = "2026-10-30T12:02:00Z"),
            read("1", "A", ts = "2026-10-30T12:01:00Z"),
        )
        val g = groupByPlate(reads)
        assertEquals(listOf("B", "A"), g.map { it.plate })
        assertEquals(2, g[0].count)
        assertEquals("4", g[0].latest.id)
    }

    // ── visits and the video window ─────────────────────────────────────────

    @Test
    fun `reads within five minutes on one camera are one visit`() {
        val reads = listOf(
            read("5", "A", ts = "2026-10-30T12:30:00Z"),
            read("4", "A", ts = "2026-10-30T12:03:00Z"),
            read("3", "A", ts = "2026-10-30T12:00:30Z"),
            read("2", "A", ts = "2026-10-30T12:01:00Z", cam = "cam-2"),
            read("1", "A", ts = "2026-10-30T12:00:00Z"),
        )
        val visits = collapseVisits(reads)
        // newest visit first: 12:30 alone, then 12:00-12:03 on cam-1, then cam-2.
        assertEquals(3, visits.size)
        assertEquals(listOf("5"), visits[0].reads.map { it.id })
        assertEquals(3, visits[1].count)
        assertEquals("cam-1", visits[1].cameraId)
        assertEquals("cam-2", visits[2].cameraId)
    }

    @Test
    fun `a visit picks its most confident read`() {
        val v = collapseVisits(
            listOf(
                read("2", "A", ts = "2026-10-30T12:01:00Z", conf = 0.6f),
                read("1", "A", ts = "2026-10-30T12:00:00Z", conf = 0.97f),
            ),
        ).single()
        assertEquals("1", v.best.id)
        assertEquals("2", v.id)
    }

    @Test
    fun `the video window pads the visit`() {
        val (s, e) = sightingWindow(100_000L, 130_000L, 110_000L)
        assertEquals(90_000L, s)
        assertEquals(140_000L, e)
    }

    @Test
    fun `a long parked visit is capped to a few minutes around the read`() {
        val start = 0L
        val end = 3_600_000L
        val focus = 1_800_000L
        val (s, e) = sightingWindow(start, end, focus)
        assertTrue(e - s <= SIGHTING_MAX_SPAN_MS)
        assertTrue(focus in s..e)
    }

    @Test
    fun `scrub times read as minutes and seconds`() {
        assertEquals("0:04", scrubTimeLabel(4_000))
        assertEquals("1:05", scrubTimeLabel(65_900))
        assertEquals("0:00", scrubTimeLabel(-5))
    }

    // ── charts ──────────────────────────────────────────────────────────────

    @Test
    fun `bar fractions are relative to the tallest bar with a visible floor`() {
        val f = barFractions(listOf(0, 1, 10, 5))
        assertEquals(0.03f, f[0], 0.001f)
        assertEquals(0.1f, f[1], 0.001f)
        assertEquals(1f, f[2], 0.001f)
        assertEquals(0.5f, f[3], 0.001f)
        assertEquals(List(3) { 0.03f }, barFractions(listOf(0, 0, 0)))
    }

    @Test
    fun `bar captions show the number`() {
        assertEquals("9 am to 10 am: 12 of 176 reads", hourBarCaption(9, 12, 176))
        assertEquals("11 pm to 12 am: 1 of 1 read", hourBarCaption(23, 1, 1))
        assertEquals("Time of day, all 176 reads", hourChartTitle(176))
        val now = ms("2026-10-30T12:00:00Z")
        assertEquals("Today: 3 reads", dayBarCaption(0, 3, now, utc))
        assertEquals("Thu, Oct 29: 0 reads", dayBarCaption(1, 0, now, utc))
    }

    @Test
    fun `camera split keeps the biggest and merges the tail`() {
        val counts = listOf("a" to 50, "b" to 30, "c" to 10, "d" to 5, "e" to 3, "f" to 2)
            .map { PlateCameraCount(it.first, it.second) }
        val slices = cameraSplitSlices(counts, { "cam $it" }, maxSlices = 4)
        assertEquals(listOf("cam a", "cam b", "cam c", "Other cameras"), slices.map { it.label })
        assertEquals(10, slices.last().n)
        assertEquals(counts.size, cameraSplitSlices(counts, { it }, maxSlices = 10).size)
    }

    @Test
    fun `summary says when a regular usually arrives`() {
        val hours = List(24) { 0 }.toMutableList().also { it[8] = 10; it[18] = 8; it[12] = 2 }
        val s = stats("A", total = 20, seen30d = 20, hours = hours, cameras = listOf(PlateCameraCount("a", 20)))
        val text = plateSummary(s, { "Front gate" }, nowMs = ms("2026-10-30T12:00:00Z"), firstSeenMs = null, zone = utc)
        assertEquals("Usually arrives between 8 and 9 am, mostly at Front gate.", text)
    }

    @Test
    fun `summary for a plate seen at all hours`() {
        val s = stats("A", total = 24, seen30d = 24, hours = List(24) { 1 }, cameras = listOf(PlateCameraCount("a", 10), PlateCameraCount("b", 14)))
        assertEquals("Comes and goes at all hours, across 2 cameras.", plateSummary(s, { it }, 0L, null, utc))
    }

    @Test
    fun `summary for a plate first seen today`() {
        val s = stats("A", total = 2, seen30d = 2, today = 2, cameras = listOf(PlateCameraCount("a", 2)))
        assertEquals("First seen today at Front gate, 2 times so far.", plateSummary(s, { "Front gate" }, 0L, null, utc))
    }

    // ── plate correction ────────────────────────────────────────────────────

    @Test
    fun `plate input is uppercased and stripped to letters and digits`() {
        assertEquals("GIF2GAB", normalizePlateInput(" gif-2 gab "))
        assertEquals("", normalizePlateInput("--"))
    }

    @Test
    fun `only admins are offered correction`() {
        assertTrue(canOfferPlateCorrection(true, "ABC123"))
        assertFalse(canOfferPlateCorrection(false, "ABC123"))
        assertFalse(canOfferPlateCorrection(true, "  "))
    }

    @Test
    fun `correction effect describes what will move`() {
        assertEquals(
            "GIT2GAB's 12 reads will count as GIF2GAB, and so will future reads of it.",
            plateCorrectionEffect("GIT2GAB", "gif2gab", 12),
        )
        assertEquals(
            "Future reads of GIT2GAB will count as GIF2GAB.",
            plateCorrectionEffect("GIT2GAB", "GIF2GAB", 0),
        )
        assertEquals(
            "GIT2GAB's 1 read will count as GIF2GAB, and so will future reads of it. Its known misread G1T2GAB will move to GIF2GAB too.",
            plateCorrectionEffect("GIT2GAB", "GIF2GAB", 1, listOf("G1T2GAB")),
        )
    }

    @Test
    fun `correction effect is null for an unusable target`() {
        assertNull(plateCorrectionEffect("GIT2GAB", "", 3))
        assertNull(plateCorrectionEffect("GIT2GAB", "git-2-gab", 3))
        assertNull(plateCorrectionEffect("", "ABC", 3))
    }

    @Test
    fun `suggestion distance reads in words`() {
        assertEquals("look-alike characters", plateSuggestionDistanceLabel(0))
        assertEquals("1 character off", plateSuggestionDistanceLabel(1))
        assertEquals("2 characters off", plateSuggestionDistanceLabel(2))
    }

    @Test
    fun `an open read moves to the corrected plate and loses the old name`() {
        val r = plateReadAs(read("1", "GIT2GAB", name = "Old name"), "GIF2GAB")
        assertEquals("GIF2GAB", r.plate)
        assertNull(r.displayName)
        assertEquals("1", r.id)
    }

    // ── wire shapes ─────────────────────────────────────────────────────────

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `plate stats response parses the server shape`() {
        val body = """
            {"tz":"America/Los_Angeles","today":"2026-10-30","regular_min_reads_30d":5,
             "plates":[{"plate":"ABC123","total":39,"seen_7d":4,"seen_30d":18,
               "first_seen":"2026-03-03T10:00:00Z","last_seen":"2026-10-30T16:41:00Z","prev_seen":null,
               "cameras":[{"camera_id":"cam-1","n":30},{"camera_id":"cam-2","n":9}],
               "hours":[0,0,0,0,0,0,0,0,12,3,0,0,0,0,0,0,0,0,9,0,0,0,0,0],
               "days30":[0,1,0,2,1,0,0,1,2,1,0,0,1,1,0,2,1,0,1,0,0,1,2,1,0,1,1,0,2,3]}]}
        """.trimIndent()
        val r = json.decodeFromString(PlateStatsResponse.serializer(), body)
        assertEquals(5, r.regularMinReads30d)
        val p = r.plates.single()
        assertEquals(39, p.total)
        assertEquals(24, p.hours.size)
        assertEquals(30, p.days30.size)
        assertEquals(3, p.days30.last())
        assertEquals("cam-1", p.cameras.first().cameraId)
        assertNull(p.prevSeen)
        assertFalse(p.isNewPlate())
        assertTrue(p.isRegularPlate(r.regularMinReads30d))
    }

    @Test
    fun `alias create response parses the server shape`() {
        val body = """
            {"alias":{"alias_plate":"GIT2GAB","canonical_plate":"GIF2GAB","created_by":null,
             "created_at":"2026-10-30T16:41:00Z","reads":7},"moved":["G1T2GAB"]}
        """.trimIndent()
        val r = json.decodeFromString(PlateAliasCreated.serializer(), body)
        assertEquals("GIT2GAB", r.alias.aliasPlate)
        assertEquals("GIF2GAB", r.alias.canonicalPlate)
        assertEquals(7, r.alias.reads)
        assertEquals(listOf("G1T2GAB"), r.moved)
    }
}
