// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color as AndroidColor
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.drawable.BitmapDrawable
import android.graphics.pdf.PdfDocument
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import coil.ImageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import video.crumb.app.data.MediaUrls
import video.crumb.app.data.PlateRead
import video.crumb.app.data.PlateWatchlistEntry
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Renders a single plate read to a **single-plate report** PDF using Android's
 * built-in [PdfDocument] (no third-party PDF dependency).
 *
 * Layout (one A4 portrait page):
 *  - **Title** + divider.
 *  - **Watchlist/BOLO banner** (red) when the plate matches a `kind:"watch"`
 *    entry from `GET /lpr/watchlist`.
 *  - **Header block**: the plate (large monospace), confidence, the date+time in
 *    the operator-chosen timezone, and the camera name.
 *  - **Two images**: a zoomed plate crop (the snapshot cropped to [PlateRead.bbox])
 *    and the full "vehicle" snapshot. When bbox is null / the crop fails, the
 *    first image falls back to the full snapshot, labeled "vehicle".
 *  - **Details**: `plate_raw`, source.
 *  - **Dossier** (optional): every sighting of this plate — total, distinct
 *    cameras, first/last seen, and a thumbnail strip captioned with each
 *    sighting's date/time.
 *
 * Snapshots are loaded exactly like the on-screen `PlateThumb`: each read's
 * sibling detection-event JPEG via the scoped-token proxy
 * ([MediaUrls.eventSnapshotUrl]), fetched through the shared Coil [ImageLoader]
 * with `allowHardware(false)` so we get a software bitmap to draw.
 *
 * The finished PDF is written to the app-private `reports/` cache subdir (exposed
 * by `res/xml/file_paths.xml`). From there the operator is offered three
 * deliveries: [openPlatesPdf] (view it now in the device PDF viewer),
 * [savePlateReportToDownloads] (a durable copy in the public Downloads folder,
 * findable in the Files app), and [sharePlatesPdf] (the system share sheet). The
 * open/share paths hand out a scoped `content://` FileProvider Uri — never a
 * `file://` Uri or a token-bearing URL (same posture as the Export screen).
 */

/** A4 portrait at 72 dpi (points). */
private const val PAGE_W = 595
private const val PAGE_H = 842
private const val MARGIN = 36f

/** Cap on dossier thumbnail-strip fetches, to keep a share tap responsive and
 *  the strip to a single row within the content width. */
private const val MAX_DOSSIER_THUMBS = 6

/**
 * Peak-memory guard (#147-1). Camera snapshots can be 1080p/4K; decoding several
 * at full resolution and holding them all at once (primary + crop + up to
 * [MAX_DOSSIER_THUMBS] thumbs) risks OOM on a share tap. We ask Coil to downsample
 * each fetch to a bounded box: the primary/vehicle image is drawn into a ~150 pt
 * A4 box (and cropped for the zoomed plate), so ~1400 px is ample; the dossier
 * thumbs render tiny, so ~400 px is plenty. Report fetches also disable Coil's
 * memory cache so the decoded bitmaps are exclusively ours to recycle after the
 * PDF is written — never the shared instances the on-screen thumbnails use.
 */
private const val REPORT_IMAGE_TARGET_PX = 1400
private const val DOSSIER_THUMB_TARGET_PX = 400

/** Subdirectory of the app cache dir that `file_paths.xml` exposes via FileProvider. */
private const val REPORTS_CACHE_SUBDIR = "reports"

/**
 * Everything the report needs about one sighting. The network reads (watchlist
 * match + dossier) are resolved by the caller (the Plates screen) so this builder
 * stays a focused render step: it only performs the image fetches it must decode
 * itself, then draws.
 */
data class PlateReportInput(
    /** The sighting the report is about. */
    val read: PlateRead,
    /** Camera id → display name (resolves both the primary camera and dossier cameras). */
    val cameraNames: Map<String, String>,
    /** Timezone the timestamps are rendered in (defaults to device-local at the call site). */
    val zoneId: ZoneId,
    /** Whether to render the sighting-history dossier section. */
    val includeDossier: Boolean,
    /** The matching `kind:"watch"` watchlist entry, or null — drives the BOLO banner. */
    val watchMatch: PlateWatchlistEntry?,
    /** All sightings of this plate (up to the query limit), newest-first. Empty when
     *  the dossier is disabled or the plate is blank. */
    val dossier: List<PlateRead>,
    /** Server-reported total match count for the dossier query (may exceed `dossier.size`). */
    val dossierTotal: Int,
)

