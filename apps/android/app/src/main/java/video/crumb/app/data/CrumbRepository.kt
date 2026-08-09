// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import video.crumb.app.di.AppContainer
import video.crumb.app.ui.Time
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import retrofit2.HttpException
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.SSLHandshakeException

/**
 * Max cameras accepted by `GET /timeline/intensity/batch` per request — must
 * match the server's `MAX_INTENSITY_BATCH` (services/api/src/timeline.rs),
 * which 400s above this. The multi-camera playback wall can exceed it (e.g.
 * "All Cameras"), so [CrumbRepository.timelineIntensityCombined] splits into
 * chunks of this size, mirroring the desktop
 * (`apps/desktop-flutter/lib/api/motion_timeline_api.dart`) and iOS
 * (`apps/ios/Crumb/Features/Playback/PlaybackViewModel.swift`) clients (#599).
 */
private const val MAX_INTENSITY_BATCH = 64

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
internal inline fun <T> runCatchingCancellable(block: () -> T): Result<T> =
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

    /**
     * Server base URLs whose API 404'd `/timeline/intensity/batch` — i.e. older
     * than the batch endpoint. Keyed by base (not a lone flag) so switching to a
     * different, newer server later in the same process isn't wrongly demoted
     * to the per-camera fallback (#599). Thread-safe: reads/writes can happen
     * from concurrent scrub-triggered loads.
     */
    private val batchUnsupportedBases = ConcurrentHashMap.newKeySet<String>()

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
            // Fetch the profile with a short retry. A TRANSIENT /auth/me failure
            // (network blip, 5xx) must NOT throw away the session we just obtained —
            // fetchMeWithRetry returns null in that case and we keep the token,
            // proceeding with fail-closed defaults until a later /auth/me succeeds.
            // Only a REAL auth rejection (401/403) propagates, tripping the
            // onFailure below that clears the token.
            val me = fetchMeWithRetry()
            if (me != null) {
                store.role = me.role
                store.username = me.username
                store.capabilities = me.effectiveCapabilities
                store.platesEnabled = me.platesEnabled
                me
            } else {
                // Keep the session; record the username so the UI isn't blank. Role/
                // capabilities/plates stay at their fail-closed defaults (viewer, no
                // plates) until the next successful /auth/me.
                store.username = username.trim()
                UserDto(id = "", username = username.trim(), role = store.role ?: "viewer")
            }
        }.onFailure { store.token = null }

    /**
     * `GET /auth/me` with a small retry budget. Returns the profile on success;
     * returns null when it can't be reached after [attempts] tries for a TRANSIENT
     * reason (network [IOException], or a 5xx server error) so the caller can keep
     * the just-obtained session instead of discarding it (#147-8). A genuine auth
     * rejection (HTTP 401/403) is re-thrown immediately — that session really is
     * invalid and must be dropped.
     */
    private suspend fun fetchMeWithRetry(attempts: Int = 3): UserDto? {
        repeat(attempts) { i ->
            try {
                return api.me()
            } catch (e: CancellationException) {
                throw e
            } catch (e: HttpException) {
                // Auth rejection → the token is bad; let it propagate to discard it.
                if (e.code() == 401 || e.code() == 403) throw e
                // Any other HTTP status (5xx, etc.) is transient → fall through/retry.
            } catch (e: IOException) {
                // Network failure → transient → fall through/retry.
            }
            if (i < attempts - 1) delay(300L * (i + 1))
        }
        return null
    }

    fun logout() {
        store.clearSession()
        container.clearMediaTokenCache()
    }

    /** Drop dead pooled sockets on the current client — see
     *  [AppContainer.recoverConnections]. Used by the resume + Retry paths so a
     *  wall that failed against half-open sockets can recover without a
     *  force-close. */
    fun recoverConnections() = container.recoverConnections()

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
     *  Uses the batched `/timeline/intensity/batch` endpoint (chunked, #599)
     *  rather than one request per camera; a camera that errors contributes
     *  nothing (no bar) rather than failing the whole overlay. */
    suspend fun timelineIntensityCombined(
        cameraIds: List<String>,
        startIso: String,
        endIso: String,
        buckets: Int = 240,
    ): Result<List<Float>> = runCatchingCancellable {
        val byId = fetchIntensityBatched(cameraIds, startIso, endIso, buckets)
        combineIntensityMax(byId.values, buckets)
    }

    /**
     * Fetch per-camera intensity buckets for [cameraIds] via the batched
     * `GET /timeline/intensity/batch`, split into <=[MAX_INTENSITY_BATCH]-camera
     * chunks (the server 400s above that; a large "All Cameras" wall can exceed
     * it). This replaces the old N-simultaneous-requests-per-scrub fan-out that
     * tripped the server's shared rate limiter (#599).
     *
     * Falls back to the pre-batch per-camera fan-out ([fetchIntensityPerCamera])
     * on 404 (server predates the batch route) or 400 (unexpected rejection,
     * e.g. a stricter cap on that server), and remembers a 404 per server base so
     * later loads skip the doomed batch attempt for the rest of the session —
     * mirrors the desktop (`motion_timeline_api.dart`) and iOS
     * (`PlaybackViewModel.swift`) clients. Any other per-chunk failure (network
     * blip, 5xx) just leaves that chunk's cameras out of the map rather than
     * failing the whole load, matching the old per-camera error tolerance.
     */
    private suspend fun fetchIntensityBatched(
        cameraIds: List<String>,
        startIso: String,
        endIso: String,
        buckets: Int,
    ): Map<String, List<Float>> {
        val base = store.serverUrl
        if (base in batchUnsupportedBases) {
            return fetchIntensityPerCamera(cameraIds, startIso, endIso, buckets)
        }
        val merged = mutableMapOf<String, List<Float>>()
        for (chunk in cameraIds.chunked(MAX_INTENSITY_BATCH)) {
            try {
                merged.putAll(
                    api.timelineIntensityBatch(chunk.joinToString(","), startIso, endIso, buckets).cameras,
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: HttpException) {
                if (e.code() == 404 || e.code() == 400) {
                    if (e.code() == 404) batchUnsupportedBases.add(base)
                    // Older/incompatible server: fall back to the per-camera fan-out
                    // for every requested camera, not just the remaining chunks.
                    return fetchIntensityPerCamera(cameraIds, startIso, endIso, buckets)
                }
                // Any other HTTP failure is transient for this chunk only; leave
                // its cameras out of the map and keep going.
            } catch (e: IOException) {
                // Network failure for this chunk only; same tolerance as above.
            }
        }
        return merged
    }

    /** Pre-batch per-camera fan-out — the fallback for a server older than the
     *  batch route (or one that unexpectedly rejects it). One request per
     *  camera, in parallel, same as before #599; a camera that errors
     *  contributes nothing rather than failing the whole overlay. */
    private suspend fun fetchIntensityPerCamera(
        cameraIds: List<String>,
        startIso: String,
        endIso: String,
        buckets: Int,
    ): Map<String, List<Float>> = coroutineScope {
        cameraIds
            .map { id ->
                async {
                    id to runCatchingCancellable { api.timelineIntensity(id, startIso, endIso, buckets).buckets }
                        .getOrDefault(emptyList())
                }
            }
            .awaitAll()
            .toMap()
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

    /** Home Assistant entities linked to a camera. Empty when HA is not set up. */
    suspend fun haLinks(cameraId: String): Result<List<HaLinkDto>> =
        runCatchingCancellable { api.haLinks(cameraId) }

    /** Live HA entity states (demand-cached on the server). */
    suspend fun haStates(): Result<HaStatesResponse> =
        runCatchingCancellable { api.haStates() }

    /**
     * Fire an HA service call ([action], e.g. "toggle"/"open_cover"/"unlock") for
     * a linked entity ([linkId]) on [cameraId]. [value] is the one numeric a
     * value action carries (#442, Slice 1: `set_brightness`/`set_position`/
     * `set_speed`, a 0..100 percent the server validates and rounds) — omit it
     * for discrete actions. Success is a bare 200 `{ok:true}`; we don't flip
     * state locally — the `/ha/states` poll converges the shown state. A
     * capability/validation/HA-unreachable rejection is a [Result.failure] the
     * UI turns into a compact error via [toUserMessage].
     */
    suspend fun haAction(cameraId: String, linkId: String, action: String, value: Double? = null): Result<Unit> =
        runCatchingCancellable { api.haAction(cameraId, HaActionRequest(linkId, action, value)); Unit }

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

    // ── license-plate reads (LPR) ───────────────────────────────────────────────
    /**
     * Newest-first plate reads for [cameraIds] over an optional [startIso,endIso]
     * window (both null = all time), optionally filtered by [query]/[match].
     * Short-circuits to an empty page when [cameraIds] is empty (the endpoint
     * requires `camera_ids`) — the Plates screen's "no cameras selected" state
     * relies on this rather than surfacing an error.
     */
    suspend fun plates(
        cameraIds: List<String>,
        startIso: String? = null,
        endIso: String? = null,
        query: String? = null,
        match: String = "contains",
        limit: Int = 200,
        offset: Int = 0,
    ): Result<PlatesResponse> = runCatchingCancellable {
        if (cameraIds.isEmpty()) return@runCatchingCancellable PlatesResponse()
        val q = query?.trim()?.ifBlank { null }
        api.plates(
            cameraIds = cameraIds.joinToString(","),
            start = startIso,
            end = endIso,
            query = q,
            // `match` is only meaningful with a non-blank query — omit it otherwise
            // so an empty search doesn't accidentally narrow results server-side.
            match = if (q != null) match else null,
            limit = limit,
            offset = offset,
        )
    }

    // ── LPR plate watchlist ──────────────────────────────────────────────────────
    /**
     * The plate watchlist (plates that raise an alert when seen). Readable by any
     * caller with the `view_plates` capability — the same gate as [plates].
     */
    suspend fun watchlist(): Result<List<PlateWatchlistEntry>> =
        runCatchingCancellable { api.watchlist() }

    /**
     * Add [plate] to the watchlist, or edit the existing entry keyed on the same
     * normalized plate. **Admin-only** server-side — a non-admin caller's
     * [Result] fails with HTTP 403 ([Throwable.isForbidden]). Blank optional
     * fields are dropped so they serialize as absent rather than empty strings.
     */
    suspend fun addWatchlist(
        plate: String,
        label: String? = null,
        note: String? = null,
        color: String? = null,
        notify: Boolean = true,
        kind: String = WATCHLIST_KIND_WATCH,
    ): Result<PlateWatchlistEntry> =
        runCatchingCancellable {
            api.addWatchlist(
                AddWatchlistRequest(
                    plate = plate.trim(),
                    label = label?.trim()?.ifBlank { null },
                    note = note?.trim()?.ifBlank { null },
                    color = color?.trim()?.ifBlank { null },
                    notify = notify,
                    kind = kind,
                ),
            )
        }

    /** Remove a watchlist entry by id. **Admin-only** server-side (403 for non-admin). */
    suspend fun deleteWatchlist(id: String): Result<Unit> =
        runCatchingCancellable {
            // Retrofit does NOT throw for non-2xx on Response<T>, so surface the
            // error explicitly — otherwise the admin-only 403 (stale role) or any
            // server error would report a false success while the entry survives.
            // 404 means already gone → treat as success.
            val r = api.deleteWatchlist(id)
            if (!r.isSuccessful && r.code() != 404) throw HttpException(r)
            Unit
        }

    // ── LPR config (admin-only) ──────────────────────────────────────────────────
    /**
     * Platform LPR settings (enable flag, retention, watchlist fuzziness).
     * **Admin-only** server-side — a non-admin caller's [Result] fails with HTTP
     * 403 ([Throwable.isForbidden]).
     */
    suspend fun lprConfig(): Result<LprConfigDto> =
        runCatchingCancellable { api.lprConfig() }

    /**
     * Update the platform LPR settings. **Admin-only** (403 for non-admin). The
     * PUT replaces all writable fields, so the caller must pass the current
     * [enabled]/[retentionDays] alongside the changed [watchlistFuzz] — editing
     * fuzziness alone must not clobber the other two. The server clamps
     * [retentionDays] (1..3650) and [watchlistFuzz] (0.0..0.5).
     */
    suspend fun updateLprConfig(
        enabled: Boolean,
        retentionDays: Int,
        watchlistFuzz: Float,
    ): Result<LprConfigDto> =
        runCatchingCancellable {
            api.updateLprConfig(LprConfigUpdate(enabled, retentionDays, watchlistFuzz))
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
 * Per-bucket MAX across a set of per-camera intensity arrays, sized to
 * [buckets]. Pulled out of [CrumbRepository.timelineIntensityCombined] as a
 * pure function so the merge math (the part most likely to regress) is
 * testable without standing up the full [CrumbRepository]/[AppContainer]
 * dependency chain (#599). A camera's array shorter than [buckets] (e.g. an
 * error-tolerant fallback entry) contributes only over its own length.
 */
internal fun combineIntensityMax(perCamera: Collection<List<Float>>, buckets: Int): List<Float> {
    val combined = FloatArray(buckets)
    for (cam in perCamera) {
        val n = minOf(cam.size, buckets)
        for (i in 0 until n) if (cam[i] > combined[i]) combined[i] = cam[i]
    }
    return combined.asList()
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

/**
 * True when a repository call failed specifically with HTTP 403 (forbidden).
 *
 * The LPR watchlist mutations (`POST`/`DELETE /lpr/watchlist`) are admin-only; a
 * non-admin viewer gets a 403. Callers use this to show a calm "only admins can
 * manage the watchlist" message instead of the generic error snackbar.
 */
fun Throwable.isForbidden(): Boolean = this is HttpException && code() == 403

/** Map a throwable from a repository call to a human-readable message for the UI. */
fun Throwable.toUserMessage(): String = when (this) {
    is HttpException -> when (code()) {
        401 -> "Session expired or invalid credentials."
        403 -> "You don't have access to this resource."
        404 -> "Not found."
        else -> "Server error (${code()})."
    }
    // Checked before the generic IOException branch below (SSLHandshakeException
    // is an IOException) — server discovery can surface an https:// candidate
    // whose self-signed cert the real (validating) client then refuses; without
    // this the failure fell through to the generic "can't reach" message with no
    // hint that the actual problem is an untrusted certificate.
    is SSLHandshakeException ->
        "Certificate isn't trusted. Try the http:// address instead, or install the server's CA."
    is IOException -> "Can't reach the server. Check the address and your connection."
    else -> message ?: "Unexpected error."
}
