// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import video.crumb.app.di.AppContainer
import video.crumb.app.ui.Time
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import retrofit2.HttpException
import java.io.IOException

/**
 * Like [runCatching] but re-throws [CancellationException] instead of capturing
 * it as a `Result.failure`.
 *
 * `runCatching` catches *every* `Throwable`, including coroutine cancellation.
 * When a suspend call here is cancelled mid-flight — e.g. a fast timeline scrub
 * cancels the previous seek's in-flight `resolveSegment` — that cancellation
 * would otherwise become a `Result.failure(CancellationException)`, which the
 * ViewModel's `.onFailure { error = it.toUserMessage() }` surfaces as a bogus
 * "job was cancelled" snackbar. Re-throwing keeps cancellation propagating so
 * structured concurrency works and no error is shown. Every repository call
 * below wraps a cancellable suspend call, so this is a drop-in replacement.
 */
private inline fun <T> runCatchingCancellable(block: () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        Result.failure(e)
    }

/**
 * High-level data operations. Wraps [CrumbApi] + [SecureStore] and returns
 * [Result] so callers (ViewModels) handle success/failure uniformly.
 *
 * All network calls are `suspend` and safe to call from a `viewModelScope`
 * coroutine on `Dispatchers.IO` (Retrofit dispatches its own).
 */
class CrumbRepository(private val container: AppContainer) {

    private val api: CrumbApi get() = container.api
    val store: SecureStore get() = container.store

    fun mediaUrls(): MediaUrls = container.mediaUrls()

    /**
     * Ensure a fresh scoped media token is cached for [cameraId] — e.g. to
     * pre-warm the cache the moment a camera's playback/clip/live view opens, so
     * the FIRST URL build for that camera doesn't have to suspend on a cold
     * fetch. A plain cache hit if already fresh; a network round-trip only on a
     * miss / near-expiry.
     */
    suspend fun prewarmMediaToken(cameraId: String): Result<Unit> =
        runCatchingCancellable { container.mediaTokenCache().freshToken(cameraId); Unit }

    /** Authenticate, persist the token + profile, and rebuild the API for the new server.
     *  [remember] requests a long-lived token so the login survives app restarts and
     *  doesn't expire after the default 1-day window (the save-login feature). */
    suspend fun login(
        server: String,
        username: String,
        password: String,
        remember: Boolean = false,
    ): Result<UserDto> =
        runCatchingCancellable {
            store.serverUrl = server // normalizes + persists
            container.rebuildApi()
            val resp = api.login(LoginRequest(username.trim(), password, remember))
            store.token = resp.token
            val me = api.me()
            store.role = me.role
            store.username = me.username
            store.capabilities = me.effectiveCapabilities
            me
        }.onFailure { store.token = null }

    fun logout() {
        store.clearSession()
        container.clearMediaTokenCache()
    }

    /** Admin-only camera config list (source URLs, policy internals, motion config). */
    suspend fun cameras(): Result<List<CameraDto>> = runCatchingCancellable { api.cameras() }

    /**
     * Viewer-safe camera list. Scoped to the caller by the server; admins see all
     * cameras, viewers see only their permitted cameras with non-sensitive fields.
     * Use this for all live-wall, playback-wall, and playback camera-list loads so
     * viewers never hit a 403 trying to populate the camera UI.
     */
    suspend fun visibleCameras(): Result<List<CameraDto>> = runCatchingCancellable { api.visibleCameras() }

    /** Source-abstracted clip feed (detections + derived motion) for the Clips tab. */
    suspend fun clips(
        cameraIds: List<String>,
        startIso: String,
        endIso: String,
        type: String,
        limit: Int = 200,
    ): Result<ClipsResponse> = runCatchingCancellable {
        if (cameraIds.isEmpty()) return@runCatchingCancellable ClipsResponse()
        api.clips(cameraIds.joinToString(","), startIso, endIso, type, limit)
    }

    /** Mark a clip watched (server-side, per-user). Best-effort — ignores errors. */
    suspend fun markClipViewed(id: String): Result<Unit> =
        runCatchingCancellable { api.markClipViewed(MarkViewedRequest(id)); Unit }

