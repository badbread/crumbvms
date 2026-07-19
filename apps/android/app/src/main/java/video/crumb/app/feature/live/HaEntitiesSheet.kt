// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Garage
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.MeetingRoom
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Window
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import video.crumb.app.data.HaLinkDto
import video.crumb.app.data.HaStatesResponse
import java.time.Duration
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Locale

// Home Assistant default (dark) theme tokens — the sheet renders in HA's own
// look regardless of the app theme, so it feels like an extension of the HA app.
private val HaBg = Color(0xFF111111)
private val HaCard = Color(0xFF1C1C1C)
private val HaCardActive = Color(0xFF232323)
private val HaPrimaryText = Color(0xFFE1E1E1)
private val HaSecondaryText = Color(0xFF9B9B9B)
private val HaDivider = Color(0x1FE1E1E1)
private val HaBlue = Color(0xFF18BCF2) // HA brand mark
private val HaAmber = Color(0xFFFFC107) // active state
private val HaRed = Color(0xFFF44336) // problem state
private val HaGrey = Color(0xFF7A7A7A) // inactive icon

/** Resolved visual for one entity: state color, icon, and a display state text. */
private data class HaVisual(val color: Color, val icon: ImageVector, val stateText: String)

private val PROBLEM_CLASSES =
    setOf("smoke", "gas", "safety", "moisture", "problem", "co", "carbon_monoxide", "tamper")

/** Is a binary/state value "active" (on/open/detected)? */
private fun isActive(state: String): Boolean =
    when (state.lowercase(Locale.US)) {
        "on", "open", "opening", "detected", "unlocked", "home", "playing", "active" -> true
        else -> false
    }

/**
 * Map (domain, device_class, state) to HA's state color + icon + a friendly
 * state label, matching Home Assistant's own conventions: amber when active,
 * grey when inactive, red for problem-type binary sensors.
 */
private fun haVisual(link: HaLinkDto, state: String?): HaVisual {
    val s = state?.lowercase(Locale.US) ?: "unknown"
    val dc = link.deviceClass?.lowercase(Locale.US)
    val active = isActive(s)
    val problem = dc in PROBLEM_CLASSES && active

    val color = when {
        s == "unavailable" || s == "unknown" -> HaGrey
        problem -> HaRed
        active -> HaAmber
        else -> HaGrey
    }

    val icon = when {
        link.domain == "light" -> Icons.Filled.Lightbulb
        link.domain == "switch" || link.domain == "input_boolean" -> Icons.Filled.PowerSettingsNew
        link.domain == "lock" -> if (s == "unlocked") Icons.Filled.LockOpen else Icons.Filled.Lock
        dc == "garage" || dc == "garage_door" -> Icons.Filled.Garage
        dc == "motion" || dc == "occupancy" || dc == "presence" || dc == "moving" -> Icons.Filled.Sensors
        dc == "window" -> Icons.Filled.Window
        dc == "door" || dc == "opening" || link.domain == "cover" -> Icons.Filled.MeetingRoom
        problem -> Icons.Filled.Warning
        else -> Icons.Filled.Bolt
    }

    // HA's friendly state text per device class.
    val text = when {
        s == "unavailable" -> "Unavailable"
        s == "unknown" -> "Unknown"
        dc == "motion" || dc == "occupancy" || dc == "presence" -> if (active) "Detected" else "Clear"
        dc in PROBLEM_CLASSES -> if (active) "Detected" else "OK"
        dc == "door" || dc == "window" || dc == "garage" || dc == "garage_door" ||
            dc == "opening" || link.domain == "cover" -> if (active) "Open" else "Closed"
        link.domain == "lock" -> if (s == "unlocked") "Unlocked" else "Locked"
        link.domain == "light" || link.domain == "switch" || link.domain == "input_boolean" ->
            if (active) "On" else "Off"
        else -> state.orEmpty().replaceFirstChar { it.uppercase() }.ifBlank { "Unknown" }
    }
    return HaVisual(color, icon, text)
}

/** "Changed N ago" from an RFC3339 timestamp, HA-style. */
private fun changedAgo(iso: String?): String? {
    if (iso.isNullOrBlank()) return null
    val then = runCatching { OffsetDateTime.parse(iso).toInstant() }
        .getOrElse { runCatching { Instant.parse(iso) }.getOrNull() } ?: return null
    val d = Duration.between(then, Instant.now())
    val secs = d.seconds.coerceAtLeast(0)
    val label = when {
        secs < 45 -> "just now"
        secs < 3600 -> "${(secs / 60).coerceAtLeast(1)} min ago"
        secs < 86_400 -> "${secs / 3600} hr ago"
        else -> "${secs / 86_400} day${if (secs / 86_400 == 1L) "" else "s"} ago"
    }
    return if (label == "just now") "Changed just now" else "Changed $label"
}