/** One sighting-history thumbnail: the decoded image paired with that sighting's
 *  timestamp (ISO), so the strip can caption each thumbnail with its date/time. */
private class DossierThumb(val bitmap: Bitmap, val ts: String)

/**
 * Build the single-plate report PDF for [input]. Returns the written [File] on
 * success. Runs entirely off the main thread.
 */
suspend fun generatePlateReportPdf(
    context: Context,
    input: PlateReportInput,
    mediaUrls: MediaUrls,
    imageLoader: ImageLoader,
): Result<File> = withContext(Dispatchers.IO) {
    runCatching {
        val read = input.read

        // Full "vehicle" snapshot for the primary read (may be null: no event, or
        // a fetch miss → placeholder + full-snapshot fallback for the crop).
        val fullSnapshot = fetchSnapshotBitmap(
            context, mediaUrls, imageLoader, read.cameraId, read.eventId, REPORT_IMAGE_TARGET_PX,
        )

        // Zoomed plate crop from bbox; null bbox / crop failure → reuse the full
        // snapshot (labeled "vehicle" downstream).
        val crop = fullSnapshot?.let { cropToBbox(it, read.bbox) }
        val cropIsFallback = crop == null
        val plateImage = crop ?: fullSnapshot

        // Dossier thumbnail strip (bounded). Each thumb keeps its sighting's
        // timestamp so the strip can caption it with a date/time (captions stay
        // aligned even when a fetch is skipped, since ts travels with the image).
        val dossierThumbs: List<DossierThumb> = if (input.includeDossier) {
            val out = ArrayList<DossierThumb>(MAX_DOSSIER_THUMBS)
            for (d in input.dossier) {
                if (out.size >= MAX_DOSSIER_THUMBS) break
                val bmp = fetchSnapshotBitmap(
                    context, mediaUrls, imageLoader, d.cameraId, d.eventId, DOSSIER_THUMB_TARGET_PX,
                ) ?: continue
                out.add(DossierThumb(bmp, d.ts))
            }
            out
        } else {
            emptyList()
        }

        val tsFmt = DateTimeFormatter
            .ofPattern("EEE, MMM d yyyy · HH:mm:ss z", Locale.US)
            .withZone(input.zoneId)

        val doc = PdfDocument()
        try {
            drawReport(
                doc = doc,
                input = input,
                plateImage = plateImage,
                cropIsFallback = cropIsFallback,
                vehicleImage = fullSnapshot,
                dossierThumbs = dossierThumbs,
                tsFmt = tsFmt,
            )
            val dir = File(context.cacheDir, REPORTS_CACHE_SUBDIR).apply { mkdirs() }
            val stamp = android.text.format.DateFormat
                .format("yyyyMMdd_HHmmss", System.currentTimeMillis())
                .toString()
            val file = File(dir, plateReportFileName(read.plate, stamp))
            FileOutputStream(file).use { out -> doc.writeTo(out) }
            file
        } finally {
            doc.close()
            // The PDF bytes are now fully written, so the source bitmaps can go.
            // We own them (report fetches disable Coil's memory cache), so recycling
            // frees memory immediately without touching the on-screen thumbnails'
            // cached copies. A LinkedHashSet de-dupes the crop-is-fallback case where
            // plateImage === fullSnapshot, so nothing is recycled twice.
            val owned = LinkedHashSet<Bitmap>()
            fullSnapshot?.let(owned::add)
            plateImage?.let(owned::add)
            dossierThumbs.forEach { owned.add(it.bitmap) }
            owned.forEach { runCatching { it.recycle() } }
        }
    }
}

/**
 * Fetch a read's sibling detection-event snapshot as a software [Bitmap]
 * downsampled to a [targetPx]-bounded box, or null.
 *
 * The memory cache is DISABLED so the returned bitmap is decoded fresh and owned
 * solely by the caller (safe to recycle after the PDF is written) rather than the
 * shared instance the on-screen thumbnails render; the disk cache stays on for a
 * fast re-fetch. [targetPx] bounds peak memory (see [REPORT_IMAGE_TARGET_PX]).
 */
