// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** One clip in the source-abstracted `/clips` feed (detection or motion). */
@Serializable
data class ClipDescriptor(
    /** Opaque handle: `d:<event>` or `m:<cam>:<start>:<end>`. */
    val id: String,
    @SerialName("camera_id") val cameraId: String,
    @SerialName("camera_name") val cameraName: String = "",
    /** `"detection"` | `"motion"`. */
    val kind: String,
    val label: String = "",
    @SerialName("icon_key") val iconKey: String = "generic",
    val score: Float? = null,
    @SerialName("start_ts") val startTs: String,
    @SerialName("end_ts") val endTs: String,
    @SerialName("duration_ms") val durationMs: Long = 0,
    @SerialName("thumbnail_url") val thumbnailUrl: String,
    /** Lightweight preview MP4 (reduced res/fps) — the feed default. */
    @SerialName("clip_url") val clipUrl: String,
    /** Full-resolution MP4 for an explicit "full quality" action. */
    @SerialName("download_url") val downloadUrl: String = "",
    /** `"frigate"` | `"crumb"`. */
    val source: String = "crumb",
    /** True if the current user has already opened this clip (watched-dimming). */
    val viewed: Boolean = false,
    /**
     * Normalized `[x, y, w, h]` (0..1 of the frame) of where the motion was, for
     * the motion-highlight auto-zoom. Present for motion clips that captured a
     * region; null for detections and bbox-less motion clips.
     */
    @SerialName("motion_bbox") val motionBbox: List<Float>? = null,
)

@Serializable
data class ClipsResponse(
    val clips: List<ClipDescriptor> = emptyList(),
    val total: Int = 0,
    /**
     * Server-configured motion-highlight duration (seconds; 0 = disabled). The
     * clip player auto-zooms to [ClipDescriptor.motionBbox] for this long at the
     * start of a motion clip, then eases back to the full frame.
     */
    @SerialName("motion_highlight_seconds") val motionHighlightSeconds: Int = 0,
)

/** Body for `POST /clips/viewed`. */
@Serializable
data class MarkViewedRequest(val id: String)
