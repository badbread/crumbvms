// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Doorbell
import androidx.compose.material.icons.filled.Garage
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MovieFilter
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Power
import androidx.compose.material.icons.filled.PowerOff
import androidx.compose.material.icons.filled.SensorDoor
import androidx.compose.material.icons.filled.SensorWindow
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import video.crumb.app.data.HaLinkDto
import java.util.Locale

// ── The ONE canonical Home Assistant visual mapping for the Android client. ──
//
// `badgeVisual` (icon slug -> glyph, state -> active/color/label) is the single
// source of truth shared by BOTH the on-video badge overlay (`HaBadgeOverlay.kt`)
// and the entity sheet + more-info dialog (`HaEntitiesSheet.kt`), so an entity
// reads identically wherever Android draws it (issue #437). It is a faithful port
// of the desktop `haVisualFor` + `edgeOn` (`ui/ha_overlay/ha_icons.dart`), which
// keeps Android in step with the other clients. The closed-vocabulary rework is
// tracked separately (issue #438) — do NOT widen the slug set here.

// Palette — matches desktop `ha_icons.dart`.
internal val BadgeGrey = Color(0xFF8E8E93)
internal val BadgeAmber = Color(0xFFFFB143) // open (door/window/garage)
internal val BadgeNeutral = Color(0xFFB9C2CC) // closed/off but KNOWN — not grey
internal val BadgeBlue = Color(0xFF33C3FF) // motion / occupancy active
internal val BadgeGreen = Color(0xFF2BA84A) // switch on
internal val BadgeWarmYellow = Color(0xFFFFCC33) // light on

/** Resolved look for one entity: state color, glyph, and a friendly state label. */
internal data class BadgeVisual(val color: Color, val icon: ImageVector, val label: String)

/**
 * HA `state` -> on / off / indeterminate, mirroring desktop `edgeOn` (and the
 * server `edge_on`). `null` = indeterminate (unavailable/unknown/anything else)
 * and is NEVER treated as off. Beyond the desktop set, a few tokens the Android
 * entity sheet relied on (`opening`, `unlocked`, `playing`, `active`, `locked`)
 * are folded in here so those entities keep reading as active/inactive under the
 * one unified mapping instead of falling back to indeterminate (issue #437).
 */
private fun edgeOn(state: String): Boolean? = when (state.trim().lowercase(Locale.US)) {
    "on", "open", "opening", "detected", "true", "home", "motion", "occupied",
    "unlocked", "playing", "active" -> true
    "off", "closed", "clear", "false", "not_home", "no_motion", "locked" -> false
    else -> null
}

/** device_class -> Crumb label slug (mirrors desktop `labelForDeviceClass`). */
private fun labelForDeviceClass(deviceClass: String?): String =
    when (deviceClass?.trim()?.lowercase(Locale.US)) {
        "motion", "moving", "vibration" -> "motion"
        "occupancy", "presence" -> "occupancy"
        "door", "opening" -> "door"
        "window" -> "window"
        "garage_door" -> "garage"
        else -> "sensor"
    }

/** Operator-pickable per-badge icon override (migration 0059 slug -> glyph). */
private val badgeIconSlugs: Map<String, ImageVector> = mapOf(
    "door" to Icons.Filled.SensorDoor,
    "window" to Icons.Filled.SensorWindow,
    "garage" to Icons.Filled.Garage,
    "motion" to Icons.Filled.DirectionsRun,
    "person" to Icons.Filled.Person,
    "lightbulb" to Icons.Filled.Lightbulb,
    "power" to Icons.Filled.Power,
    "switch" to Icons.Filled.Power,
    "lock" to Icons.Filled.Lock,
    "doorbell" to Icons.Filled.Doorbell,
    "water" to Icons.Filled.WaterDrop,
    "leak" to Icons.Filled.WaterDrop,
    "fire" to Icons.Filled.LocalFireDepartment,
    "smoke" to Icons.Filled.LocalFireDepartment,
    "thermostat" to Icons.Filled.Thermostat,
    "camera" to Icons.Filled.Videocam,
    "pet" to Icons.Filled.Pets,
    "scene" to Icons.Filled.MovieFilter,
    "sensor" to Icons.Filled.Sensors,
    "energy" to Icons.Filled.Bolt,
)