private suspend fun fetchSnapshotBitmap(
    context: Context,
    mediaUrls: MediaUrls,
    imageLoader: ImageLoader,
    cameraId: String,
    eventId: String?,
    targetPx: Int,
): Bitmap? {
    if (eventId.isNullOrBlank()) return null
    val url = runCatching { mediaUrls.eventSnapshotUrl(cameraId, eventId) }.getOrNull() ?: return null
    val req = ImageRequest.Builder(context)
        .data(url)
        .size(targetPx) // downsample to a bounded box → guards against OOM
        .allowHardware(false) // need a software bitmap to draw into the PDF canvas + hash
        .memoryCachePolicy(CachePolicy.DISABLED)
        .diskCachePolicy(CachePolicy.ENABLED)
        .build()
    return (imageLoader.execute(req) as? SuccessResult)
        ?.let { it.drawable as? BitmapDrawable }
        ?.bitmap
}

/**
 * Crop [src] to the normalized `[x, y, w, h]` (0..1 fractions of width/height)
 * [bbox], reusing the shared [bboxToRect] geometry (same math the on-screen
 * thumbnails crop with). Returns null when bbox is absent/malformed or the crop
 * can't be made, so the caller falls back to the full snapshot.
 */
private fun cropToBbox(src: Bitmap, bbox: List<Double>?): Bitmap? {
    val rect = bboxToRect(bbox, src.width, src.height) ?: return null
    return runCatching {
        Bitmap.createBitmap(src, rect.left, rect.top, rect.width(), rect.height())
    }.getOrNull()
}

// ─── drawing ────────────────────────────────────────────────────────────────

