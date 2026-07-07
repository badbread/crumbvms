// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.export

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import video.crumb.app.data.CameraDto
import video.crumb.app.data.ExportJob
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.toUserMessage
import video.crumb.app.ui.Time
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * UI state for the export screen.
 *
 * @property loadingCameras True while the initial camera list is being fetched.
 * @property error Non-null when a non-fatal camera-load error should be shown (e.g. 403 shows
 *   an access-denied banner rather than crashing).
 * @property cameras The list of cameras available to this user; may be empty on 403.
 * @property selectedCameraIds The set of camera IDs the user has checked.
 * @property startMs Clip start as epoch-milliseconds (editable).
 * @property endMs Clip end as epoch-milliseconds (editable); defaults to now.
 * @property burn Whether to bake the timestamp into the exported video.
 * @property job The most recent [ExportJob] returned by the server (null until created).
 * @property jobError Human-readable error string when the job itself fails.
 * @property polling True while we are actively polling exportStatus.
 * @property downloadMsg Transient confirmation shown after triggering a DownloadManager enqueue.
 */
data class ExportUiState(
    val loadingCameras: Boolean = true,
    val error: String? = null,
    val cameras: List<CameraDto> = emptyList(),
    val selectedCameraIds: Set<String> = emptySet(),
    val startMs: Long = Instant.now().minusSeconds(600).toEpochMilli(),
    val endMs: Long = Instant.now().toEpochMilli(),
    val burn: Boolean = true,
    val job: ExportJob? = null,
    val jobError: String? = null,
    val polling: Boolean = false,
    val downloadMsg: String? = null,
)

/**
 * ViewModel for the Export screen.
 *
 * Loads cameras, manages clip-range selection, submits the export job, and
 * polls for completion. Also provides per-output authenticated download URLs.
 */
class ExportViewModel(private val repo: CrumbRepository) : ViewModel() {

    private val _state = MutableStateFlow(ExportUiState())
    val state: StateFlow<ExportUiState> = _state.asStateFlow()

    private var pollJob: Job? = null

    init {
        loadCameras()
    }

    // ─── camera loading ──────────────────────────────────────────────────────

    fun loadCameras() {
        viewModelScope.launch {
            _state.update { it.copy(loadingCameras = true, error = null) }
            repo.visibleCameras()
                .onSuccess { cameras ->
                    _state.update { it.copy(loadingCameras = false, cameras = cameras) }
                }
                .onFailure { t ->
                    _state.update {
                        it.copy(
                            loadingCameras = false,
                            cameras = emptyList(),
                            error = t.toUserMessage(),
                        )
                    }
                }
        }
    }

    // ─── selection + form ───────────────────────────────────────────────────

    fun toggleCamera(cameraId: String) {
        _state.update { s ->
            val updated = if (cameraId in s.selectedCameraIds) {
                s.selectedCameraIds - cameraId
            } else {
                s.selectedCameraIds + cameraId
            }
            s.copy(selectedCameraIds = updated)
        }
    }

    fun setStart(epochMs: Long) {
        _state.update { s ->
            // Clamp: start must be before end
            val clamped = minOf(epochMs, s.endMs - 1_000L)
            s.copy(startMs = clamped)
        }
    }

    fun setEnd(epochMs: Long) {
        _state.update { s ->
            // Clamp: end must be after start
            val clamped = maxOf(epochMs, s.startMs + 1_000L)
            s.copy(endMs = clamped)
        }
    }

    fun setBurn(enabled: Boolean) {
        _state.update { it.copy(burn = enabled) }
    }

    // ─── export job ─────────────────────────────────────────────────────────

    fun createExport() {
        val s = _state.value
        if (s.selectedCameraIds.isEmpty()) return
        if (s.polling) return // already running

        val startIso = Time.iso(Instant.ofEpochMilli(s.startMs))
        val endIso = Time.iso(Instant.ofEpochMilli(s.endMs))

        viewModelScope.launch {
            // Reset any previous job state before submitting.
            _state.update { it.copy(job = null, jobError = null, polling = false, downloadMsg = null) }

            repo.createExport(
                cameraIds = s.selectedCameraIds.toList(),
                startIso = startIso,
                endIso = endIso,
                burn = s.burn,
            ).onSuccess { response ->
                _state.update { it.copy(polling = true) }
                startPolling(response.jobId)
            }.onFailure { t ->
                _state.update { it.copy(jobError = t.toUserMessage()) }
            }
        }
    }

    private fun startPolling(jobId: String) {
        pollJob?.cancel()
        pollJob = viewModelScope.launch {
            var failStreak = 0
            while (isActive) {
                // Back off on consecutive failures (1.5s→3s→6s, cap ~12s) so a flaky
                // link doesn't poll a healthy job hard, and don't cry "Export failed"
                // on a single dropped packet — surface only after a few in a row, and
                // CLEAR the transient error on the next success (review D2). The hard
                // failure path stays reserved for job.isFailed.
                delay((POLL_INTERVAL_MS shl failStreak.coerceAtMost(3)).coerceAtMost(12_000L))
                repo.exportStatus(jobId)
                    .onSuccess { job ->
                        failStreak = 0
                        _state.update { it.copy(job = job, jobError = null) }
                        if (job.isTerminal) {
                            _state.update { it.copy(polling = false) }
                            if (job.isFailed) {
                                _state.update {
                                    it.copy(jobError = job.error ?: "Export failed.")
                                }
                            }
                            return@launch
                        }
                    }
                    .onFailure { t ->
                        failStreak += 1
                        if (failStreak >= 3) {
                            _state.update { it.copy(jobError = t.toUserMessage()) }
                        }
                    }
            }
        }
    }

    // ─── download / share helpers ───────────────────────────────────────────

    /**
     * Returns an authenticated URL for the given output file's download path,
     * carrying the full login JWT (NOT a per-camera scoped token — an export can
     * span multiple cameras/archive stages, which a scoped token can't authorize).
     * Called from the UI immediately before enqueueing / sharing.
     */
    fun authedUrl(rawDownloadUrl: String): String =
        repo.mediaUrls().authed(rawDownloadUrl, repo.store.token)

    /** Acknowledge the transient download confirmation banner. */
    fun clearDownloadMsg() {
        _state.update { it.copy(downloadMsg = null) }
    }

    /** Called by the UI after successfully enqueueing a DownloadManager request. */
    fun onDownloadEnqueued(cameraId: String) {
        _state.update {
            it.copy(downloadMsg = "Download started for camera $cameraId.")
        }
    }

    override fun onCleared() {
        super.onCleared()
        pollJob?.cancel()
    }

    companion object {
        private const val POLL_INTERVAL_MS = 1_500L
    }
}
