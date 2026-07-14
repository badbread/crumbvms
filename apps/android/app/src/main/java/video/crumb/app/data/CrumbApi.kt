// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * Retrofit interface for the Crumb JSON API.
 *
 * Authentication: the [AuthInterceptor] adds `Authorization: Bearer <token>`
 * (the login JWT) to every request except `/auth/login`. Media bytes (segments,
 * filmstrip frames, camera/clip stills, clip video) are NOT fetched here — they
 * go straight to ExoPlayer / Coil as absolute URLs with a `?token=` query param
 * (see [MediaUrls]), because those clients can't set an auth header.
 *
 * For a single per-camera resource, that query-string token is now the
 * **short-lived scoped media token** minted by [mediaToken] and cached by
 * [MediaTokenCache] — NOT the long-lived login JWT — so per-camera media URLs
 * never leak the full-privilege token into proxy/access logs or `<img>`/player
 * sources. Export downloads are the one exception: they can span multiple
 * cameras/archive stages, so they keep using the login JWT via
 * [MediaUrls.authed] directly.
 */
interface CrumbApi {

    @POST("auth/login")
    suspend fun login(@Body body: LoginRequest): LoginResponse

    @GET("auth/me")
    suspend fun me(): UserDto

    /**
     * Mint a short-lived (~15 min), single-camera **scoped media token**. Called
     * WITH the full login JWT in the `Authorization` header (added by
     * [video.crumb.app.data.Network]'s interceptor); the returned [MediaTokenResponse.token]
     * is valid only as `?token=` on media endpoints for [cameraId] — never the
     * full-privilege login JWT. See [MediaTokenCache], which fetches + caches
     * this per camera so URL construction stays synchronous where it needs to be.
     */
    @GET("media-token")
    suspend fun mediaToken(@Query("camera") cameraId: String): MediaTokenResponse

    /** Admin-only. Returns the full camera config including sensitive fields (source URLs,
     *  policy internals, motion config). Use [visibleCameras] for viewer-safe camera lists. */
    @GET("config/cameras")
    suspend fun cameras(): List<CameraDto>

    /**
     * Viewer-safe camera list. Scoped to the caller: admins receive all cameras,
     * viewers receive only their permitted cameras with non-sensitive fields.
     * Replaces [cameras] for all live-wall, playback, and clip camera-list loads.
     */
    @GET("cameras")
    suspend fun visibleCameras(): List<CameraDto>

    @GET("timeline")
    suspend fun timeline(
        @Query("camera_ids") cameraIds: String,
        @Query("start") start: String,
        @Query("end") end: String,
    ): TimelineResponse

    /**
     * Per-bucket motion-magnitude histogram for one camera over [start,end].
     * Drives the playback timeline's real motion activity rendering (vs the
     * coarse per-span [RecordedSpan.hasMotion] boolean).
     */
    @GET("timeline/intensity")
    suspend fun timelineIntensity(
        @Query("camera_id") cameraId: String,
        @Query("start") start: String,
        @Query("end") end: String,
        @Query("buckets") buckets: Int = 240,
    ): IntensityResponse

    /**
     * The leading edge of the next/previous merged motion EVENT relative to
     * [from], searched across ALL recorded history (server-side; same
     * semantics as the desktop client's primary path). Viewer-scoped: returns
     * `start: null` (not 403) for a camera the caller can't access.
     */
    @GET("timeline/motion")
    suspend fun motionEdge(
        @Query("camera_id") cameraId: String,
        @Query("from") from: String,          // ISO 8601
        @Query("dir") dir: String,            // "next" | "prev"
    ): MotionEdgeResponse

    /** Resolve the segment covering [ts] for a camera. `stream` defaults to "main". */
    @GET("play/{camera_id}")
    suspend fun play(
        @Path("camera_id") cameraId: String,
        @Query("ts") ts: String,
        @Query("stream") stream: String = "main",
    ): ResolvedSegment

    @GET("cameras/{camera_id}/streams")
    suspend fun liveStreams(@Path("camera_id") cameraId: String): LiveStreamsResponse

    /** Live per-cell motion heatmap for the tuner. `null` if the recorder has not
     *  published one yet (e.g. no sub-stream / motion disabled). */
    @GET("cameras/{camera_id}/motion-grid")
    suspend fun motionGrid(@Path("camera_id") cameraId: String): MotionGridDto?

    /** Update a camera's motion sensitivity + threshold (copy-on-write per camera). Admin-only. */
    @PUT("config/cameras/{camera_id}/policy")
    suspend fun updatePolicy(
        @Path("camera_id") cameraId: String,
        @Body body: UpdatePolicyRequest,
    ): PolicyDto

    /** Replace a camera's motion exclusion mask. Admin-only. */
    @PUT("config/cameras/{camera_id}")
    suspend fun updateCameraMask(
        @Path("camera_id") cameraId: String,
        @Body body: UpdateCameraMaskRequest,
    ): CameraDto

    /** Set a camera's motion source + (pixel) detector algorithm. Admin-only. */
    @PUT("config/cameras/{camera_id}")
    suspend fun updateCameraMotion(
        @Path("camera_id") cameraId: String,
        @Body body: UpdateCameraMotionRequest,
    ): CameraDto

    /** Per-camera recording/motion health (drives the live "motion now" icon). */
    @GET("status")
    suspend fun status(): SystemStatusResponse

    /** PTZ control. Returns presets when action="presets"; `{}` otherwise (404 if not PTZ). */
    @POST("cameras/{camera_id}/ptz")
    suspend fun ptz(@Path("camera_id") cameraId: String, @Body body: PtzRequest): PtzResponse