private fun drawReport(
    doc: PdfDocument,
    input: PlateReportInput,
    plateImage: Bitmap?,
    cropIsFallback: Boolean,
    vehicleImage: Bitmap?,
    dossierThumbs: List<DossierThumb>,
    tsFmt: DateTimeFormatter,
) {
    val read = input.read
    val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x10, 0x18, 0x28)
        textSize = 18f
        isFakeBoldText = true
    }
    val metaLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x8a, 0x93, 0xa2)
        textSize = 9f
        isFakeBoldText = true
    }
    val headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x5a, 0x66, 0x78)
        textSize = 9f
        isFakeBoldText = true
    }
    val platePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x10, 0x18, 0x28)
        textSize = 34f
        isFakeBoldText = true
        typeface = android.graphics.Typeface.MONOSPACE
    }
    val cellPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x33, 0x3b, 0x48)
        textSize = 11f
    }
    val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0xd8, 0xdd, 0xe4)
        strokeWidth = 0.6f
    }
    val placeholderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0xec, 0xee, 0xf1)
        style = Paint.Style.FILL
    }
    val placeholderTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x8a, 0x93, 0xa2)
        textSize = 10f
        textAlign = Paint.Align.CENTER
    }
    val bannerBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0xC2, 0x2B, 0x2B)
        style = Paint.Style.FILL
    }
    val bannerTitlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.WHITE
        textSize = 13f
        isFakeBoldText = true
    }
    val bannerBodyPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0xFF, 0xE4, 0xE4)
        textSize = 10f
    }

    val contentLeft = MARGIN
    val contentRight = PAGE_W - MARGIN
    val contentWidth = contentRight - contentLeft

    val info = PdfDocument.PageInfo.Builder(PAGE_W, PAGE_H, 1).create()
    val page = doc.startPage(info)
    val c = page.canvas

    var y = MARGIN + 6f

    // ── header ──────────────────────────────────────────────────────────────────
    c.drawText("CrumbVMS — License Plate Report", contentLeft, y, titlePaint)
    y += 14f
    c.drawLine(contentLeft, y, contentRight, y, linePaint)
    y += 14f

    // ── watchlist / BOLO banner ─────────────────────────────────────────────────
    if (input.watchMatch != null) {
        val bannerH = 40f
        c.drawRect(contentLeft, y, contentRight, y + bannerH, bannerBgPaint)
        val label = input.watchMatch.label?.takeIf { it.isNotBlank() }
        val title = "⚠ WATCHLIST / BOLO" + (label?.let { " — $it" } ?: "")
        c.drawText(title, contentLeft + 10f, y + 17f, bannerTitlePaint)
        val note = input.watchMatch.note?.takeIf { it.isNotBlank() } ?: "This plate is on the alert watchlist."
        c.drawText(note.take(90), contentLeft + 10f, y + 32f, bannerBodyPaint)
        y += bannerH + 14f
    }

    // ── header block (plate + key facts) ────────────────────────────────────────
    val plateText = read.plate.ifBlank { "—" }
    c.drawText(plateText, contentLeft, y + 26f, platePaint)
    // Right-aligned confidence beside the big plate.
    val confPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x5a, 0x66, 0x78)
        textSize = 12f
        textAlign = Paint.Align.RIGHT
    }
    c.drawText("Confidence ${confidenceLabel(read.confidence)}", contentRight, y + 14f, confPaint)
    y += 34f
    val cameraName = input.cameraNames[read.cameraId] ?: "(unknown camera)"
    c.drawText(fmtTs(read.ts, tsFmt), contentLeft, y, cellPaint)
    y += 14f
    c.drawText("Camera: $cameraName", contentLeft, y, cellPaint)
    y += 16f

    // ── two images ──────────────────────────────────────────────────────────────
    val gap = 16f
    val boxW = (contentWidth - gap) / 2f
    val boxH = 150f
    val plateLabel = if (cropIsFallback) "VEHICLE (no plate box)" else "PLATE (zoomed)"
    c.drawText(plateLabel, contentLeft, y, headerPaint)
    c.drawText("VEHICLE", contentLeft + boxW + gap, y, headerPaint)
    y += 6f
    drawImageBox(c, plateImage, contentLeft, y, boxW, boxH, placeholderPaint, placeholderTextPaint)
    drawImageBox(c, vehicleImage, contentLeft + boxW + gap, y, boxW, boxH, placeholderPaint, placeholderTextPaint)
    y += boxH + 16f

    // ── details ───────────────────────────────────────────────────────────────
    c.drawText("DETAILS", contentLeft, y, headerPaint)
    y += 14f
    fun detailLine(label: String, value: String) {
        c.drawText(label, contentLeft, y, metaLabelPaint)
        c.drawText(value, contentLeft + 78f, y, cellPaint)
        y += 14f
    }
    detailLine("PLATE RAW", read.plateRaw.ifBlank { "—" })
    detailLine("SOURCE", read.sourceId?.takeIf { it.isNotBlank() } ?: "—")
    y += 6f

    // ── dossier ─────────────────────────────────────────────────────────────────
    if (input.includeDossier) {
        c.drawLine(contentLeft, y, contentRight, y, linePaint)
        y += 14f
        c.drawText("SIGHTING HISTORY", contentLeft, y, headerPaint)
        y += 14f
        val sightings = input.dossier
        if (sightings.isEmpty()) {
            c.drawText("No other sightings of this plate in the selected cameras.", contentLeft, y, cellPaint)
            y += 14f
        } else {
            val distinctCams = sightings.map { it.cameraId }.distinct().size
            val sortedTs = sightings.map { it.ts }.sortedBy {
                runCatching { Instant.parse(it).toEpochMilli() }.getOrDefault(Long.MAX_VALUE)
            }
            val firstSeen = sortedTs.firstOrNull()?.let { fmtTs(it, tsFmt) } ?: "—"
            val lastSeen = sortedTs.lastOrNull()?.let { fmtTs(it, tsFmt) } ?: "—"
            val totalLabel = if (input.dossierTotal > sightings.size) {
                "${input.dossierTotal} sightings (showing ${sightings.size})"
            } else {
                "${sightings.size} sighting${if (sightings.size == 1) "" else "s"}"
            }
            c.drawText("$totalLabel · $distinctCams camera${if (distinctCams == 1) "" else "s"}", contentLeft, y, cellPaint)
            y += 14f
            c.drawText("First seen $firstSeen", contentLeft, y, cellPaint)
            y += 14f
            c.drawText("Last seen  $lastSeen", contentLeft, y, cellPaint)
            y += 16f
            // Thumbnail strip (single bounded row), each captioned with its
            // sighting's date/time in the report's timezone.
            if (dossierThumbs.isNotEmpty()) {
                val thumbTsFmt = DateTimeFormatter
                    .ofPattern("MMM d, HH:mm", Locale.US)
                    .withZone(input.zoneId)
                val thumbCapPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = AndroidColor.rgb(0x5a, 0x66, 0x78)
                    textSize = 6.5f
                    textAlign = Paint.Align.CENTER
                }
                val thumbGap = 8f
                val thumbW = (contentWidth - thumbGap * (MAX_DOSSIER_THUMBS - 1)) / MAX_DOSSIER_THUMBS
                val thumbH = thumbW * 0.62f
                var tx = contentLeft
                for (t in dossierThumbs) {
                    drawImageBox(c, t.bitmap, tx, y, thumbW, thumbH, placeholderPaint, placeholderTextPaint)
                    c.drawText(fmtTs(t.ts, thumbTsFmt), tx + thumbW / 2f, y + thumbH + 9f, thumbCapPaint)
                    tx += thumbW + thumbGap
                }
                y += thumbH + 8f + 11f
            }
        }
    }

    doc.finishPage(page)
}

