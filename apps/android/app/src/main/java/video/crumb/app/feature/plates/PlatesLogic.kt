// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import video.crumb.app.data.DEFAULT_REGULAR_MIN_READS_30D
import video.crumb.app.data.PlateRead
import video.crumb.app.data.PlateStatsDto
import video.crumb.app.ui.Time
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * Pure logic behind the Plates tab redesign (no Compose, no Android types, so
 * all of it is unit-tested in PlatesLogicTest). It mirrors the desktop plate
 * desk (`apps/desktop-flutter/lib/ui/plates/plate_desk_logic.dart` and
 * `plate_collapse.dart`) wherever the two clients share a rule.
 */

// ─── classification: new / regular / rails ──────────────────────────────────

/** Every visible read of the plate happened on the server's today: a first-time plate. */
fun PlateStatsDto.isNewPlate(): Boolean = total > 0 && (days30.lastOrNull() ?: 0) >= total

/**
 * Seen before today with at least [minReads] reads in the last 30 days. The
 * same rule as the desktop's `PlateStats.isRegular` and the server's overview
 * split, so all clients label a plate the same way.
 */
fun PlateStatsDto.isRegularPlate(minReads: Int = DEFAULT_REGULAR_MIN_READS_30D): Boolean =
    !isNewPlate() && seen30d >= minReads

/** The coloured left rail on a row: watchlist wins over new, new over regular. */
enum class PlateRail { NONE, WATCHLIST, NEW, REGULAR }

fun plateRail(watched: Boolean, stats: PlateStatsDto?, minReads: Int = DEFAULT_REGULAR_MIN_READS_30D): PlateRail =
    when {
        watched -> PlateRail.WATCHLIST
        stats == null -> PlateRail.NONE
        stats.isNewPlate() -> PlateRail.NEW
        stats.isRegularPlate(minReads) -> PlateRail.REGULAR
        else -> PlateRail.NONE
    }

/**
 * Whether a read is hidden by "Hide regulars": the plate is a known regular and
 * is not on the watchlist. A plate whose history has not loaded is never hidden
 * (no flicker-hiding of unknowns), and a watchlisted plate always shows.
 */
fun isHiddenRegular(watched: Boolean, stats: PlateStatsDto?, minReads: Int = DEFAULT_REGULAR_MIN_READS_30D): Boolean =
    !watched && stats != null && stats.isRegularPlate(minReads)

/** Drops the reads of known, non-watchlisted regulars. */
fun withoutRegularReads(
    reads: List<PlateRead>,
    watched: (String) -> Boolean,
    stats: (String) -> PlateStatsDto?,
    minReads: Int = DEFAULT_REGULAR_MIN_READS_30D,
): List<PlateRead> = reads.filterNot { isHiddenRegular(watched(it.plate), stats(it.plate), minReads) }

// ─── plate crop sizing ──────────────────────────────────────────────────────

/** Frame aspect assumed until the real crop has decoded (the common camera shape). */
const val DEFAULT_FRAME_ASPECT: Float = 16f / 9f

/** Plausible plate crop aspect range; anything outside is a bad box, not a plate. */
private const val MIN_CROP_ASPECT = 1.0f
private const val MAX_CROP_ASPECT = 6.0f

/** Clamp a measured crop aspect (width / height) into the range a plate can have. */
fun clampCropAspect(aspect: Float): Float =
    if (aspect.isNaN() || aspect <= 0f) DEFAULT_PLATE_ASPECT else aspect.coerceIn(MIN_CROP_ASPECT, MAX_CROP_ASPECT)

/** Used when nothing is known about the crop (a US plate is 2:1). */
const val DEFAULT_PLATE_ASPECT: Float = 2f

/**
 * The crop's display aspect (width / height) estimated from the read's
 * normalized `[x, y, w, h]` box before the image has loaded. The box is in
 * fractions of the frame, so the real aspect is `(w * frameW) / (h * frameH)`;
 * the frame size is not in the read, so [frameAspect] (frameW / frameH) stands
 * in until the decoded crop reports its true pixel size. Null when there is no
 * usable box (the caller then shows the whole frame).
 */
fun cropAspectEstimate(bbox: List<Double>?, frameAspect: Float = DEFAULT_FRAME_ASPECT): Float? {
    if (bbox == null || bbox.size < 4) return null
    val w = bbox[2]
    val h = bbox[3]
    if (w <= 0.0 || h <= 0.0) return null
    return clampCropAspect((w / h).toFloat() * frameAspect)
}

