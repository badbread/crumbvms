// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Wire models for the Crumb API. Field names mirror the Rust `dto.rs`
 * (snake_case on the wire via [SerialName]). Timestamps are kept as RFC-3339
 * strings and parsed with `java.time.Instant` where math is needed.
 *
 * The JSON parser is configured with `ignoreUnknownKeys = true`, so these
 * classes only declare the fields the client actually consumes.
 */

// ─── auth ───────────────────────────────────────────────────────────────────

@Serializable
data class LoginRequest(
    val username: String,
    val password: String,
    /** "Keep me signed in": when true the server mints a long-lived token so the
     *  session survives well past the default 1-day expiry (the save-login feature). */
    val remember: Boolean = false,
)

@Serializable
data class LoginResponse(
    val token: String,
    @SerialName("expires_at") val expiresAt: String,
)

/**
 * `GET /media-token?camera=<id>` response — a short-lived (~15 min) token scoped
 * to exactly ONE camera, valid only as `?token=` on that camera's media
 * endpoints (server-validated via `try_media_token`). Minted from the full
 * login JWT (sent in the `Authorization` header) and cached client-side by
 * [MediaTokenCache] so per-camera media URLs never carry the long-lived JWT.
 */
@Serializable
data class MediaTokenResponse(
    val token: String,
    @SerialName("camera_id") val cameraId: String,
    @SerialName("expires_at") val expiresAt: String,
)

/**
 * Per-role capability set returned by `GET /auth/me`.
 *
 * All fields default to the most-restrictive value so that clients talking to an
 * older server (which omits the `capabilities` object) degrade gracefully: an
 * admin sees everything regardless (gated by [UserDto.isAdmin]), and a viewer who
 * gets no capabilities object is shown only live.
 *
 * [bookmarks] mirrors `/status.bookmarks_enabled` at the per-user level:
 * - `"none"` — no bookmark access (hide all bookmark UI)
 * - `"own"` — can create/delete own bookmarks only
 * - `"all"` — can manage all users' bookmarks
 *
 * The platform-wide `/status.bookmarks_enabled` toggle still controls whether the
 * UI shows bookmarks at all; this per-user field refines it further.
 */
@Serializable
data class CapabilitiesDto(
    /** May export footage to a downloadable archive. */
    val export: Boolean = false,
    /** May access the recorded-playback timeline. */
    val playback: Boolean = false,
    /** May access the Clips tab (motion/detection clip feed). */
    val clips: Boolean = false,
    /** May use PTZ controls on cameras that support it. */
    val ptz: Boolean = false,
    /** May create/edit custom camera views. */
    @SerialName("manage_views") val manageViews: Boolean = false,
    /** Bookmark access level: "none", "own", or "all". */
    val bookmarks: String = "none",
)

@Serializable
data class UserDto(
    val id: String,
    val username: String,
    /** "admin" or "viewer". */
    val role: String,
    @SerialName("camera_ids") val cameraIds: List<String> = emptyList(),
    /** Server-asserted admin flag (authoritative; prefer over role-string comparison). */
    @SerialName("is_admin") val isAdminFlag: Boolean? = null,
    /** Fine-grained capability set. Absent on older servers → defaults to all-false
     *  (admins bypass this via [isAdmin]; viewers fall back to live-only). */
    val capabilities: CapabilitiesDto = CapabilitiesDto(),
) {
    /**
     * True when this user has full admin access. Checks the explicit [isAdminFlag]
     * first (set by servers that support RBAC); falls back to the role string for
     * backward-compat with older servers that only return `role`.
     */
    val isAdmin: Boolean get() = isAdminFlag ?: role.equals("admin", ignoreCase = true)

    /**
     * Effective capability set. Admins implicitly have every capability enabled;
     * viewers are governed by the server-sent [capabilities] object.
     */
    val effectiveCapabilities: CapabilitiesDto get() = if (isAdmin) {
        CapabilitiesDto(
            export = true,
            playback = true,
            clips = true,
            ptz = true,
            manageViews = true,
            bookmarks = "all",
        )
    } else {
        capabilities
    }
}