    suspend fun timeline(cameraIds: List<String>, startIso: String, endIso: String): Result<List<RecordedSpan>> =
        runCatchingCancellable { api.timeline(cameraIds.joinToString(","), startIso, endIso).spans }

    /** Per-bucket motion histogram for one camera over [start,end] (drives the
     *  playback timeline's real motion activity rendering, vs the coarse
     *  per-span hasMotion boolean). */
    suspend fun timelineIntensity(
        cameraId: String,
        startIso: String,
        endIso: String,
        buckets: Int = 240,
    ): Result<List<Float>> =
        runCatchingCancellable { api.timelineIntensity(cameraId, startIso, endIso, buckets).buckets }

    /** Combined motion histogram across MANY cameras: the per-bucket MAX of each
     *  camera's intensity, so a multi-camera wall timeline shows "the busiest
     *  camera at that moment" and only goes quiet when EVERY camera is quiet.
     *  Fetches each camera in parallel; a camera that errors contributes nothing
     *  (no bar) rather than failing the whole overlay. */
    suspend fun timelineIntensityCombined(
        cameraIds: List<String>,
        startIso: String,
        endIso: String,
        buckets: Int = 240,
    ): Result<List<Float>> = runCatchingCancellable {
        coroutineScope {
            val perCamera = cameraIds.map { id ->
                async {
                    runCatchingCancellable { api.timelineIntensity(id, startIso, endIso, buckets).buckets }
                        .getOrDefault(emptyList())
                }
            }.awaitAll()
            val combined = FloatArray(buckets)
            for (cam in perCamera) {
                val n = minOf(cam.size, buckets)
                for (i in 0 until n) if (cam[i] > combined[i]) combined[i] = cam[i]
            }
            combined.asList()
        }
    }

    suspend fun resolveSegment(cameraId: String, tsIso: String, stream: String = "main"): Result<ResolvedSegment> =
        runCatchingCancellable { api.play(cameraId, tsIso, stream) }

    /**
     * Next/previous merged motion-event start (epoch-millis) relative to
     * [fromMs], searched server-side across the camera's ENTIRE recorded
     * history — not just the client's loaded window. `null` means there is no
     * event in that direction. This is the primary path for the playback
     * next/prev-motion buttons; see [PlaybackViewModel] for the local-scan
     * fallback used when this call fails (older server / offline).
     */
    suspend fun motionEdge(cameraId: String, fromMs: Long, next: Boolean): Result<Long?> =
        runCatchingCancellable {
            api.motionEdge(
                cameraId = cameraId,
                from = Time.iso(java.time.Instant.ofEpochMilli(fromMs)),
                dir = if (next) "next" else "prev",
            ).start?.let { Time.parseToMillis(it) }
        }

    suspend fun liveStreams(cameraId: String): Result<LiveStreamsResponse> =
        runCatchingCancellable { api.liveStreams(cameraId) }

    // ── motion tuner ───────────────────────────────────────────────────────────
    /** Latest live per-cell motion heatmap (null when none published yet). */
    suspend fun motionGrid(cameraId: String): Result<MotionGridDto?> =
        runCatchingCancellable { api.motionGrid(cameraId) }

    /** Persist motion sensitivity ("dynamic"|"manual") + threshold (%) to the camera's policy. */
    suspend fun updateMotionPolicy(cameraId: String, sensitivity: String, threshold: Float): Result<Unit> =
        runCatchingCancellable { api.updatePolicy(cameraId, UpdatePolicyRequest(sensitivity, threshold)); Unit }

    /** Replace the camera's motion exclusion mask with normalized [x,y,w,h] rects. */
    suspend fun updateMotionMask(cameraId: String, mask: List<List<Double>>): Result<CameraDto> =
        runCatchingCancellable { api.updateCameraMask(cameraId, UpdateCameraMaskRequest(mask)) }