private fun defaultIcon(domain: String, deviceClass: String?): ImageVector = when {
    domain == "light" -> Icons.Filled.Lightbulb
    domain == "switch" -> Icons.Filled.Power
    domain == "scene" -> Icons.Filled.MovieFilter
    else -> when (labelForDeviceClass(deviceClass)) {
        "door" -> Icons.Filled.SensorDoor
        "window" -> Icons.Filled.SensorWindow
        "garage" -> Icons.Filled.Garage
        "motion" -> Icons.Filled.DirectionsRun
        "occupancy" -> Icons.Filled.Person
        else -> Icons.Filled.Sensors
    }
}

/** Port of desktop `_haVisualDefault` — device-class/domain + state -> look. */
private fun defaultVisual(
    domain: String,
    deviceClass: String?,
    state: String?,
    stale: Boolean,
): BadgeVisual {
    if (domain == "scene") return BadgeVisual(BadgeNeutral, Icons.Filled.MovieFilter, "Scene")
    val on = if (state == null || stale) null else edgeOn(state)
    if (on == null) {
        return BadgeVisual(BadgeGrey.copy(alpha = 0.6f), defaultIcon(domain, deviceClass), state ?: "Unknown")
    }
    if (domain == "light") {
        return BadgeVisual(if (on) BadgeWarmYellow else BadgeGrey, Icons.Filled.Lightbulb, if (on) "On" else "Off")
    }
    if (domain == "switch") {
        return BadgeVisual(
            if (on) BadgeGreen else BadgeGrey,
            if (on) Icons.Filled.Power else Icons.Filled.PowerOff,
            if (on) "On" else "Off",
        )
    }
    return when (labelForDeviceClass(deviceClass)) {
        "door" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, Icons.Filled.SensorDoor, if (on) "Open" else "Closed")
        "window" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, Icons.Filled.SensorWindow, if (on) "Open" else "Closed")
        "garage" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, Icons.Filled.Garage, if (on) "Open" else "Closed")
        "motion" -> BadgeVisual(if (on) BadgeBlue else BadgeGrey, Icons.Filled.DirectionsRun, if (on) "Motion" else "Clear")
        "occupancy" -> BadgeVisual(if (on) BadgeBlue else BadgeGrey, Icons.Filled.Person, if (on) "Occupied" else "Clear")
        else -> BadgeVisual(if (on) BadgeBlue else BadgeGrey, Icons.Filled.Sensors, if (on) "Active" else "Clear")
    }
}

/**
 * The canonical entity look: the default look, then the operator's per-badge
 * icon/color overrides. The color override applies ONLY to a KNOWN reading
 * (active full-strength, inactive dimmed) — never to unknown/stale, where the
 * grey honesty treatment must win (unknown/stale never reads as a confident
 * "off/closed").
 */
internal fun badgeVisual(link: HaLinkDto, state: String?, stale: Boolean): BadgeVisual {
    val base = defaultVisual(link.domain, link.deviceClass, state, stale)
    val overrideIcon = link.overlayIcon?.let { badgeIconSlugs[it] }
    val on = if (state == null || stale || link.domain == "scene") null else edgeOn(state)
    val colorOverride = parseHexColor(link.overlayColor)
    val color = if (colorOverride != null && on != null) {
        if (on) colorOverride else colorOverride.copy(alpha = 0.45f)
    } else {
        base.color
    }
    return BadgeVisual(color, overrideIcon ?: base.icon, base.label)
}

/**
 * The state text to show on a badge caption / entity sheet (issue #449): the
 * visual's friendly label ("Open"/"On"), with the entity's
 * `unit_of_measurement` appended when the reading is a real value — a
 * numeric/plain state (`edgeOn == null`) that is not an indeterminate
 * placeholder — and a unit is known: "72" -> "72 °F", "48" -> "48 %". An
 * on/off/open/closed label never takes a unit. Returns exactly today's label
 * when [unit] is null, so an un-updated server renders unchanged. Mirrors the
 * desktop `haStateDisplay`.
 */
internal fun haStateDisplay(visual: BadgeVisual, state: String?, unit: String?): String {
    val base = visual.label
    val u = unit?.trim()
    if (u.isNullOrEmpty() || state == null) return base
    val s = state.trim()
    if (s.isEmpty() || edgeOn(s) != null) return base
    when (s.lowercase(Locale.US)) {
        "unavailable", "unknown", "none" -> return base
    }
    return "$base $u"
}

/** Parse `#RRGGBB` -> opaque [Color], or null if absent/malformed. */
internal fun parseHexColor(hex: String?): Color? {
    val h = hex?.trim()?.removePrefix("#") ?: return null
    if (h.length != 6) return null
    val v = h.toLongOrNull(16) ?: return null
    return Color(0xFF000000L or v)
}