// ─── cameras ─────────────────────────────────────────────────────────────────

@Serializable
data class CameraDto(
    val id: String,
    val name: String,
    val enabled: Boolean = true,
    /**
     * go2rtc stream name. Present in the admin `GET /config/cameras` response.
     * The viewer-safe `GET /cameras` endpoint may omit this field (viewers don't
     * need internal stream plumbing); defaults to empty so deserialization never
     * fails on viewer responses.
     */
    @SerialName("go2rtc_name") val go2rtcName: String = "",
    @SerialName("sub_url") val subUrl: String? = null,
    /** Motion source: "pixel" (local analysis) or "frigate" (neural detections). */
    @SerialName("motion_source") val motionSource: String = "pixel",
    /** Pixel detector when source is "pixel": census/framediff/mog2/opticalflow/ensemble. */
    @SerialName("motion_algorithm") val motionAlgorithm: String = "census",
    /** Embedded recording policy — only the motion fields are consumed (tuner). Admin only. */
    val policy: PolicyDto? = null,
    /**
     * Motion exclusion mask. Normalized `[x,y,w,h]` rects (and/or legacy polygons).
     * Kept as raw JSON so a legacy polygon doesn't fail deserialization; the
     * motion tuner parses out the rects. Admin only.
     */
    @SerialName("motion_mask") val motionMask: kotlinx.serialization.json.JsonElement? = null,
) {
    /** Whether a sub (low-res) stream is configured — drives grid stream choice. */
    val hasSubStream: Boolean get() = subUrl != null
}

/** Subset of the recording policy consumed by the motion tuner + live wall. */
@Serializable
data class PolicyDto(
    /** Manual-mode motion floor as a FRACTION of frame area (0..1) — same unit as
     *  the score; the UI shows it as `× 100` = %. */
    @SerialName("motion_threshold") val motionThreshold: Float? = null,
    /** "dynamic" (auto) or "manual". */
    @SerialName("motion_sensitivity") val motionSensitivity: String = "dynamic",
    /** Record mode: "continuous" (always recording while online → REC dot always on)
     *  or "motion" (only records during a motion event → REC dot only when motion now). */
    @SerialName("mode") val mode: String = "continuous",
)

/** `GET /cameras/{id}/motion-grid` — live per-cell motion heatmap (0..100, row-major),
 *  plus the recorder's actual largest-blob score + effective floor (fractions 0..1). */
@Serializable
data class MotionGridDto(
    val cols: Int = 0,
    val rows: Int = 0,
    val cells: List<Float> = emptyList(),
    val score: Float = 0f,
    val threshold: Float = 0f,
)

/** `PUT /config/cameras/{id}/policy` body — motion sensitivity + threshold only. */
@Serializable
data class UpdatePolicyRequest(
    @SerialName("motion_sensitivity") val motionSensitivity: String,
    /** Fraction of frame area (0..1). */
    @SerialName("motion_threshold") val motionThreshold: Float,
)

/** `PUT /config/cameras/{id}` body — replace the motion exclusion mask. */
@Serializable
data class UpdateCameraMaskRequest(
    @SerialName("motion_mask") val motionMask: List<List<Double>>,
)

/** `PUT /config/cameras/{id}` body — set the per-camera motion source + (pixel)
 *  detector algorithm. Other camera fields are left unchanged by the backend. */
@Serializable
data class UpdateCameraMotionRequest(
    @SerialName("motion_source") val motionSource: String,
    @SerialName("motion_algorithm") val motionAlgorithm: String,
)

// ─── PTZ ─────────────────────────────────────────────────────────────────────

/**
 * Request body for `POST /cameras/:id/ptz`. Mirrors the Rust `PtzRequest`.
 * `action` is one of: "move", "stop", "preset", "home", "presets".
 * For "move", pan/tilt/zoom are velocities in [-1, 1]. For "preset", set [preset].
 */
@Serializable
data class PtzRequest(
    val action: String,
    val pan: Float = 0f,
    val tilt: Float = 0f,
    val zoom: Float = 0f,
    val preset: String? = null,
)

