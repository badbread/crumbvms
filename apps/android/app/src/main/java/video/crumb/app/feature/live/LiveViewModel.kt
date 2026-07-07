// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import video.crumb.app.data.CameraDto
import video.crumb.app.data.LiveStreamsResponse
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.SecureStore
import video.crumb.app.data.toUserMessage
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import retrofit2.HttpException

/**
 * UiState for the live wall screen.
 *
 * @param loading True while the initial load or a refresh is in progress.
 * @param error Non-null when a non-403 error occurred; shown as a snackbar/banner.
 * @param cameras The list of enabled cameras returned by the API.
 * @param streams Pre-resolved RTSP URLs keyed by camera id so tiles never
 *   individually hit the network on composition.
 * @param isViewerRestricted True when the server replied 403 (cameras endpoint
 *   is admin-only in this build); tiles show an explanatory empty state.
 * @param lowBandwidthMode When true the live wall renders each tile as a
 *   snapshot-polling path instead of RTSP. Persisted in [SecureStore].
 * @param autoFallbackActive True when the wall entered low-bandwidth mode
 *   automatically due to repeated stalls (not by user choice). Drives the
 *   "Low bandwidth — tap to restore" dismissible badge.
 */
data class LiveUiState(
    val loading: Boolean = true,
    val error: String? = null,
    val cameras: List<CameraDto> = emptyList(),
    val streams: Map<String, LiveStreamsResponse> = emptyMap(),
    val isViewerRestricted: Boolean = false,
    val lowBandwidthMode: Boolean = false,
    val autoFallbackActive: Boolean = false,
)

/**
 * ViewModel for [LiveScreen]. Loads the camera list, then fan-out resolves the
 * live RTSP URLs for every camera in parallel. The tile composables receive a
 * ready [LiveStreamsResponse] so they never stall on construction.
 *
 * Also owns the Low-bandwidth mode toggle (snapshot-polling floor for poor links).
 * The mode is persisted via [SecureStore.lowBandwidthMode]; [autoFallbackActive]
 * tracks whether the current low-bw state was triggered automatically (stalls)
 * vs. manually (user toggle) so the UI can show the dismissible badge.
 */