/**
 * Size a crop of [aspect] (width / height) inside a [slotW] x [slotH] slot: it
 * fills the slot by width, and only shrinks (keeping its aspect) when that
 * would be taller than the slot. A tiny far-away plate therefore becomes a
 * small box, never a letterboxed black block.
 */
fun fitCropBox(aspect: Float, slotW: Float, slotH: Float): Pair<Float, Float> {
    val a = clampCropAspect(aspect)
    val h = slotW / a
    return if (h <= slotH) slotW to h else (slotH * a) to slotH
}

// ─── filters and the chip strip ─────────────────────────────────────────────

/** Default range of the feed, in hours. */
const val DEFAULT_RANGE_HOURS: Long = 24L

/** Default match mode of the search box. */
const val DEFAULT_MATCH: String = "contains"

enum class FilterKind { CAMERAS, RANGE, ENDS_AT, MATCH, HIDE_REGULARS }

/** One dismissible chip in the strip under the search bar. */
data class ActiveFilterChip(val kind: FilterKind, val label: String)

/**
 * The chips to show under the search bar: one per filter that is off its
 * default, in a stable order. Empty when everything is default, which is the
 * calm first screen (the strip is not drawn at all then).
 *
 * [cameraNames] is the id -> name map of the cameras that exist; [selected] the
 * ids currently included. [anchorLabel] is the already-formatted "ends at" time.
 */
fun activeFilterChips(
    cameraNames: Map<String, String>,
    selected: Set<String>,
    hours: Long,
    anchorEndMs: Long?,
    anchorLabel: String?,
    match: String,
    hideRegulars: Boolean,
    rangeLabel: (Long) -> String,
): List<ActiveFilterChip> {
    val out = mutableListOf<ActiveFilterChip>()
    val chosen = cameraNames.keys.filter { it in selected }
    if (cameraNames.isNotEmpty() && chosen.size != cameraNames.size) {
        val label = when (chosen.size) {
            0 -> "No cameras"
            1 -> cameraNames[chosen.first()].orEmpty().ifBlank { "1 camera" }
            else -> "${chosen.size} of ${cameraNames.size} cameras"
        }
        out += ActiveFilterChip(FilterKind.CAMERAS, label)
    }
    if (hours != DEFAULT_RANGE_HOURS) out += ActiveFilterChip(FilterKind.RANGE, rangeLabel(hours))
    if (anchorEndMs != null && hours != 0L) {
        out += ActiveFilterChip(FilterKind.ENDS_AT, "Ends ${anchorLabel.orEmpty()}".trim())
    }
    if (match != DEFAULT_MATCH) {
        out += ActiveFilterChip(FilterKind.MATCH, if (match == "exact") "Exact match" else "Fuzzy match")
    }
    if (hideRegulars) out += ActiveFilterChip(FilterKind.HIDE_REGULARS, "Hide regulars")
    return out
}

/** The number on the filter icon's badge: how many filters are off their default. */
fun activeFilterCount(chips: List<ActiveFilterChip>): Int = chips.size

/**
 * Camera chip tap rules for the filter sheet. With every camera on, tapping one
 * narrows to just that camera; otherwise it toggles; and an empty selection
 * snaps back to all cameras (never a list that can show nothing).
 */
fun toggleCameraSelection(allIds: List<String>, selected: Set<String>, tapped: String): Set<String> {
    val allOn = allIds.isNotEmpty() && selected.containsAll(allIds)
    val next = when {
        allOn -> setOf(tapped)
        tapped in selected -> selected - tapped
        else -> selected + tapped
    }
    return if (next.isEmpty()) allIds.toSet() else next
}

// ─── time labels for rows ───────────────────────────────────────────────────

private val clockFmt: DateTimeFormatter = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
private val shortDateFmt: DateTimeFormatter = DateTimeFormatter.ofPattern("MMM d", Locale.US)
private val fullDateFmt: DateTimeFormatter = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US)
private val dayHeaderFmt: DateTimeFormatter = DateTimeFormatter.ofPattern("EEE, MMM d", Locale.US)

