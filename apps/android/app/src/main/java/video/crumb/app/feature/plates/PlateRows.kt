// SPDX-License-Identifier: AGPL-3.0-or-later

@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package video.crumb.app.feature.plates

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil.compose.AsyncImage
import coil.request.ImageRequest
import video.crumb.app.data.MediaUrls
import video.crumb.app.data.PlateRead
import video.crumb.app.ui.theme.JetBrainsMono
import video.crumb.app.ui.theme.LprAccentChip
import video.crumb.app.ui.theme.LprAccentHot
import video.crumb.app.ui.theme.LprWatchAmber
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary
import kotlin.math.roundToInt

/*
 * Rows, cards and the long-press peek for the Plates tab (2A "two-line row,
 * no icons; long-press for actions"). Nothing on a row competes with the plate:
 * the aspect-true crop and the plate text are the only strong elements, the
 * known name sits beside the plate in the accent colour, everything else is
 * slate.
 */

/** Everything a row, card or peek needs about one read (resolved by the screen). */
data class PlateRowData(
    val read: PlateRead,
    val cameraName: String,
    val watched: Boolean,
    val rail: PlateRail,
    val isNew: Boolean,
    /** Raw reads merged into this row (1 when merging is off). */
    val passCount: Int = 1,
)

/** Confidence below this is drawn amber; a high number is just a quiet number. */
private const val LOW_CONFIDENCE = 0.8f

/** Decode ceiling for plate crops: the snapshot decodes to ~1024 px first, so a tiny crop stays sharp. */
private const val CROP_DECODE_PX = 1024

/** Bigger decode for the enlarged peek and profile crops. */
private const val CROP_DECODE_PX_LARGE = 2048

// ─── crop aspect memory ─────────────────────────────────────────────────────

/**
 * Remembers each crop's true aspect once it has decoded, so a row scrolling
 * back into view lays out at its final size on the first frame instead of
 * jumping from the estimate.
 */
internal object CropAspectCache {
    private val map = object : LinkedHashMap<String, Float>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Float>?): Boolean = size > 600
    }

    @Synchronized
    fun get(key: String): Float? = map[key]

    @Synchronized
    fun put(key: String, aspect: Float) {
        map[key] = aspect
    }
}

/** The scoped-token URL of the read's detection snapshot, or null while resolving / when it has none. */
@Composable
internal fun rememberSnapshotUrl(read: PlateRead, mediaUrls: MediaUrls): String? {
    var url by remember(read.id) { mutableStateOf<String?>(null) }
    val eventId = read.eventId
    LaunchedEffect(read.id) {
        url = if (!eventId.isNullOrBlank()) {
            runCatching { mediaUrls.eventSnapshotUrl(read.cameraId, eventId) }.getOrNull()
        } else {
            null
        }
    }
    return url
}

/**
 * The plate crop at its REAL aspect, inside a [slotW] x [slotH] slot: it fills
 * the slot by width and only gets shorter, never padded with a black box. A US
 * plate is 2:1, a European one 4.7:1, a far-away plate a small box.
 *
 * The aspect starts as an estimate from the read's box ([cropAspectEstimate])
 * and snaps to the decoded crop's true pixel aspect as soon as it loads. A read
 * with no box shows the whole snapshot (16:9) instead.
 */
@Composable
fun PlateCropImage(
    read: PlateRead,
    mediaUrls: MediaUrls,
    slotW: Dp,
    slotH: Dp,
    modifier: Modifier = Modifier,
    corner: Dp = 4.dp,
    large: Boolean = false,
    watched: Boolean = false,
) {
    val context = LocalContext.current
    val url = rememberSnapshotUrl(read, mediaUrls)
    val bbox = read.bbox?.takeIf { it.size >= 4 }
    var aspect by remember(read.id) {
        mutableFloatStateOf(
            CropAspectCache.get(read.id) ?: cropAspectEstimate(bbox) ?: if (bbox == null && read.eventId != null) DEFAULT_FRAME_ASPECT else DEFAULT_PLATE_ASPECT,
        )
    }
    val (boxW, boxH) = fitCropBox(aspect, slotW.value, slotH.value)
    Box(modifier.size(slotW, slotH), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(boxW.dp, boxH.dp)
                .clip(RoundedCornerShape(corner))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            if (url != null) {
                val request = remember(url, bbox) {
                    ImageRequest.Builder(context)
                        .data(url)
                        .size(if (large) CROP_DECODE_PX_LARGE else CROP_DECODE_PX)
                        .apply { bbox?.let { transformations(PlateCropTransformation(it)) } }
                        .build()
                }
                AsyncImage(
                    model = request,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                    onSuccess = { state ->
                        val d = state.result.drawable
                        if (d.intrinsicWidth > 0 && d.intrinsicHeight > 0) {
                            val real = clampCropAspect(d.intrinsicWidth.toFloat() / d.intrinsicHeight)
                            CropAspectCache.put(read.id, real)
                            if (kotlin.math.abs(real - aspect) > 0.01f) aspect = real
                        }
                    },
                )
            } else {
                Icon(
                    Icons.Filled.CreditCard,
                    contentDescription = null,
                    tint = TextSecondary,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
        if (watched) WatchStarBadge(Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-6).dp))
    }
}