@Serializable
data class PtzPresetDto(
    val token: String,
    val name: String = "",
)

@Serializable
data class PtzResponse(
    val presets: List<PtzPresetDto> = emptyList(),
)

// ─── timeline ────────────────────────────────────────────────────────────────

@Serializable
data class RecordedSpan(
    @SerialName("camera_id") val cameraId: String,
    val start: String,
    val end: String,
    @SerialName("has_motion") val hasMotion: Boolean,
    val stage: String,
)

@Serializable
data class TimelineResponse(
    val spans: List<RecordedSpan> = emptyList(),
    /** Total spans available before pagination (added with /timeline pagination). */
    val total: Int = 0,
    @SerialName("has_more") val hasMore: Boolean = false,
)

/**
 * Response for `GET /timeline/intensity` — one 0..1 motion-magnitude value per
 * time bucket across the requested window. This is the granular per-segment
 * motion data (backed by `segments.motion_score`) that drives a real activity
 * histogram, as opposed to [RecordedSpan.hasMotion] which is a single boolean
 * OR'd over a whole merged span (useless for continuous recording).
 */
@Serializable
data class IntensityResponse(
    val buckets: List<Float> = emptyList(),
)

/**
 * Wire envelope for `GET /timeline/motion` — the leading edge of the next/
 * previous merged motion event relative to a reference time, searched across
 * ALL recorded history. `start == null` means there is no event that way.
 */
@Serializable
data class MotionEdgeResponse(
    val start: String? = null,
)

// ─── playback ────────────────────────────────────────────────────────────────

@Serializable
data class ResolvedSegment(
    @SerialName("camera_id") val cameraId: String,
    @SerialName("segment_id") val segmentId: String,
    /** Relative URL the client fetches, e.g. `/segments/{id}`. */
    val url: String,
    val start: String,
    val end: String,
    @SerialName("duration_ms") val durationMs: Int,
    @SerialName("has_motion") val hasMotion: Boolean,
)

// ─── live ────────────────────────────────────────────────────────────────────

@Serializable
data class LiveStreamsResponse(
    @SerialName("camera_id") val cameraId: String,
    @SerialName("webrtc_main_url") val webrtcMainUrl: String? = null,
    @SerialName("webrtc_sub_url") val webrtcSubUrl: String? = null,
    @SerialName("rtsp_main_url") val rtspMainUrl: String,
    @SerialName("rtsp_sub_url") val rtspSubUrl: String? = null,
    /**
     * On-demand low-res H.264 transcode for cellular "Data saver" fullscreen live.
     * `null` when the server has the feature disabled or the camera is
     * Frigate-served. Nullable-with-default so older servers deserialize cleanly.
     */
    @SerialName("rtsp_mobile_url") val rtspMobileUrl: String? = null,
)

// ─── export ──────────────────────────────────────────────────────────────────

@Serializable
data class CreateExportRequest(
    @SerialName("camera_ids") val cameraIds: List<String>,
    val start: String,
    val end: String,
    @SerialName("burn_timestamp") val burnTimestamp: Boolean = true,
)

@Serializable
data class CreateExportResponse(
    @SerialName("job_id") val jobId: String,
    @SerialName("status_url") val statusUrl: String,
)

@Serializable
data class ExportOutputFile(
    @SerialName("camera_id") val cameraId: String,
    @SerialName("download_url") val downloadUrl: String,
    @SerialName("size_bytes") val sizeBytes: Long,
)

@Serializable
data class ExportJob(
    val id: String,
    /** "queued" | "running" | "done" | "failed". */
    val status: String,
    @SerialName("camera_ids") val cameraIds: List<String> = emptyList(),
    val start: String,
    val end: String,
    @SerialName("output_files") val outputFiles: List<ExportOutputFile> = emptyList(),
    val error: String? = null,
    @SerialName("progress_pct") val progressPct: Int = 0,
) {
    val isDone: Boolean get() = status.equals("done", ignoreCase = true)
    val isFailed: Boolean get() = status.equals("failed", ignoreCase = true)
    val isTerminal: Boolean get() = isDone || isFailed
}