/** "Today", "Yesterday", or "Mon, Mar 3": the date header above a run of rows. */
fun dayLabel(tsMs: Long, nowMs: Long, zone: ZoneId = Time.zone): String {
    val day = Instant.ofEpochMilli(tsMs).atZone(zone).toLocalDate()
    val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
    return when (day) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> dayHeaderFmt.format(day)
    }
}

/** The local calendar day of [tsMs], the key rows are grouped under. */
fun dayKey(tsMs: Long, zone: ZoneId = Time.zone): LocalDate =
    Instant.ofEpochMilli(tsMs).atZone(zone).toLocalDate()

/**
 * Time text for line two of a row: "just now" or "N min ago" within the last
 * hour, otherwise the clock time ("9:41 AM"). The date header above the row
 * carries the day.
 */
fun rowTimeLabel(tsMs: Long, nowMs: Long, zone: ZoneId = Time.zone): String {
    val diff = nowMs - tsMs
    if (diff in -60_000L until 60_000L) return "just now"
    if (diff in 60_000L until 3_600_000L) return "${diff / 60_000L} min ago"
    return clockFmt.format(Instant.ofEpochMilli(tsMs).atZone(zone))
}

/** "9:41 AM": the clock time of an instant in the device zone. */
fun clockLabel(tsMs: Long, zone: ZoneId = Time.zone): String =
    clockFmt.format(Instant.ofEpochMilli(tsMs).atZone(zone))

/** "Mar 3" (this year) or "Mar 3, 2025", for first-seen style facts. */
fun shortDateLabel(tsMs: Long, nowMs: Long, zone: ZoneId = Time.zone): String {
    val d = Instant.ofEpochMilli(tsMs).atZone(zone).toLocalDate()
    val n = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
    return if (d.year == n.year) shortDateFmt.format(d) else fullDateFmt.format(d)
}

/** "2 min ago", "3 h ago", "5 days ago": a coarse relative time. */
fun agoLabel(tsMs: Long, nowMs: Long): String {
    val diff = max(0L, nowMs - tsMs)
    val min = diff / 60_000L
    return when {
        min < 1 -> "just now"
        min < 60 -> "$min min ago"
        min < 60 * 24 -> "${min / 60} h ago"
        else -> "${min / (60 * 24)} ${if (min / (60 * 24) == 1L) "day" else "days"} ago"
    }
}

/** "9 am", "12 pm", for the hour-of-day axis and tooltips. */
fun hourLabel(hour: Int): String {
    val h = ((hour % 24) + 24) % 24
    val h12 = if (h % 12 == 0) 12 else h % 12
    return "$h12 ${if (h < 12) "am" else "pm"}"
}

/**
 * The one-line count in the filter sheet footer: "142 reads", or "Latest 200 of
 * 1204 reads" when the feed was capped, plus how many reads Hide regulars dropped.
 */
fun feedSummary(shown: Int, loaded: Int, total: Int, hiddenRegulars: Int): String {
    val head = if (loaded < total) "Latest $loaded of $total reads" else readsLabel(loaded)
    return if (hiddenRegulars > 0) "$head, $hiddenRegulars from regulars hidden" else head
}

/** "1 read" / "12 reads". */
fun readsLabel(n: Int): String = if (n == 1) "1 read" else "$n reads"

// ─── merge duplicates (one row per physical vehicle pass) ───────────────────

/**
 * How far apart (in time) two reads on the same camera can be and still be one
 * pass. Covers multi-second OCR refinement and the ~2 s offset between two
 * engines, while staying under the worker's 45 s re-appear gap.
 */
const val PASS_WINDOW_MS: Long = 15_000L

/** One vehicle pass: the best read plus every raw read that merged into it, newest first. */
data class PassGroup(val representative: PlateRead, val members: List<PlateRead>) {
    val count: Int get() = members.size
}

/**
 * Collapse [readsNewestFirst] into one [PassGroup] per physical pass: same
 * camera, fuzzy-equal plate, within [windowMs]. The input must be newest-first;
 * output keeps that order by representative timestamp. Raw reads are untouched
 * server-side; this is only how the client presents them.
 */
