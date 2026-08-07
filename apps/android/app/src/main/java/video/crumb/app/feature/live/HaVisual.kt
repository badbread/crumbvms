// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.material.icons.filled.Blinds
import androidx.compose.material.icons.filled.BlindsClosed
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material.icons.filled.CleaningServices
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Co2
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Curtains
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.DeviceThermostat
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Doorbell
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.ElectricMeter
import androidx.compose.material.icons.filled.ElectricalServices
import androidx.compose.material.icons.filled.EvStation
import androidx.compose.material.icons.filled.Fence
import androidx.compose.material.icons.filled.Garage
import androidx.compose.material.icons.filled.GasMeter
import androidx.compose.material.icons.filled.GppGood
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.HeatPump
import androidx.compose.material.icons.filled.Highlight
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.HotTub
import androidx.compose.material.icons.filled.Hvac
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Kitchen
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.LocalLaundryService
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Mail
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MovieFilter
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.OutdoorGrill
import androidx.compose.material.icons.filled.Outlet
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Plumbing
import androidx.compose.material.icons.filled.Pool
import androidx.compose.material.icons.filled.Power
import androidx.compose.material.icons.filled.PowerOff
import androidx.compose.material.icons.filled.Print
import androidx.compose.material.icons.filled.RollerShades
import androidx.compose.material.icons.filled.Router
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.SensorDoor
import androidx.compose.material.icons.filled.SensorOccupied
import androidx.compose.material.icons.filled.SensorWindow
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.SettingsRemote
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.SmartButton
import androidx.compose.material.icons.filled.SmartDisplay
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.SolarPower
import androidx.compose.material.icons.filled.Speaker
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.ToggleOn
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Vibration
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WaterDamage
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbIncandescent
import androidx.compose.material.icons.filled.WbCloudy
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.WbTwilight
import androidx.compose.material.icons.filled.Whatshot
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WindPower
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
// keeps Android in step with the other clients.
//
// `badgeIconSlugs` below covers the ENTIRE canonical closed icon vocabulary
// defined once server-side in `services/api/src/ha.rs` (`CANONICAL_ICON_SLUGS`,
// issue #438): every slug there maps to a Material glyph here, so an operator's
// pick renders the same on Android as on desktop/iOS instead of degrading to the
// generic `Sensors` dot. The server rejects any `overlay_icon` outside that set,
// so the `?: base.icon` fallback in `badgeVisual` is defense-in-depth.

// Palette — matches desktop `ha_icons.dart`.
internal val BadgeGrey = Color(0xFF8E8E93)
internal val BadgeAmber = Color(0xFFFFB143) // open (door/window/garage)
internal val BadgeNeutral = Color(0xFFB9C2CC) // closed/off but KNOWN — not grey
internal val BadgeBlue = Color(0xFF33C3FF) // motion / occupancy active
internal val BadgeGreen = Color(0xFF2BA84A) // switch on
internal val BadgeWarmYellow = Color(0xFFFFCC33) // light on
internal val BadgeDanger = Color(0xFFE5484D) // smoke/gas alarm active — attention red
internal val BadgeDefaultBg = Color(0xFF17171B) // near-black opaque chip behind the glyph

/**
 * Resolved look for one entity: state color, glyph, and a friendly state label,
 * plus [active] — the tri-state on/off derived once here (true = on/open/motion,
 * false = off/closed/clear, null = unknown/stale/scene) so every surface can
 * style "on vs off" from the SAME signal instead of re-deriving it or guessing
 * from the color. The more-info dialog uses it to fill the icon disc boldly when
 * an actuator is on (issue: popup icon didn't read as lit); the badge/tile ignore
 * it and keep today's look.
 */
internal data class BadgeVisual(
    val color: Color,
    val icon: ImageVector,
    val label: String,
    val active: Boolean? = null,
)

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

/**
 * device_class -> Crumb badge-class slug. Mirrors desktop `labelForDeviceClass`
 * exactly, including the display-only extensions (lock/smoke/gas/leak) that give
 * problem sensors their own glyph + alert color instead of a generic dot (issue
 * #438, restoring the richness #437 flattened). A SUPERSET of the backend's
 * `label_for_device_class`; the shared first five cases stay aligned with it.
 */
private fun labelForDeviceClass(deviceClass: String?): String =
    when (deviceClass?.trim()?.lowercase(Locale.US)) {
        "motion", "moving", "vibration" -> "motion"
        "occupancy", "presence" -> "occupancy"
        "door", "opening" -> "door"
        "window" -> "window"
        "garage_door" -> "garage"
        // display-only extensions (badge/sheet richness, issue #438)
        "lock" -> "lock"
        "smoke" -> "smoke"
        "gas", "carbon_monoxide" -> "gas"
        "moisture" -> "leak"
        else -> "sensor"
    }