// ─── filmstrip ───────────────────────────────────────────────────────────────

@Serializable
data class FilmstripFrame(
    val ts: String,
    /** Relative URL, e.g. `/filmstrip/{camera_id}/frame?ts=...`. */
    val url: String,
)

@Serializable
data class FilmstripResponse(
    @SerialName("camera_id") val cameraId: String,
    val frames: List<FilmstripFrame> = emptyList(),
)

// ─── bookmarks ─────────────────────────────────────────────────────────────────

/** A saved playback moment (camera + time + optional note), shared server-side. */
@Serializable
data class BookmarkDto(
    val id: String,
    @SerialName("camera_id") val cameraId: String,
    /** Joined camera name (present on the cross-camera list; null otherwise). */
    @SerialName("camera_name") val cameraName: String? = null,
    /** RFC-3339 instant of the bookmarked moment. */
    val ts: String,
    val description: String? = null,
    /** RFC-3339 expiry while the clip is protected from auto-delete (null = not protected). */
    @SerialName("protect_until") val protectUntil: String? = null,
    @SerialName("created_at") val createdAt: String,
)

/** `POST /bookmarks` body. */
@Serializable
data class CreateBookmarkRequest(
    @SerialName("camera_id") val cameraId: String,
    val ts: String,
    val description: String? = null,
    /** Protected retention: keep the clip for N days (1..30); null/0 = not protected. */
    @SerialName("protect_days") val protectDays: Int? = null,
    @SerialName("protect_pre_seconds") val protectPreSeconds: Int? = null,
    @SerialName("protect_post_seconds") val protectPostSeconds: Int? = null,
)

// ─── detection events ────────────────────────────────────────────────────────

/**
 * A single detection event returned by `GET /events`.
 *
 * [ts] and [endTs] are ISO 8601 strings. Callers convert via
 * `java.time.Instant.parse(event.ts).toEpochMilli()`.
 *
 * [iconKey] is server-derived from [label]: it is the per-label slug itself
 * (e.g. `person`, `car`, `truck`, `bus`, `bicycle`, `cat`, `dog`,
 * `license_plate`, `face`, `package`, …). Unknown / future labels keep their own
 * slug; the client maps each via [DetectionIcons] and falls back to a generic
 * marker. See `docs/DETECTION-ICONS.md`.
 */
@Serializable
data class DetectionEvent(
    val id: String,
    @SerialName("camera_id") val cameraId: String,
    /** ISO 8601 detection start timestamp. */
    val ts: String,
    /** ISO 8601 tracking end timestamp, or null while the event is in progress. */
    @SerialName("end_ts") val endTs: String? = null,
    val label: String,
    @SerialName("icon_key") val iconKey: String,
    @SerialName("sub_label") val subLabel: String? = null,
    val score: Float = 0f,
    @SerialName("top_score") val topScore: Float = 0f,
    val zones: List<String> = emptyList(),
    @SerialName("snapshot_url") val snapshotUrl: String? = null,
    @SerialName("source_id") val sourceId: String = "",
)

/** Wire envelope for `GET /events`. */
@Serializable
data class DetectionEventsResponse(
    val events: List<DetectionEvent> = emptyList(),
    val total: Int = 0,
    @SerialName("has_more") val hasMore: Boolean = false,
)

// ─── system status ─────────────────────────────────────────────────────────────

/** `GET /status` — only the per-camera fields the client needs (storages,
 *  recorder heartbeat, etc. are ignored via ignoreUnknownKeys). */
@Serializable
data class SystemStatusResponse(
    val cameras: List<CameraStatusEntry> = emptyList(),
    /** Opaque server config fingerprint; when it changes the client re-fetches the
     *  camera list + reconnects, so server-side edits (stream URLs, mode, …) apply
     *  without a manual refresh. */
    @SerialName("config_version") val configVersion: String = "",
    /** Platform-wide bookmarks-UI toggle. When false, clients hide the bookmark
     *  button(s). Defaults true so older servers (no field) keep showing them. */
    @SerialName("bookmarks_enabled") val bookmarksEnabled: Boolean = true,
)

