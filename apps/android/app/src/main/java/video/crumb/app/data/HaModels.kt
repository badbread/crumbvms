// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Home Assistant link + state DTOs. Mirror the subset of the server shapes the
// mobile UI needs. The JSON layer has `ignoreUnknownKeys = true`, so it is safe
// to carry only the fields we render — the overlay placement fields below are
// what the desktop badge editor writes, and are needed on Android to draw the
// same on-video badges the operator placed on the desktop (issue #263).

/** One HA entity linked to a camera (GET /cameras/{id}/ha/links). */
@Serializable
data class HaLinkDto(
    val id: String,
    // The link's stable uuid as the server names it in the action contract. Some
    // server builds emit only `id` (which is the same uuid); decode either and
    // resolve through [actionLinkId] so POST /ha/action always has the id.
    @SerialName("link_id") val linkId: String? = null,
    @SerialName("entity_id") val entityId: String,
    val role: String,
    @SerialName("device_class") val deviceClass: String? = null,
    val label: String? = null,
    @SerialName("sort_order") val sortOrder: Int = 0,
    // ── On-video badge placement (desktop overlay editor; see services/api ha.rs).
    // overlay_x/y are fractions (0..1) of the DISPLAYED (letterboxed) video frame;
    // both null = the badge is not placed and is shown only in the list sheet.
    @SerialName("overlay_x") val overlayX: Double? = null,
    @SerialName("overlay_y") val overlayY: Double? = null,
    @SerialName("overlay_size") val overlaySize: Double? = null,
    @SerialName("overlay_color") val overlayColor: String? = null,
    @SerialName("overlay_icon") val overlayIcon: String? = null,
    @SerialName("overlay_show_state") val overlayShowState: Boolean = false,
    @SerialName("overlay_show_age") val overlayShowAge: Boolean = false,
    @SerialName("overlay_opacity") val overlayOpacity: Double? = null,
    @SerialName("overlay_shape") val overlayShape: String? = null,
    @SerialName("overlay_bg_color") val overlayBgColor: String? = null,
    @SerialName("overlay_outline") val overlayOutline: Boolean = false,
    // ── Per-link control config (migration 0075, issue #440). Both default to
    // today's behavior, so an older server that omits them decodes unchanged
    // (kotlinx nullable + default; JSON layer also ignores unknown keys).
    // require_confirm: prompt a confirm before EVERY action on this link.
    // allowed_actions: when non-null, offer/allow ONLY these actions.
    @SerialName("require_confirm") val requireConfirm: Boolean = false,
    @SerialName("allowed_actions") val allowedActions: List<String>? = null,
) {
    /** The HA domain — the part before the dot in `light.porch`. */
    val domain: String get() = entityId.substringBefore('.', "")

    /**
     * Whether [action] is permitted by this link's [allowedActions] gate
     * (migration 0075). A null list means "all of the domain's actions"
     * (today's behavior).
     */
    fun actionAllowed(action: String): Boolean =
        allowedActions == null || action in allowedActions

    /** Display caption: the operator's label, else the entity id. */
    val displayName: String get() = label?.takeIf { it.isNotBlank() } ?: entityId

    /** Placed on the video frame (both coordinates present) → draw an on-video badge. */
    val hasPlacement: Boolean get() = overlayX != null && overlayY != null

    /** The uuid POST /ha/action expects for this link (`link_id`, else `id`). */
    val actionLinkId: String get() = linkId ?: id

    /** This link controls (not just observes) its entity — controls render only for these. */
    val isActuator: Boolean get() = role == "actuator"
}

/** Body for POST /cameras/{id}/ha/action — fire one HA service call for a link. */
@Serializable
data class HaActionRequest(
    @SerialName("link_id") val linkId: String,
    val action: String,
)

/** Response for the HA action call: `{ "ok": true }` on success. */
@Serializable
data class HaActionResponse(val ok: Boolean = false)

// ── HA control interaction model (issue #428) ────────────────────────────────
// One place for the domain → interaction split, shared by the on-video badges
// and the entity sheet so both clients behave identically. `domain` is the part
// of `entity_id` before the first dot (e.g. `light` in `light.porch`).