    @GET("filmstrip/{camera_id}")
    suspend fun filmstrip(
        @Path("camera_id") cameraId: String,
        @Query("start") start: String,
        @Query("end") end: String,
        @Query("width") width: Int = 160,
    ): FilmstripResponse

    /** Saved playback moments. Omit [cameraId] for the cross-camera list (newest
     *  first); pass it for one camera's markers (oldest first). */
    @GET("bookmarks")
    suspend fun bookmarks(@Query("camera_id") cameraId: String? = null): List<BookmarkDto>

    @POST("bookmarks")
    suspend fun createBookmark(@Body body: CreateBookmarkRequest): BookmarkDto

    @DELETE("bookmarks/{id}")
    suspend fun deleteBookmark(@Path("id") id: String): Response<Unit>

    @POST("export")
    suspend fun createExport(@Body body: CreateExportRequest): CreateExportResponse

    @GET("export/{job_id}")
    suspend fun exportStatus(@Path("job_id") jobId: String): ExportJob

    /**
     * Fetch detection events for one or more cameras over a time window.
     *
     * Returns an empty [DetectionEventsResponse] when the detection plugin is
     * unconfigured or when no events fall in the window — never an error.
     *
     * @param cameraIds CSV of camera UUIDs (e.g. "uuid1,uuid2").
     * @param start ISO 8601 window start.
     * @param end ISO 8601 window end.
     * @param limit Maximum number of events to return (default 500, max 2000).
     * @param offset Pagination offset (default 0).
     */
    @GET("events")
    suspend fun events(
        @Query("camera_ids") cameraIds: String,
        @Query("start") start: String,
        @Query("end") end: String,
        @Query("limit") limit: Int = 500,
        @Query("offset") offset: Int = 0,
    ): DetectionEventsResponse

    /** Source-abstracted clip feed (detections + derived motion) for the Clips tab. */
    @GET("clips")
    suspend fun clips(
        @Query("camera_ids") cameraIds: String,
        @Query("start") start: String,
        @Query("end") end: String,
        @Query("type") type: String = "all",
        @Query("limit") limit: Int = 200,
    ): ClipsResponse

    @POST("clips/viewed")
    suspend fun markClipViewed(@Body body: MarkViewedRequest)

    /**
     * License-plate reads (LPR) for the Plates tab — newest-first over
     * [cameraIds] (further viewer-scoped server-side; the route requires
     * `camera_ids`). [query]/[match] filter by plate text
     * ("exact"|"prefix"|"contains"|"fuzzy"); meaningful only when [query] is
     * non-blank. Never errors for scoping/disabled reasons — an empty or
     * LPR-disabled server returns an empty page.
     */
    @GET("plates")
    suspend fun plates(
        @Query("camera_ids") cameraIds: String,
        @Query("start") start: String? = null,
        @Query("end") end: String? = null,
        @Query("q") query: String? = null,
        @Query("match") match: String? = null,
        @Query("limit") limit: Int = 200,
        @Query("offset") offset: Int = 0,
    ): PlatesResponse

    // ── LPR plate watchlist ──────────────────────────────────────────────────────
    /**
     * The plate watchlist — plates that raise an alert when seen. Readable by any
     * caller with the `view_plates` capability (same gate as [plates]).
     */
    @GET("lpr/watchlist")
    suspend fun watchlist(): List<PlateWatchlistEntry>

    /**
     * Add a plate to the watchlist, or edit the existing entry when the
     * normalized plate already exists (the server keys on the normalized plate).
     * **Admin-only** — a non-admin viewer gets HTTP 403.
     */
    @POST("lpr/watchlist")
    suspend fun addWatchlist(@Body body: AddWatchlistRequest): PlateWatchlistEntry

    /** Remove a watchlist entry by id (204 on success, 404 if already gone).
     *  **Admin-only** — a non-admin viewer gets HTTP 403. */
    @DELETE("lpr/watchlist/{id}")
    suspend fun deleteWatchlist(@Path("id") id: String): Response<Unit>

    // ── LPR config (admin-only) ──────────────────────────────────────────────────
    /** Platform LPR settings (enable flag, retention, watchlist fuzziness).
     *  **Admin-only** — a non-admin caller gets HTTP 403. */
    @GET("config/lpr")
    suspend fun lprConfig(): LprConfigDto

    /** Update the platform LPR settings. **Admin-only** (HTTP 403 otherwise).
     *  The body carries all writable fields — the PUT replaces them wholesale. */
    @PUT("config/lpr")
    suspend fun updateLprConfig(@Body body: LprConfigUpdate): LprConfigDto

    // ── saved views (server-side, per-user; shared with desktop/web) ────────────
    /** Views visible to the caller: own + legacy-global + shared (admins: all). */
    @GET("views")
    suspend fun views(): List<ViewDto>

    /** Create a view owned by the caller. Requires the `manage_views` capability. */
    @POST("views")
    suspend fun createView(@Body body: CreateViewRequest): ViewDto

    /** Delete a view (owner or admin only). */
    @DELETE("views/{id}")
    suspend fun deleteView(@Path("id") id: String): Response<Unit>

    /**
     * Update-available check (issue #7). Any authenticated user (viewers run
     * wall displays and phones too). `enabled:false` means the operator has
     * turned the check off — every other field is then null and the client
     * shows nothing. An older server that predates this endpoint returns 404,
     * which the repository layer treats the same way.
     *
     * @param refresh Pass `"1"` to force an immediate re-check ("Check now",
     *   `docs/UPDATE-SYSTEM-PLAN.md` §2.5) bypassing the server's 6h cache —
     *   itself rate-limited server-side to one actual GitHub hit per 60s.
     *   Omit for the normal cached lookup.
     */
    @GET("updates/latest")
    suspend fun updatesLatest(@Query("refresh") refresh: String? = null): UpdateCheckResponse
}
