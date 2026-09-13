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
 * @property submitting True from the moment [ExportViewModel.createExport] is called
 *   until its `POST /export` round-trip resolves (success or failure). Distinct from
 *   [polling], which only flips true AFTER that round-trip completes — without this,
 *   a fast double-tap on Create before the first response lands could submit two
 *   export jobs (the guard in [ExportViewModel.createExport] checked [polling] too
 *   late to catch it).
 * @property cancelling True while a `DELETE /export/{job_id}` is in flight.
 * @property notice A neutral, non-error status line (e.g. "Export cancelled.").
 *   Kept apart from [jobError] so a deliberate cancel isn't shown in danger red.
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
    val submitting: Boolean = false,
    val cancelling: Boolean = false,
    val notice: String? = null,
) {
    /** True when the current window is one the server will accept (`start` < `end`). */
    val rangeValid: Boolean get() = ExportRange.isValid(startMs, endMs)
}

/**
 * ViewModel for the Export screen.
 *
 * Loads cameras, manages clip-range selection, submits the export job, and
 * polls for completion. Also provides per-output authenticated download URLs.
 *
 * @param seedCameraId Camera to pre-select (blank = none). Applied before the
 *   camera list arrives, so it survives the load.
 * @param seedStartMs Clip-window start to pre-fill (epoch-millis; ≤ 0 = keep the
 *   screen's own default).
 * @param seedEndMs Clip-window end to pre-fill (epoch-millis; ≤ 0 = keep the default).
 */
class ExportViewModel(
    private val repo: CrumbRepository,
    seedCameraId: String = "",
    seedStartMs: Long = 0L,
    seedEndMs: Long = 0L,
) : ViewModel() {

    private val _state = MutableStateFlow(
        ExportUiState().let { base ->
            val seeded = if (seedStartMs > 0L && seedEndMs > 0L &&
                ExportRange.isValid(seedStartMs, seedEndMs)
            ) {
                base.copy(startMs = seedStartMs, endMs = seedEndMs)
            } else {
                base
            }
            if (seedCameraId.isNotBlank()) {
                seeded.copy(selectedCameraIds = setOf(seedCameraId))
            } else {
                seeded
            }
        },
    )
    val state: StateFlow<ExportUiState> = _state.asStateFlow()

    private var pollJob: Job? = null

    /** Id of the job currently being polled, kept so Cancel works after a poll blip. */
    private var activeJobId: String? = null

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
            s.copy(startMs = ExportRange.clampStart(epochMs, s.endMs))
        }
    }

    fun setEnd(epochMs: Long) {
        _state.update { s ->
            // Clamp: end must be after start
            s.copy(endMs = ExportRange.clampEnd(epochMs, s.startMs))
        }
    }

    /**
     * Set both boundaries at once (quick-range chips, or a seeded hand-off). The
     * pair is ordered and widened to the minimum the server accepts, so a chip can
     * never produce an inverted or zero-length window.
     */
    fun setRange(startEpochMs: Long, endEpochMs: Long) {
        val (a, b) = ExportRange.normalize(startEpochMs, endEpochMs)
        _state.update { it.copy(startMs = a, endMs = ExportRange.clampEnd(b, a)) }
    }

    /** Apply a "Last N minutes" quick range ending now. */
    fun applyQuickRange(minutes: Int) {
        val (start, end) = ExportRange.quickRange(Instant.now().toEpochMilli(), minutes)
        setRange(start, end)
    }

    fun setBurn(enabled: Boolean) {
        _state.update { it.copy(burn = enabled) }
    }

    // ─── export job ─────────────────────────────────────────────────────────

    fun createExport() {
        val s = _state.value
        if (s.selectedCameraIds.isEmpty()) return
        if (!s.rangeValid) return // the server rejects start >= end; don't spend a round-trip
        if (s.polling || s.submitting) return // already running or already in flight
        // Set synchronously, BEFORE the coroutine launch, so a fast double-tap on
        // Create can't slip a second submit in during the POST round-trip (polling
        // alone doesn't flip true until that round-trip completes).
        _state.update { it.copy(submitting = true) }

        val startIso = Time.iso(Instant.ofEpochMilli(s.startMs))
        val endIso = Time.iso(Instant.ofEpochMilli(s.endMs))

        viewModelScope.launch {
            // Reset any previous job state before submitting.
            activeJobId = null
            _state.update { it.copy(job = null, jobError = null, notice = null, polling = false) }

            repo.createExport(
                cameraIds = s.selectedCameraIds.toList(),
                startIso = startIso,
                endIso = endIso,
                burn = s.burn,
            ).onSuccess { response ->
                activeJobId = response.jobId
                _state.update { it.copy(polling = true, submitting = false) }
                startPolling(response.jobId)
            }.onFailure { t ->
                _state.update { it.copy(jobError = t.toUserMessage(), submitting = false) }
            }
        }
    }

    /**
     * Cancel the job currently being polled (`DELETE /export/{job_id}`). The server
     * aborts ffmpeg and cleans the partial output up; cancelling a job that has
     * already finished is an idempotent success, so a race with completion is safe.
     *
     * Polling stops locally on success and the job card is cleared back to a plain
     * "Export cancelled." notice rather than a red failure.
     */
    fun cancelExport() {
        val jobId = activeJobId ?: _state.value.job?.id ?: return
        if (_state.value.cancelling) return
        _state.update { it.copy(cancelling = true) }
        viewModelScope.launch {
            repo.cancelExport(jobId)
                .onSuccess {
                    pollJob?.cancel()
                    pollJob = null
                    activeJobId = null
                    _state.update {
                        it.copy(
                            cancelling = false,
                            polling = false,
                            submitting = false,
                            job = null,
                            jobError = null,
                            notice = "Export cancelled.",
                        )
                    }
                }
                .onFailure { t ->
                    _state.update { it.copy(cancelling = false, jobError = t.toUserMessage()) }
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
                        // A job cancelled server-side (by this client, another
                        // session, or the operator's own DELETE) is terminal too —
                        // without this the poll loop would spin forever on it.
                        if (job.isTerminal || job.looksCancelled) {
                            activeJobId = null
                            _state.update { it.copy(polling = false) }
                            if (job.looksCancelled) {
                                _state.update {
                                    it.copy(job = null, notice = "Export cancelled.")
                                }
                            } else if (job.isFailed) {
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

    override fun onCleared() {
        super.onCleared()
        pollJob?.cancel()
    }

    companion object {
        private const val POLL_INTERVAL_MS = 1_500L
    }
}

/**
 * Whether the server reports this job as cancelled.
 *
 * Read off [ExportJob.status] here rather than assuming a model-level flag, so
 * this compiles against the current [ExportJob] and stays correct once a
 * dedicated `isCancelled` property lands alongside `isTerminal`.
 */
private val ExportJob.looksCancelled: Boolean
    get() = status.equals("cancelled", ignoreCase = true)
