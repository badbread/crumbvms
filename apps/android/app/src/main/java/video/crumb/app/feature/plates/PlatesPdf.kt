// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color as AndroidColor
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.drawable.BitmapDrawable
import android.graphics.pdf.PdfDocument
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
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt

/**
 * Renders a single plate read to an OpenALPR-style **single-plate report** PDF —
 * one sighting, forensically framed — using Android's built-in [PdfDocument] (no
 * third-party PDF dependency).
 *
 * Layout (one A4 portrait page):
 *  - **Forensic header**: server host, exported-by, export timestamp, a random
 *    report id, and the operator's Case #/description.
 *  - **Watchlist/BOLO banner** (red) when the plate matches a `kind:"watch"`
 *    entry from `GET /lpr/watchlist`.
 *  - **Header block**: the plate (large monospace), confidence, the date+time in
 *    the operator-chosen timezone, and the camera name.
 *  - **Two images**: a zoomed plate crop (the snapshot cropped to [PlateRead.bbox])
 *    and the full "vehicle" snapshot. When bbox is null / the crop fails, the
 *    first image falls back to the full snapshot, labeled "vehicle".
 *  - **Details**: `plate_raw`, region, source.
 *  - **Dossier** (optional): every sighting of this plate — total, distinct
 *    cameras, first/last seen, and a small thumbnail strip.
 *  - **Footer**: the SHA-256 of each embedded image's bytes, labeled
 *    "tamper-evident".
 *
 * Snapshots are loaded exactly like the on-screen `PlateThumb`: each read's
 * sibling detection-event JPEG via the scoped-token proxy
 * ([MediaUrls.eventSnapshotUrl]), fetched through the shared Coil [ImageLoader]
 * with `allowHardware(false)` so we get a software bitmap to draw + hash.
 *
 * The finished PDF is written to the app-private `reports/` cache subdir (exposed
 * by `res/xml/file_paths.xml`) so [sharePlatesPdf] can hand it to the system
 * share sheet via a scoped `content://` FileProvider Uri — never a token-bearing
 * URL (same posture as the Export share path).
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
    /** Connected server host (from the session base URL). */
    val serverHost: String,
    /** Username that exported the report (from the session / `/auth/me`). */
    val exportedBy: String,
    /** Operator's Case # / free-text description (may be blank). */
    val caseText: String,
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

        // Dossier thumbnail strip (bounded). Skip the primary read's own event to
        // avoid a duplicate of the header image where possible.
        val dossierThumbs: List<Bitmap> = if (input.includeDossier) {
            val out = ArrayList<Bitmap>(MAX_DOSSIER_THUMBS)
            for (d in input.dossier) {
                if (out.size >= MAX_DOSSIER_THUMBS) break
                val bmp = fetchSnapshotBitmap(
                    context, mediaUrls, imageLoader, d.cameraId, d.eventId, DOSSIER_THUMB_TARGET_PX,
                ) ?: continue
                out.add(bmp)
            }
            out
        } else {
            emptyList()
        }

        // Tamper-evident hashes of the exact bytes embedded (each bitmap re-encoded
        // to PNG deterministically). Null when the image is absent.
        val shaPlate = plateImage?.let { sha256Hex(it.toPngBytes()) }
        val shaVehicle = fullSnapshot?.let { sha256Hex(it.toPngBytes()) }

        val reportId = "CR-" + UUID.randomUUID().toString().replace("-", "").take(8).uppercase(Locale.US)
        val tsFmt = DateTimeFormatter
            .ofPattern("EEE, MMM d yyyy · HH:mm:ss z", Locale.US)
            .withZone(input.zoneId)
        val exportedAt = tsFmt.format(Instant.now())

        val doc = PdfDocument()
        try {
            drawReport(
                doc = doc,
                input = input,
                plateImage = plateImage,
                cropIsFallback = cropIsFallback,
                vehicleImage = fullSnapshot,
                dossierThumbs = dossierThumbs,
                shaPlate = shaPlate,
                shaVehicle = shaVehicle,
                reportId = reportId,
                exportedAt = exportedAt,
                tsFmt = tsFmt,
            )
            val dir = File(context.cacheDir, REPORTS_CACHE_SUBDIR).apply { mkdirs() }
            val stamp = android.text.format.DateFormat
                .format("yyyyMMdd_HHmmss", System.currentTimeMillis())
            val plateSlug = read.plate.ifBlank { "plate" }
                .filter { it.isLetterOrDigit() }
                .ifBlank { "plate" }
            val file = File(dir, "crumb-plate-$plateSlug-$stamp.pdf")
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
            dossierThumbs.forEach(owned::add)
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

private fun sha256Hex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

private fun Bitmap.toPngBytes(): ByteArray =
    ByteArrayOutputStream().also { compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()

// ─── drawing ────────────────────────────────────────────────────────────────

private fun drawReport(
    doc: PdfDocument,
    input: PlateReportInput,
    plateImage: Bitmap?,
    cropIsFallback: Boolean,
    vehicleImage: Bitmap?,
    dossierThumbs: List<Bitmap>,
    shaPlate: String?,
    shaVehicle: String?,
    reportId: String,
    exportedAt: String,
    tsFmt: DateTimeFormatter,
) {
    val read = input.read
    val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x10, 0x18, 0x28)
        textSize = 18f
        isFakeBoldText = true
    }
    val idPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x5a, 0x66, 0x78)
        textSize = 10f
        textAlign = Paint.Align.RIGHT
        typeface = android.graphics.Typeface.MONOSPACE
    }
    val metaLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x8a, 0x93, 0xa2)
        textSize = 9f
        isFakeBoldText = true
    }
    val metaPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x33, 0x3b, 0x48)
        textSize = 10f
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

    // ── forensic header ────────────────────────────────────────────────────────
    c.drawText("CrumbVMS — License Plate Report", contentLeft, y, titlePaint)
    c.drawText("REPORT $reportId", contentRight, y, idPaint)
    y += 16f
    fun metaLine(label: String, value: String) {
        c.drawText(label, contentLeft, y, metaLabelPaint)
        c.drawText(value, contentLeft + 78f, y, metaPaint)
        y += 13f
    }
    metaLine("SERVER", input.serverHost.ifBlank { "—" })
    metaLine("EXPORTED BY", input.exportedBy.ifBlank { "—" })
    metaLine("EXPORTED AT", exportedAt)
    metaLine("CASE", input.caseText.ifBlank { "—" })
    y += 4f
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
    detailLine("REGION", read.region?.takeIf { it.isNotBlank() } ?: "—")
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
            // Thumbnail strip (single bounded row).
            if (dossierThumbs.isNotEmpty()) {
                val thumbGap = 8f
                val thumbW = (contentWidth - thumbGap * (MAX_DOSSIER_THUMBS - 1)) / MAX_DOSSIER_THUMBS
                val thumbH = thumbW * 0.62f
                var tx = contentLeft
                for (bmp in dossierThumbs) {
                    drawImageBox(c, bmp, tx, y, thumbW, thumbH, placeholderPaint, placeholderTextPaint)
                    tx += thumbW + thumbGap
                }
                y += thumbH + 8f
            }
        }
    }

    // ── footer: tamper-evident image hashes ─────────────────────────────────────
    val footerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x8a, 0x93, 0xa2)
        textSize = 7.5f
        typeface = android.graphics.Typeface.MONOSPACE
    }
    val footerLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.rgb(0x5a, 0x66, 0x78)
        textSize = 8f
        isFakeBoldText = true
    }
    var fy = PAGE_H - MARGIN - 26f
    c.drawLine(contentLeft, fy - 8f, contentRight, fy - 8f, linePaint)
    c.drawText("TAMPER-EVIDENT — SHA-256 of each embedded image", contentLeft, fy, footerLabelPaint)
    fy += 11f
    c.drawText("plate:   ${shaPlate ?: "(no image)"}", contentLeft, fy, footerPaint)
    fy += 10f
    c.drawText("vehicle: ${shaVehicle ?: "(no image)"}", contentLeft, fy, footerPaint)

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

/** Uppercase ASCII-alphanumeric normalization — identical to the server's `normalize_plate`. */
private fun normalizePlate(s: String): String =
    buildString {
        for (c in s) if (c in '0'..'9' || c in 'a'..'z' || c in 'A'..'Z') append(c.uppercaseChar())
    }

/** Edit budget `floor(fuzz.clamp(0,0.5) · len(reference))` — matches the server. */
private fun allowedEdits(reference: String, fuzz: Float): Int =
    (fuzz.coerceIn(0f, 0.5f) * reference.length).toInt()

/** Classic two-row Levenshtein edit distance (plates are short). */
private fun levenshtein(a: String, b: String): Int {
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
