// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import video.crumb.app.data.HaLinkDto
import video.crumb.app.data.HaStatesResponse
import java.time.Duration
import java.time.Instant
import java.time.OffsetDateTime
import kotlin.math.min

// On-video Home Assistant badge layer for the live fullscreen screen — the
// Android equivalent of the desktop `ui/ha_overlay/` badges (issue #263). Each
// placed HA link (overlay_x/overlay_y set) is drawn as a badge pinned to its
// normalized position on the DISPLAYED (letterboxed) video frame, so it lands
// where the operator dropped it on the desktop regardless of the phone's aspect
// ratio. Read-only: tapping a badge opens the same HA detail dialog as the list
// sheet. The color/icon/label semantics mirror the desktop `haVisualFor` +
// `edgeOn` EXACTLY (including the honesty rule: unknown/stale never reads as a
// confident "off/closed").

// The canonical entity visual mapping (`badgeVisual`, `BadgeVisual`, the palette
// incl. `BadgeDefaultBg`, `parseHexColor`) lives in `HaVisual.kt`, shared with the
// entity sheet + more-info dialog so an entity reads identically wherever Android
// draws it (#437).

private const val BASE_REF_PX = 22f // reference badge size at pane-scale 1.0
private const val REF_SHORT_SIDE = 320f

/** Compact "just now / 5s / 3m / 2h / 4d" from an RFC3339 timestamp. */
private fun relativeAgo(iso: String?): String? {
    if (iso.isNullOrBlank()) return null
    val then = runCatching { OffsetDateTime.parse(iso).toInstant() }
        .getOrElse { runCatching { Instant.parse(iso) }.getOrNull() } ?: return null
    val secs = Duration.between(then, Instant.now()).seconds.coerceAtLeast(0)
    return when {
        secs < 5 -> "just now"
        secs < 60 -> "${secs}s"
        secs < 3600 -> "${secs / 60}m"
        secs < 86_400 -> "${secs / 3600}h"
        else -> "${secs / 86_400}d"
    }
}

// ── Geometry (dp units) — port of desktop `overlay_geometry.dart`. ───────────

private fun paneScale(paneW: Float, paneH: Float): Float =
    (min(paneW, paneH) / REF_SHORT_SIDE).coerceIn(0.5f, 3.0f)

/**
 * The contain-fit (letterboxed) video rect within a `paneW`x`paneH` pane, in dp.
 * `videoW`/`videoH` are the decoded pixel dimensions (used for aspect only).
 * Returns [x, y, w, h].
 */
private fun fieldRect(paneW: Float, paneH: Float, videoW: Int, videoH: Int): FloatArray {
    val s = min(paneW / videoW, paneH / videoH)
    val fw = videoW * s
    val fh = videoH * s
    return floatArrayOf((paneW - fw) / 2f, (paneH - fh) / 2f, fw, fh)
}

/** Rendered badge box size (w, h) in dp for [link] at the given pane scale. */
private fun badgeSize(link: HaLinkDto, ps: Float): FloatArray {
    val size = (link.overlaySize ?: 1.0).toFloat()
    val h = (BASE_REF_PX * size * ps).coerceAtLeast(8f)
    if (link.overlayShape != "pill") return floatArrayOf(h, h)
    val chars = link.displayName.length.coerceIn(1, 16)
    val w = ((BASE_REF_PX * 1.5f + chars * BASE_REF_PX * 0.42f) * size * ps).coerceAtLeast(8f)
    return floatArrayOf(w, h)
}

/**
 * Draws the placed HA badges over the live video. Sized to fill the video Box;
 * gated by the caller on video-size-known and not-digitally-zoomed. Only the
 * badge hit-boxes are interactive — the rest of the layer passes touches through
 * to the video/PTZ beneath.
 *
 * Interaction (issue #428): [onBadgeTap] is the PRIMARY gesture (the caller
 * decides direct-fire vs control sheet vs read-only detail from the link's
 * domain/role/capability); [onBadgeLongPress] always opens the read-only detail
 * so an actuator can be inspected without actuating. [inFlightLinkIds] holds the
 * [HaLinkDto.actionLinkId]s of actions currently posting, shown as a brief
 * in-flight spinner on the badge — state is never flipped locally.
 */