    /** Set the camera's motion source ("pixel"|"frigate") + pixel detector algorithm. */
    suspend fun updateMotionConfig(cameraId: String, source: String, algorithm: String): Result<CameraDto> =
        runCatchingCancellable { api.updateCameraMotion(cameraId, UpdateCameraMotionRequest(source, algorithm)) }

    /** Per-camera recording/motion health (for the live "motion now" icon). */
    suspend fun status(): Result<SystemStatusResponse> = runCatchingCancellable { api.status() }

    // ── PTZ ──────────────────────────────────────────────────────────────────
    /** Probe whether a camera supports PTZ by listing presets (404 → not PTZ). */
    suspend fun ptzPresets(cameraId: String): Result<List<PtzPresetDto>> =
        runCatchingCancellable { api.ptz(cameraId, PtzRequest(action = "presets")).presets }

    /** Continuous move at the given velocities (each in [-1, 1]). */
    suspend fun ptzMove(cameraId: String, pan: Float, tilt: Float, zoom: Float = 0f): Result<Unit> =
        runCatchingCancellable { api.ptz(cameraId, PtzRequest(action = "move", pan = pan, tilt = tilt, zoom = zoom)); Unit }

    /** Stop all PTZ movement. */
    suspend fun ptzStop(cameraId: String): Result<Unit> =
        runCatchingCancellable { api.ptz(cameraId, PtzRequest(action = "stop")); Unit }

    /** Go to the camera's configured home position. */
    suspend fun ptzHome(cameraId: String): Result<Unit> =
        runCatchingCancellable { api.ptz(cameraId, PtzRequest(action = "home")); Unit }

    /** Recall a named preset. */
    suspend fun ptzPreset(cameraId: String, token: String): Result<Unit> =
        runCatchingCancellable { api.ptz(cameraId, PtzRequest(action = "preset", preset = token)); Unit }

    suspend fun filmstrip(cameraId: String, startIso: String, endIso: String, width: Int = 160): Result<List<FilmstripFrame>> =
        runCatchingCancellable { api.filmstrip(cameraId, startIso, endIso, width).frames }

    // ── bookmarks (server-shared) ───────────────────────────────────────────────
    /** All bookmarks (newest first) when [cameraId] is null; else one camera's (oldest first). */
    suspend fun bookmarks(cameraId: String? = null): Result<List<BookmarkDto>> =
        runCatchingCancellable { api.bookmarks(cameraId) }

    suspend fun addBookmark(
        cameraId: String,
        tsIso: String,
        description: String?,
        protectDays: Int? = null,
        protectPreSeconds: Int? = null,
        protectPostSeconds: Int? = null,
    ): Result<BookmarkDto> =
        runCatchingCancellable {
            api.createBookmark(
                CreateBookmarkRequest(
                    cameraId,
                    tsIso,
                    description?.trim()?.ifBlank { null },
                    protectDays,
                    protectPreSeconds,
                    protectPostSeconds,
                ),
            )
        }

    suspend fun deleteBookmark(id: String): Result<Unit> =
        runCatchingCancellable { api.deleteBookmark(id); Unit }

    // ── saved views (server-side, per-user; replaces the old phone-local set) ────
    /** All views visible to the caller, mapped to the phone's [CameraView] shape. */
    suspend fun listViews(): Result<List<CameraView>> =
        runCatchingCancellable { api.views().map { it.toCameraView() } }

    /** Create a view server-side and return it (with the server-assigned id). */
    suspend fun createView(name: String, cameraIds: List<String>): Result<CameraView> =
        runCatchingCancellable { api.createView(CameraView("", name, cameraIds).toCreateRequest()).toCameraView() }

    /** Delete a view by id. */
    suspend fun deleteView(id: String): Result<Unit> =
        runCatchingCancellable { api.deleteView(id); Unit }

    suspend fun createExport(cameraIds: List<String>, startIso: String, endIso: String, burn: Boolean): Result<CreateExportResponse> =
        runCatchingCancellable { api.createExport(CreateExportRequest(cameraIds, startIso, endIso, burn)) }

    suspend fun exportStatus(jobId: String): Result<ExportJob> = runCatchingCancellable { api.exportStatus(jobId) }