class LiveViewModel(
    private val repo: CrumbRepository,
    private val store: SecureStore,
) : ViewModel() {

    init {
        // One-time fix: an earlier build's stall watchdog could falsely trip the
        // auto-fallback and PERSIST low-bandwidth mode, leaving the wall stuck in it
        // (snapshot polling + the "low bandwidth" Wi-Fi badge on every tile) even on
        // a healthy LAN. The auto-fallback no longer persists; clear the stale flag
        // once so affected installs return to normal RTSP. A deliberate low-bw
        // choice can be re-enabled in Settings. Runs before _uiState reads the store.
        if (!store.lowBwAutofixApplied) {
            store.lowBandwidthMode = false
            store.lowBwAutofixApplied = true
        }
    }

    private val _uiState = MutableStateFlow(
        LiveUiState(lowBandwidthMode = store.lowBandwidthMode),
    )
    val uiState: StateFlow<LiveUiState> = _uiState.asStateFlow()

    // ── auto-fallback stall tracking ─────────────────────────────────────────

    /**
     * Per-camera running stall count reported by tiles via [reportTileStall].
     * When the wall-wide total crosses [AUTO_FALLBACK_STALL_THRESHOLD] within
     * [AUTO_FALLBACK_WINDOW_MS] the wall flips to low-bw mode automatically.
     *
     * Keyed by camera id. Counts reset when the mode is manually restored.
     */
    private val stallCounts = mutableMapOf<String, Int>()

    /**
     * Timestamp of the first stall event in the current observation window (ms).
     * Resets when the window expires or when the mode is manually restored.
     */
    private var windowStartMs = 0L

    /**
     * Timestamp of the last manual restore (ms). The auto-fallback is suppressed
     * for [AUTO_FALLBACK_COOLDOWN_MS] after a manual restore so a single "restore"
     * tap doesn't immediately re-trip on the same stalling wall.
     */
    private var lastManualRestoreMs = 0L

    init {
        refresh()
    }

    /** Reload cameras and re-resolve all RTSP URLs. Safe to call from the UI. */
    fun refresh() {
        viewModelScope.launch {
            _uiState.update { it.copy(loading = true, error = null, isViewerRestricted = false) }

            val camerasResult = repo.visibleCameras()

            camerasResult.fold(
                onSuccess = { cameras ->
                    val enabledCameras = cameras.filter { it.enabled }
                    // Fan-out: resolve streams for all cameras in parallel. Also kick
                    // off (best-effort, fire-and-forget) a scoped-media-token prewarm
                    // for every tile's camera, so each tile's still-frame overlay /
                    // low-bw poll doesn't pay a cold GET /media-token round-trip on
                    // its first frame — by the time a tile's own LaunchedEffect asks
                    // for a URL, the token is very likely already cached.
                    enabledCameras.forEach { cam ->
                        viewModelScope.launch { repo.prewarmMediaToken(cam.id) }
                    }
                    val streams = resolveStreams(enabledCameras)
                    _uiState.update {
                        it.copy(
                            loading = false,
                            cameras = enabledCameras,
                            streams = streams,
                            error = null,
                            isViewerRestricted = false,
                        )
                    }
                },
                onFailure = { cause ->
                    val is403 = cause is HttpException && cause.code() == 403
                    _uiState.update {
                        it.copy(
                            loading = false,
                            cameras = emptyList(),
                            streams = emptyMap(),
                            isViewerRestricted = is403,
                            error = if (is403) null else cause.toUserMessage(),
                        )
                    }
                },
            )
        }
    }

    // ── low-bandwidth mode ────────────────────────────────────────────────────

    /**
     * Manually toggle low-bandwidth mode on or off.
     *
     * When turning OFF (restoring normal streaming), the auto-fallback cooldown
     * is armed so the wall won't immediately re-trip on the same stalling link.
     */
    fun setLowBandwidthMode(enabled: Boolean) {
        store.lowBandwidthMode = enabled
        if (!enabled) {
            // Manual restore: arm the cooldown + clear stall counts so a brief
            // connectivity improvement doesn't immediately re-trigger.
            lastManualRestoreMs = System.currentTimeMillis()
            stallCounts.clear()
            windowStartMs = 0L
        }
        _uiState.update { it.copy(lowBandwidthMode = enabled, autoFallbackActive = false) }
    }

    /**
     * Dismiss the auto-fallback badge without changing the mode.
     * The wall stays in low-bw mode but the banner is hidden.
     */
    fun dismissAutoFallbackBadge() {
        _uiState.update { it.copy(autoFallbackActive = false) }
    }

    /**
     * Called by a tile's stall watchdog (or error path) when that camera's RTSP
     * feed stalls. Accumulates counts and triggers the auto-fallback when enough
     * cameras stall within the observation window.
     *
     * @Synchronized because this is a plain synchronous call that runs on the
     * CALLER's thread — today the main thread (Compose effects), but a future
     * caller from an ExoPlayer/OkHttp callback thread would otherwise mutate the
     * non-thread-safe [stallCounts] HashMap concurrently (review F1).
     */
    @Synchronized
    fun reportTileStall(cameraId: String) {
        // Already in low-bw mode — nothing to do.
        if (_uiState.value.lowBandwidthMode) return

        val now = System.currentTimeMillis()

        // Cooldown: don't re-trip within the window after a manual restore.
        if (now - lastManualRestoreMs < AUTO_FALLBACK_COOLDOWN_MS) return

        // Reset window if it expired.
        if (windowStartMs == 0L || now - windowStartMs > AUTO_FALLBACK_WINDOW_MS) {
            stallCounts.clear()
            windowStartMs = now
        }

        stallCounts[cameraId] = (stallCounts[cameraId] ?: 0) + 1

        // Trip when enough distinct cameras have stalled. Auto-fallback is a
        // SESSION override — do NOT persist it to the store (only a manual toggle
        // does, via setLowBandwidthMode), so a transient network blip or a watchdog
        // misfire can't pin the wall into low-bw mode across launches.
        val distinctStalledCameras = stallCounts.count { it.value >= STALLS_PER_CAMERA_THRESHOLD }
        if (distinctStalledCameras >= AUTO_FALLBACK_STALL_THRESHOLD) {
            _uiState.update { it.copy(lowBandwidthMode = true, autoFallbackActive = true) }
        }
    }

    /**
     * Concurrently fetch [LiveStreamsResponse] for each camera. Individual
     * failures are silently dropped — the tile will show an error state on its
     * own if its URL is missing.
     */
    private suspend fun resolveStreams(
        cameras: List<CameraDto>,
    ): Map<String, LiveStreamsResponse> = coroutineScope {
        cameras
            .map { cam ->
                async {
                    repo.liveStreams(cam.id).getOrNull()?.let { cam.id to it }
                }
            }
            .awaitAll()
            .filterNotNull()
            .toMap()
    }

    companion object {
        /**
         * Number of distinct cameras that must each stall at least
         * [STALLS_PER_CAMERA_THRESHOLD] times within [AUTO_FALLBACK_WINDOW_MS]
         * before the wall auto-switches to low-bw mode.
         *
         * Set to 2 so a single camera's RTSP fault (camera reboot, etc.) doesn't
         * flip the whole wall; we need evidence of a systemic link problem.
         */
        const val AUTO_FALLBACK_STALL_THRESHOLD = 2

        /**
         * A camera must report at least this many stalls to count toward the
         * auto-fallback threshold (avoids a single quick error counting the same
         * camera multiple times from rapid reconnect loops).
         */
        const val STALLS_PER_CAMERA_THRESHOLD = 2

        /**
         * Observation window (ms). Stall counts older than this are discarded.
         * 60 s gives enough time for the watchdog cycles to accumulate evidence
         * of a real link problem vs. a transient burst of reconnects.
         */
        const val AUTO_FALLBACK_WINDOW_MS = 60_000L

        /**
         * Cooldown (ms) after a manual "restore" tap before the auto-fallback
         * can trip again. 5 min — long enough to watch a few segments on a slow
         * link before the wall gives up again if the link is still bad.
         */
        const val AUTO_FALLBACK_COOLDOWN_MS = 5 * 60_000L
    }
}