/** Draw [bmp] fit (aspect-preserved, centered) inside the box, on a placeholder
 *  background; when null, draw the placeholder with a "no image" caption. */
private fun drawImageBox(
    c: Canvas,
    bmp: Bitmap?,
    left: Float,
    top: Float,
    boxW: Float,
    boxH: Float,
    bg: Paint,
    placeholderText: Paint,
) {
    c.drawRect(left, top, left + boxW, top + boxH, bg)
    if (bmp == null) {
        c.drawText("no image", left + boxW / 2f, top + boxH / 2f + 4f, placeholderText)
        return
    }
    val scale = minOf(boxW / bmp.width, boxH / bmp.height)
    val dw = bmp.width * scale
    val dh = bmp.height * scale
    val dx = left + (boxW - dw) / 2f
    val dy = top + (boxH - dh) / 2f
    val dst = Rect(dx.roundToInt(), dy.roundToInt(), (dx + dw).roundToInt(), (dy + dh).roundToInt())
    c.drawBitmap(bmp, null, dst, null)
}

private fun fmtTs(iso: String, fmt: DateTimeFormatter): String =
    runCatching { fmt.format(Instant.parse(iso)) }.getOrDefault(iso)

private fun confidenceLabel(confidence: Float?): String =
    if (confidence == null) "—" else "${(confidence * 100).roundToInt()}%"

// ─── watchlist / BOLO match (mirrors the server's fuzzy matcher) ──────────────

/**
 * Resolve the watchlist ("BOLO") entry a [plate] matches, so the report banner
 * fires for FUZZY-alerted plates too — not only exact hits (#147-4). Replicates
 * the server's `match_watchlist` exactly (`services/common/src/db.rs`): a read
 * matches a `kind:"watch"` entry when the Levenshtein distance between their
 * normalized forms is within `floor(fuzz · len)` edits, where `len` is the
 * entry's normalized length and `fuzz` is clamped to `0.0..0.5`. Among all
 * matches it returns the closest by edit distance (ties → first), matching the
 * server's "closest wins" tie-break. `fuzz == 0` collapses to an exact
 * (post-normalize) match — the historical behavior — so a caller that can't read
 * the (admin-only) LPR config simply passes `0f` and loses nothing.
 *
 * Ignore entries never raise a banner, so they are skipped here.
 */
fun matchWatchlistBolo(
    plate: String,
    entries: List<PlateWatchlistEntry>,
    fuzz: Float,
): PlateWatchlistEntry? {
    val read = normalizePlate(plate)
    if (read.isEmpty()) return null
    var best: PlateWatchlistEntry? = null
    var bestDist = Int.MAX_VALUE
    for (entry in entries) {
        if (entry.isIgnore) continue
        val ref = normalizePlate(entry.plate)
        if (ref.isEmpty()) continue
        val dist = levenshtein(read, ref)
        if (dist <= allowedEdits(ref, fuzz) && dist < bestDist) {
            best = entry
            bestDist = dist
            if (dist == 0) break // an exact match can't be beaten
        }
    }
    return best
}

