// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.Serializable

/**
 * A locally-saved Live-wall **view**: a named, ordered subset of cameras.
 *
 * Phone-local ONLY — persisted in [SecureStore], never synced to the server (a
 * deliberate choice: these are a per-device convenience for grouping cameras, e.g.
 * "Inside" / "Outside", and don't belong to the shared server `/views`). Layout is
 * intentionally NOT part of a view: the wall renders a view's cameras with whatever
 * column count the user has toggled.
 *
 * @property id Stable local id (random UUID) used to select / edit / delete.
 * @property name Display label shown on the view chip.
 * @property cameraIds Camera ids in display order. Ids no longer present on the
 *   server are simply skipped when rendering, so deleting a camera can't break a
 *   saved view.
 */
@Serializable
data class CameraView(
    val id: String,
    val name: String,
    val cameraIds: List<String>,
)