fun collapsePlateReads(readsNewestFirst: List<PlateRead>, windowMs: Long = PASS_WINDOW_MS): List<PassGroup> {
    class Mut(first: PlateRead) {
        val cameraId = first.cameraId
        var best = first
        var oldestTs = Time.parseToMillis(first.ts)
        val members = mutableListOf(first)
        fun add(r: PlateRead) {
            members += r
            val t = Time.parseToMillis(r.ts)
            if (t < oldestTs) oldestTs = t
            if ((r.confidence ?: 0f) > (best.confidence ?: 0f)) best = r
        }
    }
    val groups = mutableListOf<Mut>()
    for (r in readsNewestFirst) {
        val t = Time.parseToMillis(r.ts)
        val target = groups.firstOrNull { g ->
            g.cameraId == r.cameraId && abs(g.oldestTs - t) <= windowMs && platesSimilar(g.best.plate, r.plate)
        }
        if (target != null) target.add(r) else groups += Mut(r)
    }
    return groups.map { g ->
        PassGroup(g.best, g.members.sortedByDescending { Time.parseToMillis(it.ts) })
    }
}

/** Two normalized plates are "the same car" within a small, length-scaled edit distance. */
fun platesSimilar(a: String, b: String): Boolean {
    if (a == b) return true
    if (a.isEmpty() || b.isEmpty()) return false
    val maxLen = max(a.length, b.length)
    val maxEdits = max(1, (maxLen * 0.34).roundToInt())
    return boundedLevenshtein(a, b, maxEdits) <= maxEdits
}

/** Levenshtein distance, giving up (returning maxEdits + 1) once it provably exceeds [maxEdits]. */
internal fun boundedLevenshtein(a: String, b: String, maxEdits: Int): Int {
    if (abs(a.length - b.length) > maxEdits) return maxEdits + 1
    var prev = IntArray(b.length + 1) { it }
    var curr = IntArray(b.length + 1)
    for (i in 1..a.length) {
        curr[0] = i
        var rowMin = curr[0]
        for (j in 1..b.length) {
            val cost = if (a[i - 1] == b[j - 1]) 0 else 1
            curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
            if (curr[j] < rowMin) rowMin = curr[j]
        }
        if (rowMin > maxEdits) return maxEdits + 1
        val tmp = prev
        prev = curr
        curr = tmp
    }
    return prev[b.length]
}

// ─── grouped by plate ───────────────────────────────────────────────────────

/** One normalized-plate group: its reads (newest first) + summary numbers. */
data class PlateGroup(
    val plate: String,
    val reads: List<PlateRead>,
) {
    val key: String get() = plate.ifEmpty { "(none)" }
    val count: Int get() = reads.size

    /** Reads are ordered newest-first, so first = latest, last = earliest. */
    val latest: PlateRead get() = reads.first()
}

/** Collapse [plates] (already newest-first) by normalized plate text, newest group first. */
fun groupByPlate(plates: List<PlateRead>): List<PlateGroup> =
    plates.groupBy { it.plate }
        .map { (plate, reads) -> PlateGroup(plate, reads) }
        .sortedByDescending { Time.parseToMillis(it.latest.ts) }

// ─── plate profile: visits, playback window ─────────────────────────────────

/** Reads of one plate on the same camera no more than this far apart are one visit. */
const val VISIT_GAP_MS: Long = 5 * 60_000L

/** One visit of a plate: consecutive reads on one camera, each within [VISIT_GAP_MS] of the next. */
data class PlateVisit(val cameraId: String, val reads: List<PlateRead>) {
    /** Newest first. */
    val startMs: Long get() = Time.parseToMillis(reads.last().ts)
    val endMs: Long get() = Time.parseToMillis(reads.first().ts)
    val count: Int get() = reads.size

    /** The most confident read (ties: the newest). */
    val best: PlateRead
        get() {
            var b = reads.first()
            for (r in reads) if ((r.confidence ?: 0f) > (b.confidence ?: 0f)) b = r
            return b
        }

    /** Stable id for list keys and selection: the id of the newest read. */
    val id: String get() = reads.first().id
}

/**
 * Collapse [reads] (any order) into visits, newest visit first. A read joins the
 * newest open visit on its camera when it is within [gapMs] of that visit's
 * oldest read; otherwise it starts a new visit.
 */
fun collapseVisits(reads: List<PlateRead>, gapMs: Long = VISIT_GAP_MS): List<PlateVisit> {
    class Builder(val cameraId: String, first: PlateRead) {
        val reads = mutableListOf(first)
    }
    val sorted = reads.sortedByDescending { Time.parseToMillis(it.ts) }
    val open = HashMap<String, Builder>()
    val visits = mutableListOf<Builder>()
    for (r in sorted) {
        val cur = open[r.cameraId]
        if (cur != null && Time.parseToMillis(cur.reads.last().ts) - Time.parseToMillis(r.ts) <= gapMs) {
            cur.reads += r
            continue
        }
        val v = Builder(r.cameraId, r)
        open[r.cameraId] = v
        visits += v
    }
    return visits.map { PlateVisit(it.cameraId, it.reads.toList()) }
}