/** Uppercase ASCII-alphanumeric normalization — identical to the server's `normalize_plate`.
 *  `internal` so the watchlist fuzziness preview ([acceptedMisreadExamples]) reuses the
 *  exact same normalization the server matcher uses, keeping the preview truthful. */
internal fun normalizePlate(s: String): String =
    buildString {
        for (c in s) if (c in '0'..'9' || c in 'a'..'z' || c in 'A'..'Z') append(c.uppercaseChar())
    }

/** Edit budget `floor(fuzz.clamp(0,0.5) · len(reference))` — matches the server
 *  (`allowed_edits` in `services/common/src/db.rs`). [reference] must already be
 *  normalized. `internal` so the fuzziness-preview slider shares this exact rule. */
internal fun allowedEdits(reference: String, fuzz: Float): Int =
    (fuzz.coerceIn(0f, 0.5f) * reference.length).toInt()

/** Classic two-row Levenshtein edit distance (plates are short). */
internal fun levenshtein(a: String, b: String): Int {
    if (a.isEmpty()) return b.length
    if (b.isEmpty()) return a.length
    var prev = IntArray(b.length + 1) { it }
    var curr = IntArray(b.length + 1)
    for (i in a.indices) {
        curr[0] = i + 1
        for (j in b.indices) {
            val cost = if (a[i] == b[j]) 0 else 1
            curr[j + 1] = minOf(prev[j + 1] + 1, curr[j] + 1, prev[j] + cost)
        }
        val tmp = prev; prev = curr; curr = tmp
    }
    return prev[b.length]
}

// ─── fuzzy-match preview model (mirrors the desktop + admin console) ──────────
//
// The watchlist match tolerance is *character edit distance* — a read matches an
// entry when `levenshtein(normalize(read), normalize(entry)) <= allowedEdits`. To
// make the admin fuzziness slider mean something concrete, the preview generates a
// few plausible OCR misreads of the plate being typed that the CURRENT tolerance
// would still accept — each verified by the very same edit-distance rule the
// server uses, so the preview never over-promises. Ported verbatim from the
// desktop Dart (`plates_screen.dart`) and the admin console JS (`admin.html`).

/** Common ALPR character confusions (the pairs Frigate's OCR most often swaps). */
internal val OCR_CONFUSIONS: Map<Char, Char> = mapOf(
    '0' to 'O', 'O' to '0', '1' to 'I', 'I' to '1', 'L' to '1', '2' to 'Z', 'Z' to '2',
    '5' to 'S', 'S' to '5', '8' to 'B', 'B' to '8', '6' to 'G', 'G' to '6', '4' to 'A',
    'A' to '4', 'D' to '0', 'Q' to 'O', '7' to 'T',
)

/**
 * A few realistic misreads of [plate] that the server WOULD accept at the given
 * [allowed] tolerance — one/two OCR-confusion substitutions, each verified by the
 * same edit-distance rule the server uses. Returns an empty list when tolerance is
 * 0 (exact only) or the plate normalizes to empty. Mirrors the desktop's
 * `_acceptedMisreadExamples`.
 */
internal fun acceptedMisreadExamples(plate: String, allowed: Int): List<String> {
    val norm = normalizePlate(plate)
    if (norm.isEmpty() || allowed <= 0) return emptyList()
    val out = mutableListOf<String>()
    // Distance-1 variants first: swap one confusable character.
    var i = 0
    while (i < norm.length && out.size < 4) {
        val rep = OCR_CONFUSIONS[norm[i]]
        if (rep != null) {
            val cand = norm.substring(0, i) + rep + norm.substring(i + 1)
            if (cand != norm && cand !in out && levenshtein(cand, norm) <= allowed) out.add(cand)
        }
        i++
    }
    // If two edits are allowed, add a couple of double-swaps to show the range.
    if (allowed >= 2) {
        i = 0
        while (i < norm.length && out.size < 4) {
            val r1 = OCR_CONFUSIONS[norm[i]]
            if (r1 != null) {
                var j = i + 1
                while (j < norm.length && out.size < 4) {
                    val r2 = OCR_CONFUSIONS[norm[j]]
                    if (r2 != null) {
                        val cand = norm.substring(0, i) + r1 +
                            norm.substring(i + 1, j) + r2 + norm.substring(j + 1)
                        if (cand != norm && cand !in out && levenshtein(cand, norm) <= allowed) out.add(cand)
                    }
                    j++
                }
            }
            i++
        }
    }
    return out
}

