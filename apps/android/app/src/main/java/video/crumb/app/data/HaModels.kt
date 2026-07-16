// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Home Assistant link + state DTOs. Mirror the subset of the server shapes the
// mobile sheet needs; the JSON layer has `ignoreUnknownKeys = true`, so the
// desktop-only overlay placement fields (overlay_x/y/size/color/icon/...) on
// the server's HaLinkDto are simply dropped here.

/** One HA entity linked to a camera (GET /cameras/{id}/ha/links). */
@Serializable
data class HaLinkDto(
    val id: String,
    @SerialName("entity_id") val entityId: String,
    val role: String,
    @SerialName("device_class") val deviceClass: String? = null,
    val label: String? = null,
    @SerialName("sort_order") val sortOrder: Int = 0,
) {
    /** The HA domain — the part before the dot in `light.porch`. */
    val domain: String get() = entityId.substringBefore('.', "")

    /** Display caption: the operator's label, else the entity id. */
    val displayName: String get() = label?.takeIf { it.isNotBlank() } ?: entityId
}

/** One entity's live state in the GET /ha/states feed. */
@Serializable
data class HaEntityState(
    @SerialName("entity_id") val entityId: String,
    val state: String,
    @SerialName("last_changed") val lastChanged: String? = null,
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