@Composable
fun HaBadgeOverlayLayer(
    links: List<HaLinkDto>,
    states: HaStatesResponse?,
    videoWidth: Int,
    videoHeight: Int,
    modifier: Modifier = Modifier,
    // Client-observed staleness (>= 2 missed `/ha/states` polls). ORed with the
    // server's own `stale` flag so a badge greys when EITHER Crumb->HA or
    // phone->Crumb has gone quiet. (#371)
    clientStale: Boolean = false,
    inFlightLinkIds: Set<String> = emptySet(),
    onBadgeTap: (HaLinkDto) -> Unit,
    onBadgeLongPress: (HaLinkDto) -> Unit = onBadgeTap,
) {
    if (videoWidth <= 0 || videoHeight <= 0) return
    val placed = remember(links) { links.filter { it.hasPlacement } }
    if (placed.isEmpty()) return

    val density = LocalDensity.current
    var pane by remember { mutableStateOf(Size.Zero) } // pane size in dp

    Box(
        modifier = modifier
            .fillMaxSize()
            .onSizeChanged { sz ->
                pane = with(density) { Size(sz.width.toDp().value, sz.height.toDp().value) }
            },
    ) {
        if (pane.width <= 0f || pane.height <= 0f) return@Box
        val ps = paneScale(pane.width, pane.height)
        val fr = fieldRect(pane.width, pane.height, videoWidth, videoHeight)
        val (fx, fy, fw, fh) = fr
        for (link in placed) {
            val (bw, bh) = badgeSize(link, ps)
            val x = (fx + (link.overlayX ?: 0.0).toFloat() * fw).coerceIn(fx, (fx + fw - bw).coerceAtLeast(fx))
            val y = (fy + (link.overlayY ?: 0.0).toFloat() * fh).coerceIn(fy, (fy + fh - bh).coerceAtLeast(fy))
            HaBadge(
                link, states, clientStale,
                inFlight = link.actionLinkId in inFlightLinkIds,
                xDp = x, yDp = y, wDp = bw, hDp = bh,
                onTap = onBadgeTap, onLongPress = onBadgeLongPress,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HaBadge(
    link: HaLinkDto,
    states: HaStatesResponse?,
    clientStale: Boolean,
    inFlight: Boolean,
    xDp: Float,
    yDp: Float,
    wDp: Float,
    hDp: Float,
    onTap: (HaLinkDto) -> Unit,
    onLongPress: (HaLinkDto) -> Unit,
) {
    val st = states?.stateFor(link.entityId)
    // Stale when the server says so OR this client has missed >= 2 polls (#371).
    val stale = states?.stale == true || clientStale
    val visual = badgeVisual(link, st?.state, stale)
    val bg = parseHexColor(link.overlayBgColor) ?: BadgeDefaultBg
    val opacity = (link.overlayOpacity?.toFloat() ?: 1f).coerceIn(0.05f, 1f)
    val isPill = link.overlayShape == "pill"

    Column(
        modifier = Modifier
            .offset(x = xDp.dp, y = yDp.dp)
            .alpha(opacity),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(width = wDp.dp, height = hDp.dp)
                // Tap = primary gesture (fire/sheet/detail, decided by the caller);
                // long-press = read-only inspect. Both consumed here so the touch
                // does not fall through to the video/PTZ beneath. (#428)
                .combinedClickable(
                    onClick = { onTap(link) },
                    onLongClick = { onLongPress(link) },
                ),
        ) {
            HaBadgeChip(
                visual = visual,
                isPill = isPill,
                pillLabel = link.displayName,
                bgColor = bg,
                outline = link.overlayOutline,
                heightDp = hDp,
                modifier = Modifier.fillMaxSize(),
            )
            // Brief in-flight spinner while an action posts — we never flip the
            // shown state locally; the `/ha/states` poll converges it. (#428)
            if (inFlight) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(if (isPill) RoundedCornerShape(percent = 50) else CircleShape)
                        .background(Color.Black.copy(alpha = 0.45f)),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.fillMaxSize(0.6f),
                        color = Color.White,
                        strokeWidth = 2.dp,
                    )
                }
            }
        }

        val caption = buildString {
            if (link.overlayShowState) append(haStateDisplay(visual, st?.state, st?.unit))
            if (link.overlayShowAge) {
                relativeAgo(st?.lastChanged)?.let {
                    if (isNotEmpty()) append(" · ")
                    append(it)
                }
            }
        }
        if (caption.isNotBlank()) {
            Box(
                modifier = Modifier
                    .padding(top = 2.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(Color.Black.copy(alpha = 0.62f))
                    .padding(horizontal = 5.dp, vertical = 2.dp),
            ) {
                Text(
                    text = caption,
                    color = visual.color,
                    fontSize = (hDp * 0.42f).coerceIn(9f, 15f).sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
    }
}

/** A single badge chip — `dot` (icon only) or `pill` (icon + label). */
@Composable
private fun HaBadgeChip(
    visual: BadgeVisual,
    isPill: Boolean,
    pillLabel: String,
    bgColor: Color,
    outline: Boolean,
    heightDp: Float,
    modifier: Modifier = Modifier,
) {
    val shape = if (isPill) RoundedCornerShape(percent = 50) else CircleShape
    val base = modifier
        .then(if (outline) Modifier.shadow(4.dp, shape) else Modifier)
        .clip(shape)
        .background(bgColor)
        .then(if (outline) Modifier.border(1.5.dp, Color.White.copy(alpha = 0.9f), shape) else Modifier)

    if (!isPill) {
        Box(base, contentAlignment = Alignment.Center) {
            Icon(visual.icon, contentDescription = null, tint = visual.color, modifier = Modifier.fillMaxSize(0.58f))
        }
    } else {
        val labelColor = if (bgColor.luminance() > 0.5f) Color.Black else Color.White
        Row(
            modifier = base.padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                visual.icon,
                contentDescription = null,
                tint = visual.color,
                modifier = Modifier.fillMaxHeight(0.56f).aspectRatio(1f),
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = pillLabel,
                color = labelColor,
                fontSize = (heightDp * 0.40f).coerceIn(8f, 26f).sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
        }
    }
}