// ─── report filenames (pure, unit-testable) ──────────────────────────────────

/**
 * Sanitize a plate string into a filesystem-safe slug for report filenames:
 * ASCII letters/digits only (drops spaces, punctuation, and any non-alphanumeric
 * characters that could break a path or MediaStore display name), falling back to
 * `"plate"` when the plate is blank or has no usable characters (older reads / a
 * no-text detection). Pure so it can be unit-tested without a device.
 */
internal fun sanitizePlateForFilename(plate: String): String =
    plate.filter { it.isLetterOrDigit() }.ifBlank { "plate" }

/**
 * Assemble the report's on-disk filename: `crumb-plate-<slug>-<stamp>.pdf`, where
 * [stamp] is a caller-formatted timestamp (e.g. `yyyyMMdd_HHmmss`) that makes
 * repeated exports collision-safe. Kept pure (the timestamp is passed in, not read
 * from the clock) so the naming is unit-testable. Used both for the cache copy the
 * report is rendered into and, reused verbatim, for the Downloads copy.
 */
internal fun plateReportFileName(plate: String, stamp: String): String =
    "crumb-plate-${sanitizePlateForFilename(plate)}-$stamp.pdf"

// ─── delivery: open / save / share ────────────────────────────────────────────

/** Sub-folder created under the device Downloads dir for saved plate reports —
 *  same convention as the Export screen's Downloads save (`ExportScreen.kt`). */
private const val REPORT_DOWNLOAD_SUBDIR = "CrumbVMS"

/**
 * Open a generated report PDF in the device's default PDF viewer via
 * `ACTION_VIEW`, using the SAME scoped `content://` FileProvider Uri as the share
 * path (read permission granted to the viewer only, for this file only — never a
 * `file://` Uri, and never a token-bearing URL). This is the "I just want to view
 * it on my phone" path.
 *
 * Returns `true` when a viewer was launched, `false` when no app can view a PDF
 * (`ActivityNotFoundException`) so the caller can surface a clear "no PDF viewer
 * installed" message instead of crashing on a minimal device with no PDF app.
 */
fun openPlatesPdf(context: Context, file: File): Boolean =
    try {
        val authority = "${context.packageName}.fileprovider"
        val uri = FileProvider.getUriForFile(context, authority, file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/pdf")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(intent)
        true
    } catch (e: android.content.ActivityNotFoundException) {
        false
    }

/**
 * Save a durable copy of a generated report PDF to the device's **public
 * Downloads** collection so the operator can find it in the Files app (unlike the
 * app-private cache the report is rendered into, which is invisible to Files and
 * is pruned by [video.crumb.app.data.CacheJanitor]). Mirrors the Export screen's
 * Downloads save exactly:
 * - API 29+ (scoped storage): inserts into [MediaStore.Downloads] under
 *   `Downloads/CrumbVMS/`, `IS_PENDING` until the copy finishes. **No storage
 *   permission required** — this is the path a modern phone (e.g. a Galaxy S24 on
 *   API 34) takes.
 * - API ≤ 28: writes to the public Downloads dir directly, which needs the legacy
 *   `WRITE_EXTERNAL_STORAGE` permission already declared (`maxSdkVersion=28`). If
 *   that isn't granted the copy throws and surfaces as a normal save failure.
 *
 * Reuses the cache file's already-collision-safe name (`crumb-plate-…-<stamp>.pdf`)
 * so the saved copy matches; MediaStore additionally de-dupes a colliding display
 * name, and the legacy path guards with [uniqueLegacyFile]. Returns the
 * user-visible saved location on success. Runs off the main thread.
 */
suspend fun savePlateReportToDownloads(context: Context, file: File): Result<String> =
    withContext(Dispatchers.IO) {
        runCatching {
            val fileName = file.name
            file.inputStream().use { input ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    writeReportToMediaStoreDownloads(context, fileName, input)
                } else {
                    writeReportToLegacyDownloads(fileName, input)
                }
            }
        }
    }