/**
 * The single "primary" action a DIRECT TAP fires on a controllable actuator
 * badge — no dialog. `null` = this domain is NOT a direct-tap control: it either
 * needs the multi-action control sheet (see [haNeedsSheet]) or is not actuable.
 * Mirrors the server's per-domain action allowlist for the single-tap cases.
 */
fun haPrimaryAction(domain: String): String? = when (domain) {
    "light", "switch", "fan", "siren" -> "toggle"
    "button", "input_button" -> "press"
    "scene", "script" -> "turn_on"
    else -> null
}

/**
 * Domains whose control opens the detail/control SHEET instead of a single tap,
 * because they are multi-action and/or physical-security devices that must
 * confirm before firing: `cover` (open/stop/close) and `lock` (lock/unlock).
 * A future value-setting control (dimmer/position) will also route here; the
 * backend is on/off/toggle-only today, so there is no such UI yet.
 */
fun haNeedsSheet(domain: String): Boolean = domain == "cover" || domain == "lock"

/** One control action: its wire verb + human caption. */
data class HaAction(val verb: String, val label: String)

/**
 * The FULL action set for a domain, mirroring the server allowlist. A SUPERSET
 * of the default control row: the simple on/off domains include `toggle` (which
 * the default row expresses as a single primary tap), so a link restricted via
 * `allowed_actions` (migration 0075) to exactly `toggle` can still render. Used
 * only for the restricted case; intersected with the link's allowed_actions.
 */
fun haFullActions(domain: String): List<HaAction> = when (domain) {
    "light", "switch", "fan", "siren" -> listOf(
        HaAction("turn_on", "On"),
        HaAction("turn_off", "Off"),
        HaAction("toggle", "Toggle"),
    )
    "cover" -> listOf(
        HaAction("open_cover", "Open"),
        HaAction("stop_cover", "Stop"),
        HaAction("close_cover", "Close"),
    )
    "lock" -> listOf(HaAction("lock", "Lock"), HaAction("unlock", "Unlock"))
    "button", "input_button" -> listOf(HaAction("press", "Press"))
    "scene" -> listOf(HaAction("turn_on", "Activate"))
    "script" -> listOf(HaAction("turn_on", "Run"))
    else -> emptyList()
}

/**
 * Today's DEFAULT control set for a domain (unrestricted link): the simple
 * domains collapse to the single primary tap ([haPrimaryAction]); cover/lock and
 * the rest show their full set. Preserves the exact pre-0075 control row.
 */
fun haDefaultActions(domain: String): List<HaAction> {
    val primary = haPrimaryAction(domain)
    val full = haFullActions(domain)
    return if (primary != null) full.filter { it.verb == primary } else full
}

/**
 * The control actions to present for [this] link, honoring `allowed_actions`
 * (migration 0075): null ⇒ today's default set; non-null ⇒ the full domain set
 * intersected with the permitted verbs (present ONLY those).
 */
fun HaLinkDto.controlActions(): List<HaAction> {
    val allowed = allowedActions ?: return haDefaultActions(domain)
    return haFullActions(domain).filter { it.verb in allowed }
}

/** One entity's live state in the GET /ha/states feed. */
@Serializable
data class HaEntityState(
    @SerialName("entity_id") val entityId: String,
    val state: String,
    @SerialName("last_changed") val lastChanged: String? = null,
    // HA `attributes.unit_of_measurement` for numeric sensors ("°F", "%", "W",
    // ...); null when the entity has no unit (issue #449). Default null so an
    // older server that omits the field still decodes.
    @SerialName("unit") val unit: String? = null,
)

/** GET /ha/states response: the entity states plus cache freshness. */
@Serializable
data class HaStatesResponse(
    @SerialName("fetched_at_ms_ago") val fetchedAtMsAgo: Long = 0,
    val stale: Boolean = false,
    val states: List<HaEntityState> = emptyList(),
) {
    fun stateFor(entityId: String): HaEntityState? = states.firstOrNull { it.entityId == entityId }
}