/**
 * Operator-pickable per-badge icon override (migration 0059 slug -> glyph),
 * covering the ENTIRE canonical vocabulary (`CANONICAL_ICON_SLUGS`, issue #438).
 * Each glyph is the Material equivalent of the desktop `kHaBadgeIconChoices`
 * choice for the same slug, so the same pick reads the same across clients.
 */
private val badgeIconSlugs: Map<String, ImageVector> = mapOf(
    // contact & openings
    "door" to Icons.Filled.SensorDoor,
    "window" to Icons.Filled.SensorWindow,
    "gate" to Icons.Filled.Fence,
    "garage" to Icons.Filled.Garage,
    "cover" to Icons.Filled.BlindsClosed,
    "blinds" to Icons.Filled.Blinds,
    "curtains" to Icons.Filled.Curtains,
    "shade" to Icons.Filled.RollerShades,
    "lock" to Icons.Filled.Lock,
    "key" to Icons.Filled.Key,
    // motion & presence
    "motion" to Icons.Filled.DirectionsRun,
    "occupancy" to Icons.Filled.SensorOccupied,
    "person" to Icons.Filled.Person,
    "home" to Icons.Filled.Home,
    "pet" to Icons.Filled.Pets,
    "vibration" to Icons.Filled.Vibration,
    // lighting
    "lightbulb" to Icons.Filled.Lightbulb,
    "floodlight" to Icons.Filled.Highlight,
    "outdoor_light" to Icons.Filled.WbIncandescent,
    "landscape_light" to Icons.Filled.WbTwilight,
    // power & switches
    "switch" to Icons.Filled.ToggleOn,
    "power" to Icons.Filled.Power,
    "plug" to Icons.Filled.ElectricalServices,
    "outlet" to Icons.Filled.Outlet,
    "energy" to Icons.Filled.Bolt,
    "meter" to Icons.Filled.ElectricMeter,
    "battery" to Icons.Filled.BatteryFull,
    "solar" to Icons.Filled.SolarPower,
    "ev" to Icons.Filled.EvStation,
    // climate & environment
    "fan" to Icons.Filled.Air,
    "ac" to Icons.Filled.AcUnit,
    "heatpump" to Icons.Filled.HeatPump,
    "hvac" to Icons.Filled.Hvac,
    "thermostat" to Icons.Filled.Thermostat,
    "temperature" to Icons.Filled.DeviceThermostat,
    "humidity" to Icons.Filled.Opacity,
    "sun" to Icons.Filled.WbSunny,
    // weather
    "cloud" to Icons.Filled.WbCloudy,
    "rain" to Icons.Filled.Grain,
    "wind" to Icons.Filled.WindPower,
    "storm" to Icons.Filled.Thunderstorm,
    "moon" to Icons.Filled.DarkMode,
    // safety & alarm
    "smoke" to Icons.Filled.Cloud,
    "gas" to Icons.Filled.GasMeter,
    "co" to Icons.Filled.Co2,
    "fire" to Icons.Filled.LocalFireDepartment,
    "leak" to Icons.Filled.WaterDamage,
    "water" to Icons.Filled.WaterDrop,
    "valve" to Icons.Filled.Plumbing,
    "siren" to Icons.Filled.Campaign,
    "security" to Icons.Filled.Shield,
    "armed" to Icons.Filled.GppGood,
    "warning" to Icons.Filled.Warning,
    "doorbell" to Icons.Filled.Doorbell,
    "bell" to Icons.Filled.NotificationsActive,
    // camera & media
    "camera" to Icons.Filled.Videocam,
    "tv" to Icons.Filled.Tv,
    "speaker" to Icons.Filled.Speaker,
    "media_player" to Icons.Filled.SmartDisplay,
    "remote" to Icons.Filled.SettingsRemote,
    "game" to Icons.Filled.SportsEsports,
    "mic" to Icons.Filled.Mic,
    "music" to Icons.Filled.MusicNote,
    // network & computing
    "wifi" to Icons.Filled.Wifi,
    "router" to Icons.Filled.Router,
    "printer" to Icons.Filled.Print,
    "server" to Icons.Filled.Dns,
    "computer" to Icons.Filled.Computer,
    "storage" to Icons.Filled.Storage,
    "phone" to Icons.Filled.Smartphone,
    // vehicles & delivery
    "vehicle" to Icons.Filled.DirectionsCar,
    "package" to Icons.Filled.Inventory2,
    "mail" to Icons.Filled.Mail,
    // appliances & outdoor
    "vacuum" to Icons.Filled.CleaningServices,
    "lawn" to Icons.Filled.Grass,
    "fridge" to Icons.Filled.Kitchen,
    "laundry" to Icons.Filled.LocalLaundryService,
    "pool" to Icons.Filled.Pool,
    "hottub" to Icons.Filled.HotTub,
    "grill" to Icons.Filled.OutdoorGrill,
    "smoker" to Icons.Filled.Whatshot,
    "coffee" to Icons.Filled.Coffee,
    "plant" to Icons.Filled.Eco,
    // time
    "clock" to Icons.Filled.Schedule,
    "calendar" to Icons.Filled.CalendarToday,
    "timer" to Icons.Filled.Timer,
    // automation
    "scene" to Icons.Filled.MovieFilter,
    "script" to Icons.Filled.Terminal,
    "button" to Icons.Filled.SmartButton,
    // generic fallback
    "sensor" to Icons.Filled.Sensors,
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
        "lock" -> Icons.Filled.Lock
        "smoke" -> Icons.Filled.LocalFireDepartment
        "gas" -> Icons.Filled.Co2
        "leak" -> Icons.Filled.WaterDamage
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
    if (domain == "scene") return BadgeVisual(BadgeNeutral, Icons.Filled.MovieFilter, "Scene", active = null)
    val on = if (state == null || stale) null else edgeOn(state)
    if (on == null) {
        return BadgeVisual(BadgeGrey.copy(alpha = 0.6f), defaultIcon(domain, deviceClass), state ?: "Unknown", active = null)
    }
    if (domain == "light") {
        return BadgeVisual(if (on) BadgeWarmYellow else BadgeGrey, Icons.Filled.Lightbulb, if (on) "On" else "Off", active = on)
    }
    if (domain == "switch") {
        return BadgeVisual(
            if (on) BadgeGreen else BadgeGrey,
            if (on) Icons.Filled.Power else Icons.Filled.PowerOff,
            if (on) "On" else "Off",
            active = on,
        )
    }
    return when (labelForDeviceClass(deviceClass)) {
        "door" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, Icons.Filled.SensorDoor, if (on) "Open" else "Closed", active = on)
        "window" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, Icons.Filled.SensorWindow, if (on) "Open" else "Closed", active = on)
        "garage" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, Icons.Filled.Garage, if (on) "Open" else "Closed", active = on)
        "motion" -> BadgeVisual(if (on) BadgeBlue else BadgeGrey, Icons.Filled.DirectionsRun, if (on) "Motion" else "Clear", active = on)
        "occupancy" -> BadgeVisual(if (on) BadgeBlue else BadgeGrey, Icons.Filled.Person, if (on) "Occupied" else "Clear", active = on)
        // A binary_sensor lock reads on = unsecured/unlocked, off = locked.
        "lock" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, if (on) Icons.Filled.LockOpen else Icons.Filled.Lock, if (on) "Unlocked" else "Locked", active = on)
        "smoke" -> BadgeVisual(if (on) BadgeDanger else BadgeNeutral, Icons.Filled.LocalFireDepartment, if (on) "Smoke" else "Clear", active = on)
        "gas" -> BadgeVisual(if (on) BadgeDanger else BadgeNeutral, Icons.Filled.Co2, if (on) "Gas" else "Clear", active = on)
        "leak" -> BadgeVisual(if (on) BadgeAmber else BadgeNeutral, Icons.Filled.WaterDamage, if (on) "Leak" else "Dry", active = on)
        else -> BadgeVisual(if (on) BadgeBlue else BadgeGrey, Icons.Filled.Sensors, if (on) "Active" else "Clear", active = on)
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
    // `on` here is the same tri-state `defaultVisual` used for `base.active`
    // (both null out on unknown/stale/scene); keep them in lockstep.
    return BadgeVisual(color, overrideIcon ?: base.icon, base.label, active = on)
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

/**
 * The badge chip's background color: `overlay_bg_color_on` when the entity
 * reads ON (and the operator set one) — else `overlay_bg_color` — else
 * [BadgeDefaultBg]. Keyed on [active], the SAME tri-state `badgeVisual`
 * computes (`active == true` = confidently on; `false`/`null` = off, scene,
 * stale, or unknown), so a null `active` NEVER picks the on-color — same
 * honesty rule the color/icon override already follows.
 */
internal fun resolveBadgeBg(link: HaLinkDto, active: Boolean?): Color {
    val bg = parseHexColor(link.overlayBgColor)
    if (active == true) {
        parseHexColor(link.overlayBgColorOn)?.let { return it }
    }
    return bg ?: BadgeDefaultBg
}