/**
 * API 29+ path: stream [input] into a new [MediaStore.Downloads] entry under
 * `Downloads/CrumbVMS/`. Uses `IS_PENDING` so the file isn't visible to other apps
 * until the copy completes, and rolls the entry back if the copy fails so no
 * 0-byte ghost is left behind. Returns the user-visible location. (Same shape as
 * `ExportScreen.writeToMediaStoreDownloads`, with a PDF mime type.)
 */
@RequiresApi(Build.VERSION_CODES.Q)
private fun writeReportToMediaStoreDownloads(
    context: Context,
    fileName: String,
    input: InputStream,
): String {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
        put(MediaStore.Downloads.DISPLAY_NAME, fileName)
        put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
        put(
            MediaStore.Downloads.RELATIVE_PATH,
            Environment.DIRECTORY_DOWNLOADS + "/" + REPORT_DOWNLOAD_SUBDIR,
        )
        put(MediaStore.Downloads.IS_PENDING, 1)
    }
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        ?: error("Could not create a Downloads entry")
    try {
        resolver.openOutputStream(uri)?.use { out -> input.copyTo(out) }
            ?: error("Could not open the Downloads output stream")
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    } catch (t: Throwable) {
        runCatching { resolver.delete(uri, null, null) }
        throw t
    }
    return "Downloads/$REPORT_DOWNLOAD_SUBDIR/$fileName"
}

/**
 * API ≤ 28 path: write [input] to the public Downloads dir directly (needs the
 * legacy `WRITE_EXTERNAL_STORAGE` permission declared for `maxSdkVersion=28`).
 * Guards against clobbering an existing file with [uniqueLegacyFile]. Returns the
 * user-visible location.
 */
@Suppress("DEPRECATION")
private fun writeReportToLegacyDownloads(fileName: String, input: InputStream): String {
    val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    val dir = File(downloads, REPORT_DOWNLOAD_SUBDIR).apply { mkdirs() }
    val dest = uniqueLegacyFile(dir, fileName)
    dest.outputStream().use { out -> input.copyTo(out) }
    return "Downloads/$REPORT_DOWNLOAD_SUBDIR/${dest.name}"
}

/**
 * Resolve a non-colliding [File] in [dir] for [fileName]: returns it as-is if free,
 * else inserts a ` (1)`, ` (2)`, … suffix before the extension (the same disambig
 * scheme MediaStore uses on API 29+, applied by hand for the legacy path so a
 * repeated save never silently overwrites an earlier report). Pure given the
 * filesystem state, so it's unit-testable against a temp dir.
 */
internal fun uniqueLegacyFile(dir: File, fileName: String): File {
    val first = File(dir, fileName)
    if (!first.exists()) return first
    val dot = fileName.lastIndexOf('.')
    val base = if (dot > 0) fileName.substring(0, dot) else fileName
    val ext = if (dot > 0) fileName.substring(dot) else ""
    var n = 1
    while (true) {
        val candidate = File(dir, "$base ($n)$ext")
        if (!candidate.exists()) return candidate
        n++
    }
}

// ─── share ──────────────────────────────────────────────────────────────────

/**
 * Share a generated report PDF via the system share sheet, using a scoped
 * `content://` FileProvider Uri (read permission granted to the receiving app
 * only) — mirrors the Export screen's `shareLocalFile`.
 */
fun sharePlatesPdf(context: Context, file: File) {
    try {
        val authority = "${context.packageName}.fileprovider"
        val uri = FileProvider.getUriForFile(context, authority, file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "application/pdf"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_SUBJECT, "CrumbVMS Plate Report")
        }
        context.startActivity(Intent.createChooser(intent, "Share plate report"))
    } catch (e: android.content.ActivityNotFoundException) {
        android.widget.Toast
            .makeText(context, "No app available to share", android.widget.Toast.LENGTH_SHORT)
            .show()
    }
}