/** Padding either side of a visit in the profile video. */
const val SIGHTING_PAD_MS: Long = 10_000L

/** Longest stretch the profile video scrubs over, so a car parked for an hour does not make a 1 hour scrubber. */
const val SIGHTING_MAX_SPAN_MS: Long = 180_000L

/**
 * The time range the profile video covers for a visit: the visit padded by
 * [SIGHTING_PAD_MS], capped to [SIGHTING_MAX_SPAN_MS] around [focusMs] (the
 * moment the plate was read).
 */
fun sightingWindow(visitStartMs: Long, visitEndMs: Long, focusMs: Long): Pair<Long, Long> {
    var start = visitStartMs - SIGHTING_PAD_MS
    var end = visitEndMs + SIGHTING_PAD_MS
    if (end - start > SIGHTING_MAX_SPAN_MS) {
        start = max(start, focusMs - 20_000L)
        end = min(end, start + SIGHTING_MAX_SPAN_MS)
        if (focusMs > end) {
            end = focusMs + 20_000L
            start = end - SIGHTING_MAX_SPAN_MS
        }
    }
    return start to end
}

/** `m:ss` for a scrubber time. */
fun scrubTimeLabel(ms: Long): String {
    val total = max(0L, ms) / 1000L
    return "${total / 60}:${(total % 60).toString().padStart(2, '0')}"
}

// ─── history charts ─────────────────────────────────────────────────────────

/** Bar heights as fractions (0..1) of the tallest bar, with a visible minimum for non-zero values. */
fun barFractions(values: List<Int>, minNonZero: Float = 0.06f, minZero: Float = 0.03f): List<Float> {
    val peak = values.maxOrNull() ?: 0
    if (peak <= 0) return values.map { minZero }
    return values.map { v ->
        if (v <= 0) minZero else max(minNonZero, v.toFloat() / peak)
    }
}

/** The caption shown when a bar is tapped, e.g. "9 am: 12 reads". */
fun hourBarCaption(hour: Int, reads: Int): String = "${hourLabel(hour)}: ${readsLabel(reads)}"

/** The caption for a day bar: [daysAgo] 0 = today. */
fun dayBarCaption(daysAgo: Int, reads: Int, nowMs: Long, zone: ZoneId = Time.zone): String {
    val day = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().minusDays(daysAgo.toLong())
    val label = if (daysAgo == 0) "Today" else dayHeaderFmt.format(day)
    return "$label: ${readsLabel(reads)}"
}

/** One slice of the camera split bar. */
data class SplitSlice(val label: String, val n: Int)

/**
 * The camera split as at most [maxSlices] slices, biggest first; the long tail
 * is merged into one "Other cameras" slice so the legend stays short.
 */
fun cameraSplitSlices(
    cameras: List<video.crumb.app.data.PlateCameraCount>,
    nameOf: (String) -> String,
    maxSlices: Int = 5,
): List<SplitSlice> {
    val sorted = cameras.filter { it.n > 0 }.sortedByDescending { it.n }
    if (sorted.size <= maxSlices) return sorted.map { SplitSlice(nameOf(it.cameraId), it.n) }
    val head = sorted.take(maxSlices - 1).map { SplitSlice(nameOf(it.cameraId), it.n) }
    return head + SplitSlice("Other cameras", sorted.drop(maxSlices - 1).sumOf { it.n })
}

/** The busiest window of [span] consecutive hours (wrapping at midnight): (startHour, reads). */
fun busiestHours(hours: List<Int>, span: Int): Pair<Int, Int> {
    if (hours.size < 24) return 0 to 0
    var bestH = 0
    var bestN = -1
    for (h in 0 until 24) {
        var n = 0
        for (k in 0 until span) n += hours[(h + k) % 24]
        if (n > bestN) {
            bestN = n
            bestH = h
        }
    }
    return bestH to max(bestN, 0)
}