/** The watchlist star that rides a crop's corner (never over the plate text). */
@Composable
internal fun WatchStarBadge(modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(18.dp)
            .background(Color(0xFF15161A), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Star,
            contentDescription = "On the watchlist",
            tint = LprWatchAmber,
            modifier = Modifier.size(13.dp),
        )
    }
}

// ─── text pieces ────────────────────────────────────────────────────────────

/** The plate text: mono, bold, never the thing that moves. */
@Composable
internal fun PlateText(plate: String, sizeSp: Int, modifier: Modifier = Modifier) {
    Text(
        text = plate.ifEmpty { "No plate" },
        color = if (plate.isEmpty()) TextSecondary else TextPrimary,
        fontFamily = JetBrainsMono,
        fontWeight = FontWeight.Bold,
        fontSize = sizeSp.sp,
        letterSpacing = (sizeSp * 0.06f).sp,
        maxLines = 1,
        modifier = modifier,
    )
}

/** The known name, in the accent colour, scrolling smoothly when it is too long. The plate never moves. */
@Composable
internal fun PlateNameText(name: String, modifier: Modifier = Modifier, sizeSp: Int = 14, color: Color = LprAccentHot) {
    Text(
        text = name,
        color = color,
        fontSize = sizeSp.sp,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
        softWrap = false,
        modifier = modifier.basicMarquee(iterations = Int.MAX_VALUE, initialDelayMillis = 1500, repeatDelayMillis = 1500),
    )
}

@Composable
internal fun NewTag(modifier: Modifier = Modifier) {
    Text(
        "NEW",
        color = LprAccentHot,
        fontSize = 10.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.5.sp,
        modifier = modifier
            .background(LprAccentChip, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

/** Line two of a row: "Front gate · 2 min ago · 94%", the number amber only when low. */
internal fun rowMetaLine(cameraName: String, timeLabel: String, confidence: Float?): androidx.compose.ui.text.AnnotatedString =
    buildAnnotatedString {
        append(cameraName)
        append("  ·  ")
        append(timeLabel)
        if (confidence != null) {
            append("  ·  ")
            val low = confidence < LOW_CONFIDENCE
            withStyle(SpanStyle(color = if (low) LprWatchAmber else TextSecondary)) {
                append("${(confidence * 100).roundToInt()}%")
            }
        }
    }

private fun railColor(rail: PlateRail): Color? = when (rail) {
    PlateRail.WATCHLIST -> LprWatchAmber
    PlateRail.NEW -> video.crumb.app.ui.theme.LprAccent
    else -> null
}

// ─── list row (2A) ──────────────────────────────────────────────────────────

/**
 * A ~72 dp two-line row. Tap opens the plate profile; long-press shows the
 * peek with the actions. No icons live on the row.
 */
@Composable
fun PlateListRow(
    item: PlateRowData,
    mediaUrls: MediaUrls,
    timeLabel: String,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val read = item.read
    val haptic = LocalHapticFeedback.current
    val rail = railColor(item.rail)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .combinedClickable(
                onClick = onClick,
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onLongClick()
                },
                onLongClickLabel = "Show actions",
            )
            .drawBehind {
                if (rail != null) {
                    drawRoundRect(
                        color = rail,
                        topLeft = Offset(0f, 10.dp.toPx()),
                        size = Size(3.dp.toPx(), size.height - 20.dp.toPx()),
                        cornerRadius = CornerRadius(2.dp.toPx()),
                    )
                }
            }
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        PlateCropImage(read, mediaUrls, slotW = 104.dp, slotH = 56.dp, watched = item.watched)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PlateText(read.plate, 17)
                if (item.isNew) NewTag()
                val name = read.displayName?.takeIf { it.isNotBlank() }
                if (name != null) PlateNameText(name, Modifier.weight(1f))
            }
            Text(
                text = rowMetaLine(item.cameraName, timeLabel, read.confidence),
                color = TextSecondary,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** A grouped-by-plate row: the newest crop, the plate, and how many reads it has in range. */
@Composable
fun PlateGroupListRow(
    item: PlateRowData,
    count: Int,
    mediaUrls: MediaUrls,
    timeLabel: String,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val read = item.read
    val haptic = LocalHapticFeedback.current
    val rail = railColor(item.rail)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 72.dp)
            .combinedClickable(
                onClick = onClick,
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onLongClick()
                },
                onLongClickLabel = "Show actions",
            )
            .drawBehind {
                if (rail != null) {
                    drawRoundRect(
                        color = rail,
                        topLeft = Offset(0f, 10.dp.toPx()),
                        size = Size(3.dp.toPx(), size.height - 20.dp.toPx()),
                        cornerRadius = CornerRadius(2.dp.toPx()),
                    )
                }
            }
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        PlateCropImage(read, mediaUrls, slotW = 104.dp, slotH = 56.dp, watched = item.watched)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PlateText(read.plate, 17)
                if (item.isNew) NewTag()
                val name = read.displayName?.takeIf { it.isNotBlank() }
                if (name != null) PlateNameText(name, Modifier.weight(1f))
            }
            Text(
                text = "Last ${item.cameraName}  ·  $timeLabel",
                color = TextSecondary,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            text = readsLabel(count),
            color = if (count > 2) LprAccentHot else TextPrimary,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            modifier = Modifier
                .background(if (count > 2) LprAccentChip else MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(11.dp))
                .padding(horizontal = 9.dp, vertical = 3.dp),
        )
    }
}