@Serializable
data class CameraStatusEntry(
    val id: String,
    val recording: Boolean = false,
    /** Motion within the freshness window — drives the live "motion now" icon. */
    @SerialName("recent_motion") val recentMotion: Boolean = false,
)

// ─── update-available check (issue #7) ──────────────────────────────────────

/**
 * `GET /updates/latest` response. Mirrors the Rust `UpdateCheckResponse`
 * (`services/api/src/dto.rs`) exactly — see `docs/UPDATE-SYSTEM-PLAN.md` §2.1/§2.5.
 *
 * `enabled == false` means the operator has turned the check off (or this
 * server predates the feature, in which case the repository layer treats a
 * 404 the same way): every other field is then null and the client shows
 * nothing. While enabled, [latestVersion]/[notesUrl]/[publishedAt]/[checkedAt]
 * are only null in the narrow case where the server has never completed a
 * GitHub fetch yet.
 */
@Serializable
data class UpdateCheckResponse(
    val enabled: Boolean = false,
    /** Newest stable release tag from GitHub, without the leading `v`. */
    @SerialName("latest_version") val latestVersion: String? = null,
    /** GitHub release page URL (release notes). */
    @SerialName("notes_url") val notesUrl: String? = null,
    @SerialName("published_at") val publishedAt: String? = null,
    /** The server's own build version — unused by this client, which compares
     *  [latestVersion] against its OWN `BuildConfig.VERSION_NAME` instead. */
    @SerialName("server_version") val serverVersion: String? = null,
    @SerialName("server_update_available") val serverUpdateAvailable: Boolean? = null,
    @SerialName("checked_at") val checkedAt: String? = null,
)

// ─── saved views (server-side, per-user; the same /views the desktop/web use) ──

/**
 * A saved view as returned by `GET /views`. The server model is richer than the
 * phone's [CameraView] (it carries a grid `layout` and a `slots` map whose values
 * may be a bare camera-id string OR a full view-item spec object created on
 * desktop). The phone only consumes the ordered camera ids — see [toCameraView].
 */
@Serializable
data class ViewDto(
    val id: String,
    val name: String,
    val layout: String = "auto",
    val slots: JsonObject = JsonObject(emptyMap()),
    @SerialName("owner_id") val ownerId: String? = null,
)

/** `POST /views` body. Cameras are encoded as bare-string slots `{"0": id, …}` so
 *  the `{slotIndex: cameraId}` contract shared with web/desktop stays clean. */
@Serializable
data class CreateViewRequest(
    val name: String,
    val layout: String = "auto",
    val slots: JsonObject,
)

/** Pull one slot value's camera id: a bare string, or the `cameraId` of a richer
 *  desktop view-item spec (carousel/ptz/hotspot); null for anything else. */
private fun slotCameraId(v: JsonElement): String? = when (v) {
    is JsonPrimitive -> if (v.isString) v.content else null
    is JsonObject -> (v["cameraId"] as? JsonPrimitive)?.takeIf { it.isString }?.content
    else -> null
}

/** Server view → phone [CameraView]: ordered camera ids from the `slots` map
 *  (numeric slot key order), skipping non-camera view-items. */
fun ViewDto.toCameraView(): CameraView =
    CameraView(
        id = id,
        name = name,
        cameraIds = slots.entries
            .mapNotNull { (k, v) -> k.toIntOrNull()?.let { idx -> slotCameraId(v)?.let { idx to it } } }
            .sortedBy { it.first }
            .map { it.second },
    )

/** Phone [CameraView] → create request (cameras become ordered bare-string slots). */
fun CameraView.toCreateRequest(): CreateViewRequest =
    CreateViewRequest(
        name = name,
        layout = "auto",
        slots = buildJsonObject { cameraIds.forEachIndexed { i, camId -> put(i.toString(), camId) } },
    )