    /**
     * Fetch detection events for one camera over a time window.
     *
     * Non-fatal: returns [Result.success] with an empty list when the detection
     * plugin is unconfigured or when no events exist in the window. Callers
     * should always `getOrElse { emptyList() }` to absorb errors gracefully so
     * the timeline renders normally even without detection data.
     */
    suspend fun detectionEvents(
        cameraId: String,
        startIso: String,
        endIso: String,
        limit: Int = 500,
    ): Result<List<DetectionEvent>> = runCatchingCancellable {
        api.events(
            cameraIds = cameraId,
            start = startIso,
            end = endIso,
            limit = limit,
        ).events
            // Motion is shown by the timeline's motion track, not the glyph row;
            // `motion` has no object glyph (it would render as the generic marker).
            // Show OBJECT detections only.
            .filter { it.iconKey.isNotBlank() && it.iconKey != "motion" }
    }

    /**
     * Object types Frigate is CURRENTLY (or just-recently) detecting per camera,
     * for the live-wall detection icons. Returns `cameraId -> distinct icon_keys`.
     *
     * "Active" = in-progress (no `endTs`) OR ended within [lingerMs] (so a brief
     * detection lingers a moment instead of flickering out the instant it ends).
     * Non-fatal: callers should `getOrDefault(emptyMap())` so the wall degrades to
     * plain recording/motion indicators if detection is unconfigured/unreachable.
     */
    suspend fun activeDetections(
        cameraIds: List<String>,
        lingerMs: Long = 8_000L,
    ): Result<Map<String, List<String>>> = runCatchingCancellable {
        if (cameraIds.isEmpty()) return@runCatchingCancellable emptyMap()
        val now = java.time.Instant.now()
        val events = api.events(
            cameraIds = cameraIds.joinToString(","),
            start = now.minusSeconds(25).toString(),
            end = now.plusSeconds(5).toString(),
            limit = 100,
        ).events
        val nowMs = now.toEpochMilli()
        val byCam = LinkedHashMap<String, LinkedHashSet<String>>()
        for (e in events) {
            val active = e.endTs == null ||
                (nowMs - runCatchingCancellable { java.time.Instant.parse(e.endTs).toEpochMilli() }.getOrDefault(0L)) < lingerMs
            if (!active) continue
            // Object detections only — motion isn't an object (no glyph for it).
            if (e.iconKey.isBlank() || e.iconKey == "motion") continue
            byCam.getOrPut(e.cameraId) { LinkedHashSet() }.add(e.iconKey)
        }
        byCam.mapValues { it.value.toList() }
    }

    // ── update-available check (issue #7) ───────────────────────────────────
    /**
     * `GET /updates/latest`. [refresh] forces an immediate re-check ("Check
     * now", §2.5); the server itself rate-limits actual GitHub hits, so this
     * is safe to call repeatedly. A 404 (server predates the endpoint) surfaces
     * as a [Result.failure] — callers should treat that the same as
     * `enabled:false` and show nothing.
     */
    suspend fun updatesLatest(refresh: Boolean = false): Result<UpdateCheckResponse> =
        runCatchingCancellable { api.updatesLatest(if (refresh) "1" else null) }
}

/**
 * True when a repository call failed specifically with HTTP 404.
 *
 * For playback `resolveSegment`, a 404 means "no footage at this instant" — a
 * NORMAL recording gap for a motion-record camera (it only records while motion is
 * present), not an error worth alerting on. Callers use this to show a calm
 * "no footage here" state instead of the error snackbar.
 */
fun Throwable.isNotFound(): Boolean = this is HttpException && code() == 404

/** Map a throwable from a repository call to a human-readable message for the UI. */
fun Throwable.toUserMessage(): String = when (this) {
    is HttpException -> when (code()) {
        401 -> "Session expired or invalid credentials."
        403 -> "You don't have access to this resource."
        404 -> "Not found."
        else -> "Server error (${code()})."
    }
    is IOException -> "Can't reach the server. Check the address and your connection."
    else -> message ?: "Unexpected error."
}