/**
 * The Home Assistant entity sheet for one camera. Read-only (Phase 1): shows the
 * camera's linked HA entities as HA-style tile cards with live state; tapping a
 * tile opens an HA "more-info"-style detail. Control lands in Phase 2.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HaEntitiesSheet(
    cameraName: String,
    links: List<HaLinkDto>,
    states: HaStatesResponse?,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selected by remember { mutableStateOf<HaLinkDto?>(null) }
    val sorted = remember(links) { links.sortedBy { it.sortOrder } }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = HaBg,
        dragHandle = { HaGrabber() },
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 16.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Home, contentDescription = null, tint = HaBlue, modifier = Modifier.size(26.dp))
            Spacer(Modifier.size(10.dp))
            Column {
                Text("Home Assistant", color = HaPrimaryText, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                Text(
                    "$cameraName · ${sorted.size} " + if (sorted.size == 1) "entity" else "entities",
                    color = HaSecondaryText,
                    fontSize = 12.5.sp,
                )
            }
        }
        if (states?.stale == true) {
            Text(
                "Home Assistant unreachable — showing last known state",
                color = HaSecondaryText,
                fontSize = 12.sp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 2.dp),
            )
        }

        LazyColumn(
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 28.dp, top = 2.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(sorted, key = { it.id }) { link ->
                val st = states?.stateFor(link.entityId)
                HaTile(link, st?.state, onClick = { selected = link })
            }
        }
    }

    selected?.let { link ->
        val st = states?.stateFor(link.entityId)
        HaMoreInfoDialog(link, st?.state, st?.lastChanged, onDismiss = { selected = null })
    }
}

@Composable
private fun HaGrabber() {
    Box(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 8.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 36.dp, height = 4.dp).background(Color(0xFF3A3A3A), CircleShape))
    }
}

/** One HA tile card: state-colored icon in a tinted circle, name + state. */
@Composable
private fun HaTile(link: HaLinkDto, state: String?, onClick: () -> Unit) {
    val v = haVisual(link, state)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(HaCard)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(CircleShape).background(v.color.copy(alpha = 0.16f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(v.icon, contentDescription = null, tint = v.color, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                link.displayName,
                color = HaPrimaryText,
                fontSize = 14.5.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
            )
            Text(v.stateText, color = if (v.color == HaGrey) HaSecondaryText else v.color, fontSize = 13.sp)
        }
        Text("›", color = Color(0xFF4C4C4C), fontSize = 20.sp)
    }
}

/** HA "more-info"-style detail dialog (read-only). Also opened by tapping an
 *  on-video badge in [HaBadgeOverlayLayer]. */
@Composable
internal fun HaMoreInfoDialog(
    link: HaLinkDto,
    state: String?,
    lastChanged: String?,
    onDismiss: () -> Unit,
) {
    val v = haVisual(link, state)
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(HaCard)
                .padding(horizontal = 20.dp, vertical = 22.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                modifier = Modifier.size(76.dp).clip(CircleShape).background(v.color.copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(v.icon, contentDescription = null, tint = v.color, modifier = Modifier.size(40.dp))
            }
            Spacer(Modifier.height(12.dp))
            Text(link.displayName, color = HaPrimaryText, fontSize = 19.sp, fontWeight = FontWeight.Medium)
            Text(v.stateText, color = if (v.color == HaGrey) HaSecondaryText else v.color, fontSize = 15.sp)
            changedAgo(lastChanged)?.let {
                Spacer(Modifier.height(4.dp))
                Text(it, color = HaSecondaryText, fontSize = 12.5.sp)
            }
            Spacer(Modifier.height(16.dp))
            HaAttrRow("Device class", link.deviceClass?.replace('_', ' ') ?: "—")
            HaAttrRow("Entity", link.entityId)
        }
    }
}

@Composable
private fun HaAttrRow(key: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(key, color = HaSecondaryText, fontSize = 13.5.sp)
        Text(value, color = HaPrimaryText, fontSize = 13.5.sp)
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(HaDivider))
}