/** "5 and 6 pm", "11 am and 12 pm". */
fun hourRangeLabel(h: Int, span: Int): String {
    val a = h % 24
    val b = (h + span) % 24
    val aPm = a >= 12
    val bPm = b >= 12
    val a12 = if (a % 12 == 0) 12 else a % 12
    return if (aPm == bPm && b != 0 && b != 12) {
        "$a12 and ${hourLabel(b)}"
    } else {
        "${hourLabel(a)} and ${hourLabel(b)}"
    }
}

/**
 * The profile's plain-English summary, e.g. "Usually arrives between 5 and
 * 6 pm, mostly at Front gate." Empty when the plate has no history.
 */
fun plateSummary(
    stats: PlateStatsDto,
    cameraName: (String) -> String,
    nowMs: Long,
    firstSeenMs: Long?,
    zone: ZoneId = Time.zone,
): String {
    if (stats.total <= 0) return ""
    fun where(): String {
        val top = stats.cameras.firstOrNull() ?: return ""
        return if (stats.cameras.size == 1 || top.n.toFloat() / stats.total >= 0.6f) {
            ", mostly at ${cameraName(top.cameraId)}"
        } else {
            ", across ${stats.cameras.size} cameras"
        }
    }
    if (stats.isNewPlate()) {
        val today = stats.days30.lastOrNull() ?: stats.total
        val times = if (today == 1) "once" else "$today times"
        val cam = stats.cameras.firstOrNull()?.let { " at ${cameraName(it.cameraId)}" }.orEmpty()
        return "First seen today$cam, $times so far."
    }
    if (stats.total < 3) {
        val first = firstSeenMs?.let { ", first on ${shortDateLabel(it, nowMs, zone)}" }.orEmpty()
        return "Seen ${if (stats.total == 1) "once" else "twice"} before$first${where()}."
    }
    val (h1, n1) = busiestHours(stats.hours, 1)
    val (h3, n3) = busiestHours(stats.hours, 3)
    val whenText = when {
        n1.toFloat() / stats.total >= 0.25f -> "Usually arrives between ${hourRangeLabel(h1, 1)}"
        n3.toFloat() / stats.total >= 0.4f -> "Usually arrives between ${hourRangeLabel(h3, 3)}"
        else -> "Comes and goes at all hours"
    }
    return "$whenText${where()}."
}

// ─── plate correction (admin) ───────────────────────────────────────────────

/** Uppercase ASCII letters and digits only, the way the server stores plates. */
fun normalizePlateInput(s: String): String =
    s.uppercase(Locale.ROOT).filter { it in 'A'..'Z' || it in '0'..'9' }

/**
 * Whether to offer "Correct plate". Writes are admin-only server-side, so a
 * viewer never sees a control that would 403. A blank plate has nothing to correct.
 */
fun canOfferPlateCorrection(isAdmin: Boolean, plate: String): Boolean = isAdmin && plate.isNotBlank()

/**
 * The sentence telling the admin what saving will do, e.g. "GIT2GAB's 12 reads
 * will count as GIF2GAB, and so will future reads of it." Null when [target] is
 * not a usable correction of [from].
 */
fun plateCorrectionEffect(
    from: String,
    target: String,
    reads: Int,
    movingAliases: List<String> = emptyList(),
): String? {
    val to = normalizePlateInput(target)
    if (from.isEmpty() || to.isEmpty() || to == from) return null
    val b = StringBuilder(
        if (reads > 0) {
            "$from's ${readsLabel(reads)} will count as $to, and so will future reads of it."
        } else {
            "Future reads of $from will count as $to."
        },
    )
    if (movingAliases.isNotEmpty()) {
        b.append(" ")
        b.append(if (movingAliases.size == 1) "Its known misread" else "Its known misreads")
        b.append(" ${movingAliases.joinToString(", ")} will move to $to too.")
    }
    return b.toString()
}

/** How far a suggestion is from the misread, in words. */
fun plateSuggestionDistanceLabel(distance: Int): String = when (distance) {
    0 -> "look-alike characters"
    1 -> "1 character off"
    else -> "$distance characters off"
}

/**
 * [read] shown as [plate]: the same read after its plate was corrected, so a
 * profile open on the misread can move to the real plate before the reload
 * lands. The name is dropped because it belonged to the old plate string.
 */
fun plateReadAs(read: PlateRead, plate: String): PlateRead = read.copy(plate = plate, displayName = null)