/** The small date header above a run of rows ("TODAY", "YESTERDAY", "MON, MAR 3"). */
@Composable
fun PlateDayHeader(label: String, modifier: Modifier = Modifier) {
    Text(
        text = label.uppercase(),
        color = TextSecondary,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.7.sp,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 4.dp),
    )
}

// ─── gallery card ───────────────────────────────────────────────────────────

/**
 * A gallery card: the frame with the aspect-true crop inset bottom-left, then
 * the plate, the name and camera and time. No icons; the watchlist star sits in
 * the frame corner over a dark pill so it never covers the plate.
 */
@Composable
fun PlateGalleryCard(
    item: PlateRowData,
    mediaUrls: MediaUrls,
    timeLabel: String,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val read = item.read
    val haptic = LocalHapticFeedback.current
    val context = LocalContext.current
    val url = rememberSnapshotUrl(read, mediaUrls)
    val bbox = read.bbox?.takeIf { it.size >= 4 }
    // One decode serves both the frame and the crop inset: the inset is drawn out
    // of the same bitmap, so the gallery makes a single request per card and the
    // inset's aspect is pixel-true.
    var frame by remember(read.id) { mutableStateOf<ImageBitmap?>(null) }
    Column(
        modifier
            .clip(RoundedCornerShape(12.dp))
            .background(NavySurface)
            .combinedClickable(
                onClick = onClick,
                onLongClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onLongClick()
                },
                onLongClickLabel = "Show actions",
            ),
    ) {
        BoxWithConstraints(
            Modifier
                .fillMaxWidth()
                .background(Color(0xFF1A1E27)),
        ) {
            val maxW = maxWidth
            val frameH = maxW * 10f / 16f
            Box(Modifier.size(width = maxW, height = frameH)) {
                if (url != null) {
                    val frameRequest = remember(url) {
                        ImageRequest.Builder(context).data(url).size(CROP_DECODE_PX).build()
                    }
                    AsyncImage(
                        model = frameRequest,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                        onSuccess = { state ->
                            val bmp = (state.result.drawable as? android.graphics.drawable.BitmapDrawable)?.bitmap
                            if (bmp != null) frame = bmp.asImageBitmap()
                        },
                    )
                    val bmp = frame
                    val rect = if (bbox != null && bmp != null) bboxToRect(bbox, bmp.width, bmp.height) else null
                    if (bmp != null && rect != null) {
                        val insetAspect = clampCropAspect(rect.width().toFloat() / rect.height())
                        CropAspectCache.put(read.id, insetAspect)
                        // Inset height is a third of the frame; width follows the crop's real aspect.
                        val (iw, ih) = fitCropBox(insetAspect, (maxW * 0.8f).value, (frameH * 0.34f).value)
                        Canvas(
                            Modifier
                                .align(Alignment.BottomStart)
                                .padding(6.dp)
                                .size(iw.dp, ih.dp)
                                .clip(RoundedCornerShape(3.dp)),
                        ) {
                            drawImage(
                                image = bmp,
                                srcOffset = IntOffset(rect.left, rect.top),
                                srcSize = IntSize(rect.width(), rect.height()),
                                dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()),
                            )
                        }
                    }
                } else {
                    Icon(
                        Icons.Filled.CreditCard,
                        contentDescription = null,
                        tint = TextSecondary,
                        modifier = Modifier.align(Alignment.Center).size(22.dp),
                    )
                }
                if (item.watched) {
                    Box(
                        Modifier
                            .align(Alignment.TopEnd)
                            .padding(6.dp)
                            .background(Color(0xBF15161A), CircleShape)
                            .padding(4.dp),
                    ) {
                        Icon(
                            Icons.Filled.Star,
                            contentDescription = "On the watchlist",
                            tint = LprWatchAmber,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                }
            }
        }
        Column(Modifier.padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PlateText(read.plate, 15)
                if (item.isNew) NewTag()
            }
            val name = read.displayName?.takeIf { it.isNotBlank() }
            if (name != null) PlateNameText(name, Modifier.fillMaxWidth(), sizeSp = 13)
            Text(
                text = "${item.cameraName}  ·  $timeLabel",
                color = TextSecondary,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// ─── long-press peek ────────────────────────────────────────────────────────

/** One action in the peek's icon row. */
private data class PeekAction(val icon: ImageVector, val label: String, val onClick: () -> Unit)

/**
 * The long-press peek: the crop enlarged (the touch version of hover zoom), the
 * plate and name, and the quick actions. Admin-only actions (watch, correct)
 * are left out for viewers, exactly as the server would refuse them.
 */
@Composable
fun PlatePeek(
    item: PlateRowData,
    mediaUrls: MediaUrls,
    timeLabel: String,
    isAdmin: Boolean,
    onCopy: () -> Unit,
    onWatch: () -> Unit,
    onCorrect: () -> Unit,
    onReport: () -> Unit,
    onPlayback: () -> Unit,
    onDismiss: () -> Unit,
) {
    val read = item.read
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .padding(horizontal = 24.dp)
                .widthIn(max = 440.dp)
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF24272E))
                .padding(14.dp),
        ) {
            BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                // Fill the card's width (up to 320 dp) so a narrow phone never clips the crop.
                PlateCropImage(read, mediaUrls, slotW = minOf(maxWidth, 320.dp), slotH = 150.dp, corner = 8.dp, large = true)
            }
            Spacer(Modifier.size(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PlateText(read.plate, 20)
                val name = read.displayName?.takeIf { it.isNotBlank() }
                if (name != null) PlateNameText(name, Modifier.weight(1f, fill = false))
            }
            Text(
                text = "${item.cameraName}  ·  $timeLabel",
                color = TextSecondary,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 2.dp),
            )
            Spacer(Modifier.size(8.dp))
            val actions = buildList {
                if (read.plate.isNotBlank()) add(PeekAction(Icons.Filled.ContentCopy, "Copy") { onCopy(); onDismiss() })
                if (isAdmin && read.plate.isNotBlank()) {
                    add(
                        PeekAction(Icons.Filled.StarBorder, if (item.watched) "Unwatch" else "Watch") { onWatch(); onDismiss() },
                    )
                }
                if (canOfferPlateCorrection(isAdmin, read.plate)) {
                    add(PeekAction(Icons.Filled.EditNote, "Correct") { onCorrect(); onDismiss() })
                }
                add(PeekAction(Icons.Filled.PictureAsPdf, "Report") { onReport(); onDismiss() })
                add(PeekAction(Icons.Filled.Videocam, "Playback") { onPlayback(); onDismiss() })
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                actions.forEach { a ->
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.width(60.dp),
                    ) {
                        IconButton(onClick = a.onClick) {
                            Icon(a.icon, contentDescription = a.label, tint = Color(0xFFC7CBD3))
                        }
                        Text(a.label, color = TextSecondary, fontSize = 11.sp, maxLines = 1)
                    }
                }
            }
        }
    }
}
