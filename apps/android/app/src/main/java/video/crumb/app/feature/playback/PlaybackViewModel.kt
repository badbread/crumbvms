// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import video.crumb.app.data.DetectionEvent
import video.crumb.app.data.FilmstripFrame
import video.crumb.app.data.RecordedSpan
import video.crumb.app.data.ResolvedSegment
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.isNotFound
import video.crumb.app.data.toUserMessage
import video.crumb.app.ui.Time
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * UI state for the single-camera playback screen.
 *
 * @property loading True while the initial timeline load is in progress.
 * @property error Non-null when an unrecoverable error should be surfaced.
 * @property cameraName Display name resolved from [CrumbRepository.cameras]; falls back to the raw id.
 * @property spans Recorded spans within the current time window.
 * @property windowStartMs Epoch-millis for the left edge of the visible timeline window.
 * @property windowEndMs Epoch-millis for the right edge of the visible timeline window.
 * @property playheadMs Current playback position as epoch-millis.
 * @property currentSegment The resolved segment currently being played, or null when idle.
 * @property currentSegmentUrl Absolute authed URL ready for ExoPlayer, derived from [currentSegment].
 * @property segmentOffsetMs How far into [currentSegment] the playhead sits; used to seek ExoPlayer.
 * @property nextSegment The next segment pre-resolved by [PlaybackViewModel.prefetchNextSegment]
 *   while [currentSegment] is still playing, so the screen can queue it on the ExoPlayer
 *   playlist ahead of time and transition gaplessly instead of hitting `STATE_ENDED` and
 *   waiting on a fresh network resolve. Null until prefetched; cleared once consumed.
 * @property nextSegmentUrl Absolute authed URL for [nextSegment].
 * @property playing Whether playback is running (maps to player.playWhenReady).
 * @property speed Playback rate; one of 0.5f, 1f, 2f, 4f, 8f.
 * @property filmstrip Thumbnails fetched around the current scrub position.
 * @property scrubbing True while the user is dragging the timeline scrubber.
 * @property scrubFrameUrl The filmstrip frame URL nearest the current scrub position (authed).
 * @property jumpInProgress True while a motion-event step (see [PlaybackViewModel.stepMotion])
 *   is resolving. The screen pauses the player and suppresses every OTHER playhead
 *   writer ([PlaybackViewModel.onPlaybackTick], [PlaybackViewModel.onSegmentEnded],
 *   [PlaybackViewModel.onAdvancedToNextSegment]) for the duration, so nothing but the
 *   step itself can move [playheadMs] (closes the playhead-overwrite race).
 */
data class PlaybackUiState(
    val loading: Boolean = true,
    val error: String? = null,
    /** Id of the camera currently being reviewed (drives the screen's swipe nav). */
    val cameraId: String = "",
    val cameraName: String? = null,
    val spans: List<RecordedSpan> = emptyList(),
    val windowStartMs: Long = 0L,
    val windowEndMs: Long = 0L,
    val playheadMs: Long = 0L,
    val currentSegment: ResolvedSegment? = null,
    val currentSegmentUrl: String? = null,
    val segmentOffsetMs: Long = 0L,
    val nextSegment: ResolvedSegment? = null,
    val nextSegmentUrl: String? = null,
    val playing: Boolean = false,
    val speed: Float = 1f,
    val filmstrip: List<FilmstripFrame> = emptyList(),
    val scrubbing: Boolean = false,
    val scrubFrameUrl: String? = null,
    val jumpInProgress: Boolean = false,
    /**
     * True when the resolve at [playheadMs] returned 404 — there is simply no
     * footage at this instant (a NORMAL recording gap for a motion-record camera,
     * which only records while motion is present). The UI shows a calm "No footage
     * at this time" message and does NOT raise the error snackbar. Distinct from
     * [error], which is reserved for genuine failures (network / 5xx / auth).
     */
    val noFootageAtPlayhead: Boolean = false,
    /** Visible time span of the centered timeline (pinch-to-zoom). */
    val visibleSpanMs: Long = 60L * 60_000L,
    /**
     * Per-bucket motion magnitude across [motionStartMs, motionEndMs] from
     * `/timeline/intensity`. Each value is 0 (no motion) or the peak changed-pixel
     * fraction for that time bucket. THIS is what gives the timeline real motion
     * granularity — the old `RecordedSpan.hasMotion` boolean collapses an entire
     * continuous recording to one all-or-nothing color (the "static bar" bug).
     */
    val motionBuckets: List<Float> = emptyList(),
    val motionStartMs: Long = 0L,
    val motionEndMs: Long = 0L,
    /**
     * Detection events fetched from `GET /events` for the current camera and
     * time window. Empty when the detection plugin is unconfigured or when no
     * events exist. The timeline icon layer is invisible when this list is empty.
     */
    val detectionEvents: List<DetectionEvent> = emptyList(),
)

private val SPEED_STEPS = listOf(0.5f, 1f, 2f, 4f, 8f)
private const val DEFAULT_WINDOW_HOURS = 6L
private const val MIN_SPAN_MS = 60_000L            // 1 min (max zoom-in)
private const val MAX_SPAN_MS = DEFAULT_WINDOW_HOURS * 3600_000L // = data window (max zoom-out)
private const val FILMSTRIP_HALF_WINDOW_HOURS = 1L
private const val FILMSTRIP_DEBOUNCE_MS = 300L
private const val NEXT_SEGMENT_LOOKAHEAD_MS = 1L

/**
 * How close to the end of the current segment (in playhead time) the screen
 * should trigger [PlaybackViewModel.prefetchNextSegment]. Segments are short
 * (~4s), so this needs to be small enough not to fire immediately on entry but
 * comfortably ahead of a resolve round-trip on a slow link.
 */
private const val PREFETCH_LEAD_MS = 2_000L

/**
 * Motion histogram resolution over the loaded data window. 1440 buckets across
 * the 6 h window ≈ 15 s/bucket (~3–4 segments each), so motion is visible at
 * fine grain even when zoomed in to a few minutes.
 */
private const val MOTION_BUCKETS = 1440

/**
 * A bucket value at/above this counts as "motion" for the jump-to-motion
 * buttons — matches the server's `motion_event_edge` floor
 * (`services/common/src/db.rs`) and desktop's `TL_MOTION_ABS`
 * (`apps/desktop/src/app.js`). Deliberately the SAME constant the server uses
 * so the buttons never skip motion the timeline renders as visible (the old
 * 0.006 vs render-floor-0.0025 mismatch).
 */
private const val MOTION_EVENT_FLOOR = 0.004f

/**
 * Sub-threshold gaps up to this long are bridged into the SAME motion event
 * (fallback local scan only — the server does this merge in SQL). Matches
 * the server's 8 s coalescing window and desktop's `COALESCE_GAP_MS`, so one
 * real-world motion with a brief dip isn't split into several "events".
 */
private const val MOTION_MERGE_GAP_MS = 8_000L

/**
 * Epsilon subtracted/added to the anchor before searching for the next/prev
 * event edge, so a just-landed anchor (sitting exactly on an event start)
 * doesn't immediately re-match itself. Bigger than typical seek/keyframe
 * jitter; safely inside one 15 s fallback bucket.
 */
private const val STEP_EPSILON_MS = 1_000L

/**
 * How far before a motion event's start the step lands, so the user always
 * sees the motion BEGIN rather than landing after it's already underway.
 * Clamped into the recorded span containing the event (never lands in a gap).
 */
private const val PRE_ROLL_MS = 3_000L

/** Live-edge threshold: within this of the wall clock, treat the playhead as
 *  "at the live edge" — the anchor for a motion step is `min(playheadMs, now)`
 *  and the server (which sees segments written after the client's window
 *  load) is trusted over any locally-cached data. */
private const val LIVE_EDGE_THRESHOLD_MS = 10_000L

/**
 * ViewModel for single-camera recorded playback.
 *
 * Responsibilities:
 * - Maintains the time window and loads timeline spans.
 * - Resolves segments on demand (seek, segment-ended, motion jump).
 * - Debounces filmstrip fetches during scrubbing.
 * - Exposes all state the UI needs to drive ExoPlayer and the timeline scrubber.
 */
class PlaybackViewModel(
    initialCameraId: String,
    private val repo: CrumbRepository,
    initialTimeMs: Long = 0L,
) : ViewModel() {

    // The camera currently being reviewed. Mutable so Playback can act as a
    // standalone mode: a camera picker or a swipe gesture calls [switchCamera] to
    // re-target the SAME ViewModel (and player) at another camera, rather than the
    // screen being locked to the one camera it was opened with.
    private var cameraId: String = initialCameraId

    // A one-shot seed time (epoch-millis) for the VERY FIRST camera open — set when
    // entered from the playback wall scrubbed to a past moment. Consumed once (then
    // zeroed) so later camera switches use the normal preserve-time / latest logic.
    private var pendingSeedMs: Long = initialTimeMs

    /** The id of the camera currently shown (for the screen's swipe-nav math). */
    val currentCameraId: String get() = cameraId

    private val _state = MutableStateFlow(PlaybackUiState())
    val state: StateFlow<PlaybackUiState> = _state.asStateFlow()

    private var filmstripJob: Job? = null
    private var seekJob: Job? = null
    private var timelineJob: Job? = null
    private var prefetchJob: Job? = null

    // ── Motion-event stepping (see `docs/ANDROID-MOTION-EVENT-NAV-FIX.md`) ──────
    // Logical anchor for next/prev-motion stepping: the START of the event the
    // last step landed on (NOT the pre-rolled seek position — otherwise prev/next
    // become asymmetric around PRE_ROLL_MS). Null means "derive from current
    // playback time"; invalidated by anything else that moves the playhead
    // (scrub, jumpToTime, gotoFirst/Last, camera switch).
    private var stepAnchorMs: Long? = null

    // Single worker coroutine that serializes button presses. A press just
    // enqueues a direction on [pendingSteps] and (re)starts the worker if it
    // isn't already running — rapid presses coalesce into ONE pause→resolve→
    // seek→play at the FINAL anchor instead of each firing its own racing seek.
    private var stepJob: Job? = null
    private val pendingSteps = Channel<Int>(capacity = 8)

    // One-shot feedback for terminal/clamped steps (first/last event, no motion
    // data, offline fallback exhausted) — the screen collects this into its
    // snackbar. Never a silent no-op (RC5).
    private val _toast = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val toast: SharedFlow<String> = _toast.asSharedFlow()

    init {
        startCamera(initialCameraId, preserveTime = false)
    }

    /**
     * (Re)initialise all state for [camId]. Resets only the PER-CAMERA data/overlays
     * (spans, motion histogram, detection events, segment, filmstrip) so the previous
     * camera's footage doesn't bleed through. Zoom and speed always carry over.
     *
     * @param preserveTime when true (a camera switch made WHILE reviewing footage),
     *   keep the current time window + playhead and resolve the new camera's segment
     *   at the SAME instant — so you can review the same moment from another angle.
     *   When false (first entry, or before any footage has resolved), open a window
     *   around "now" and jump to the new camera's latest footage.
     */
    private fun startCamera(camId: String, preserveTime: Boolean) {
        cameraId = camId
        // Kick off the scoped media-token fetch for this camera immediately, in
        // parallel with the state resets below — by the time seekTo()/loadFilmstrip()
        // need it to build a URL, it's very likely already cached. Best-effort: a
        // failure here just means the first URL build pays the fetch cost itself.
        viewModelScope.launch { repo.prewarmMediaToken(camId) }
        seekJob?.cancel()
        filmstripJob?.cancel()
        prefetchJob?.cancel()
        cancelStepWorker() // new camera invalidates the anchor + any in-flight step
        val prev = _state.value
        if (preserveTime && prev.playheadMs > 0L) {
            // Same time, different camera — keep window + playhead, reload this
            // camera's overlays for that window, then seek it to the same instant.
            _state.update {
                PlaybackUiState(
                    cameraId = camId,
                    cameraName = null,
                    windowStartMs = prev.windowStartMs,
                    windowEndMs = prev.windowEndMs,
                    playheadMs = prev.playheadMs,
                    visibleSpanMs = prev.visibleSpanMs,
                    speed = prev.speed,
                    detectionEvents = emptyList(),
                )
            }
            loadCameraName()
            loadTimeline(prev.windowStartMs, prev.windowEndMs, gotoLatest = false)
            // Resolve the new camera's segment at the preserved time. If it has no
            // footage there, seekTo clears the segment gracefully (no crash).
            seekTo(prev.playheadMs)
        } else {
            val now = Instant.now()
            // A pending seed (entered from the wall at a scrubbed moment) centers the
            // window on that moment and seeks there; otherwise open a window ending at
            // "now" and snap to the latest footage once spans arrive.
            val seed = pendingSeedMs.takeIf { it > 0L }
            pendingSeedMs = 0L
            val halfMs = DEFAULT_WINDOW_HOURS * 3600_000L / 2
            val windowStartMs: Long
            val windowEndMs: Long
            val playheadMs: Long
            if (seed != null) {
                windowStartMs = (seed - halfMs).coerceAtLeast(0L)
                windowEndMs = minOf(seed + halfMs, now.toEpochMilli())
                playheadMs = seed
            } else {
                windowStartMs = now.minusSeconds(DEFAULT_WINDOW_HOURS * 3600).toEpochMilli()
                windowEndMs = now.toEpochMilli()
                playheadMs = now.toEpochMilli()
            }
            _state.update {
                PlaybackUiState(
                    cameraId = camId,
                    cameraName = null, // resolved by loadCameraName() below
                    windowStartMs = windowStartMs,
                    windowEndMs = windowEndMs,
                    // Without a seed, start at "now" (live edge); loadTimeline snaps to
                    // the latest recorded footage once spans arrive (gotoLatest below).
                    playheadMs = playheadMs,
                    visibleSpanMs = prev.visibleSpanMs, // preserve the user's zoom level
                    speed = prev.speed,                 // preserve the chosen speed
                    detectionEvents = emptyList(),      // clear stale events from previous camera
                )
            }
            loadCameraName()
            loadTimeline(windowStartMs, windowEndMs, gotoLatest = seed == null)
            // With a seed, resolve the segment at that exact instant immediately.
            if (seed != null) seekTo(seed)
        }
    }

    /**
     * Switch the camera being reviewed (camera picker / swipe nav). No-op if it's
     * already the current camera. Keeps the SAME time across the switch when you're
     * actively reviewing footage (multi-angle review of the same moment); on first
     * entry / before footage has resolved it jumps to the new camera's latest.
     */
    fun switchCamera(camId: String) {
        if (camId == cameraId) return
        val reviewing = _state.value.currentSegment != null
        startCamera(camId, preserveTime = reviewing)
    }

    // ─── Internal loaders ───────────────────────────────────────────────────────

    private fun loadCameraName() {
        viewModelScope.launch {
            repo.visibleCameras()
                .onSuccess { cameras ->
                    val name = cameras.firstOrNull { it.id == cameraId }?.name
                    _state.update { it.copy(cameraName = name ?: cameraId) }
                }
                .onFailure {
                    // Network issue — fall back silently, use id as name
                    _state.update { it.copy(cameraName = cameraId) }
                }
        }
    }

    private fun loadTimeline(startMs: Long, endMs: Long, gotoLatest: Boolean = false) {
        // Cancel any in-flight load so a rapid jumpToTime/switchCamera can't let a
        // stale window's spans/intensity/events response clobber the current
        // overlay (review G3). The three fetches are children of one parent job,
        // so cancelling it cancels all of them.
        timelineJob?.cancel()
        timelineJob = viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            // Recorded spans (drives loading + optional goto-latest).
            launch {
                repo.timeline(
                    cameraIds = listOf(cameraId),
                    startIso = Time.iso(Instant.ofEpochMilli(startMs)),
                    endIso = Time.iso(Instant.ofEpochMilli(endMs)),
                ).onSuccess { spans ->
                    _state.update { it.copy(loading = false, spans = spans) }
                    if (gotoLatest && spans.isNotEmpty()) {
                        // Jump to the most recent recorded footage. Land ~1.5 s INSIDE
                        // the last segment, not its end boundary — segment resolve uses
                        // `end_ts > ts`, so the exact end returns 404 ("Not found").
                        val latest = spans.maxOf { Time.parseToMillis(it.end) }
                        seekTo((latest - 1500L).coerceIn(0L, endMs))
                    }
                }.onFailure { err ->
                    _state.update { it.copy(loading = false, error = err.toUserMessage()) }
                }
            }
            // Motion-magnitude histogram (non-fatal: timeline still renders without it).
            launch {
                repo.timelineIntensity(
                    cameraId = cameraId,
                    startIso = Time.iso(Instant.ofEpochMilli(startMs)),
                    endIso = Time.iso(Instant.ofEpochMilli(endMs)),
                    buckets = MOTION_BUCKETS,
                ).onSuccess { buckets ->
                    _state.update {
                        it.copy(motionBuckets = buckets, motionStartMs = startMs, motionEndMs = endMs)
                    }
                }
            }
            // Detection events (non-fatal: absent plugin / network → emptyList).
            launch {
                val events = try {
                    repo.detectionEvents(
                        cameraId = cameraId,
                        startIso = Time.iso(Instant.ofEpochMilli(startMs)),
                        endIso = Time.iso(Instant.ofEpochMilli(endMs)),
                        limit = 2000,
                    ).getOrElse { emptyList() }
                } catch (_: Exception) {
                    emptyList()
                }
                _state.update { it.copy(detectionEvents = events) }
            }
        }
    }

    // ─── Segment resolution ─────────────────────────────────────────────────────

    /**
     * Seek to an absolute epoch-millis position. Resolves the covering segment,
     * computes the in-segment offset, and updates state so the screen can feed
     * ExoPlayer immediately.
     */
    /**
     * ExoPlayer reported an error mid-stream, or the position watchdog detected a
     * silent freeze (mid-segment 404, dropped connection, expired token, decoder
     * wedge). Re-resolve at the current playhead: a fresh segment URL recovers
     * transient/token cases, and a hard failure falls through to [seekTo]'s
     * failure path which surfaces the existing error snackbar + Retry (review A1).
     */
    fun onPlayerError() {
        seekTo(_state.value.playheadMs)
    }

    /**
     * @param retryAtMs When a motion-jump pre-rolled the seek target ahead of an
     *   event's true start (see [performJump]) and the pre-rolled instant 404s —
     *   e.g. a motion-gated camera with a pre-buffer shorter than [PRE_ROLL_MS] —
     *   retry ONCE at this exact time before falling back to the calm
     *   "no footage" state. Null for every other caller (plain seeks never retry).
     */
    fun seekTo(tsMs: Long, retryAtMs: Long? = null) {
        _state.update { it.copy(playheadMs = tsMs) }
        // Cancel any in-flight resolve so a stale result can't override this seek
        // (e.g. an onSegmentEnded auto-advance racing a user scrub). NOTE: a
        // motion-jump's own seekTo is the ONLY writer active while
        // jumpInProgress is true (every other writer is suppressed above), so
        // this cancellation can no longer clobber the user's press the way
        // onSegmentEnded used to (RC2) — onSegmentEnded now returns early
        // instead of calling seekTo while a jump is in flight.
        seekJob?.cancel()
        // Any previously prefetched "next" segment was computed relative to the
        // segment we're now jumping AWAY from — it no longer describes what comes
        // after tsMs, so drop it. [prefetchNextSegment] will resolve a fresh one
        // once we're playing again near the (new) segment's tail.
        _state.update { it.copy(nextSegment = null, nextSegmentUrl = null) }
        seekJob = viewModelScope.launch {
            val tsIso = Time.iso(Instant.ofEpochMilli(tsMs))
            repo.resolveSegment(cameraId, tsIso).onSuccess { segment ->
                val startMs = Time.parseToMillis(segment.start)
                val offsetMs = (tsMs - startMs).coerceAtLeast(0L)
                val authedUrl = repo.mediaUrls().scopedUrl(cameraId, segment.url)
                _state.update {
                    it.copy(
                        // Belt-and-braces re-assertion (spec 5.): whatever else
                        // touched playheadMs during the round-trip, the landed
                        // segment's own resolve target wins.
                        playheadMs = tsMs,
                        currentSegment = segment,
                        currentSegmentUrl = authedUrl,
                        segmentOffsetMs = offsetMs,
                        error = null,
                        noFootageAtPlayhead = false,
                    )
                }
            }.onFailure { err ->
                if (err.isNotFound() && retryAtMs != null && retryAtMs != tsMs) {
                    // Pre-rolled landing fell in a gap (short pre-buffer) — retry
                    // once at the event's exact start before giving up.
                    seekTo(retryAtMs, retryAtMs = null)
                    return@launch
                }
                _state.update {
                    if (err.isNotFound()) {
                        // No footage at this instant — a NORMAL recording gap (motion
                        // camera, quiet period). Show a calm "no footage" state; do NOT
                        // raise the error snackbar/Retry alert.
                        it.copy(
                            currentSegment = null,
                            currentSegmentUrl = null,
                            segmentOffsetMs = 0L,
                            error = null,
                            noFootageAtPlayhead = true,
                        )
                    } else {
                        // A genuine failure (network / 5xx / auth) — surface it.
                        it.copy(
                            currentSegment = null,
                            currentSegmentUrl = null,
                            segmentOffsetMs = 0L,
                            error = err.toUserMessage(),
                            noFootageAtPlayhead = false,
                        )
                    }
                }
            }
        }
    }

    /**
     * Pre-resolve the segment that will follow [currentSegment] and stash it in
     * [PlaybackUiState.nextSegment]/[PlaybackUiState.nextSegmentUrl], WITHOUT
     * touching [PlaybackUiState.currentSegment] or the playhead.
     *
     * Called by the screen while playing, once the playhead is within
     * [PREFETCH_LEAD_MS] of the current segment's end — so the network resolve
     * happens ahead of time and the screen can queue the result on the ExoPlayer
     * playlist for a gapless transition, instead of waiting for `STATE_ENDED` and
     * visibly freezing on the resolve round-trip.
     *
     * Mirrors the "still in span" branch of [onSegmentEnded]: only prefetches
     * when the next instant is still covered by a recorded span (a seamless
     * continuation). Across a recording GAP there is nothing to gaplessly queue —
     * that case still goes through the normal [onSegmentEnded] → [seekTo] path.
     * No-ops if a prefetch for this segment is already in flight or done.
     */
    fun prefetchNextSegment() {
        val s = _state.value
        val seg = s.currentSegment ?: return
        if (s.nextSegment != null || prefetchJob?.isActive == true) return
        val endMs = Time.parseToMillis(seg.end)
        val stillInSpan = s.spans.any { span ->
            Time.parseToMillis(span.start) <= endMs && endMs < Time.parseToMillis(span.end)
        }
        if (!stillInSpan) return

        val targetSegmentId = seg.segmentId
        prefetchJob = viewModelScope.launch {
            val tsIso = Time.iso(Instant.ofEpochMilli(endMs + NEXT_SEGMENT_LOOKAHEAD_MS))
            repo.resolveSegment(cameraId, tsIso).onSuccess { next ->
                // Guard against a race: if the user scrubbed/switched away from the
                // segment this prefetch was FOR while the network call was in
                // flight, don't attach a stale "next" to the new current segment.
                if (_state.value.currentSegment?.segmentId != targetSegmentId) return@onSuccess
                val authedUrl = repo.mediaUrls().scopedUrl(cameraId, next.url)
                _state.update { it.copy(nextSegment = next, nextSegmentUrl = authedUrl) }
            }
            // Failures (including 404 at a span boundary edge case) are silently
            // dropped — the STATE_ENDED fallback in onSegmentEnded() still covers
            // it, just without the gapless transition for this one boundary.
        }
    }

    /**
     * Called by the screen once ExoPlayer's playlist has ACTUALLY advanced into
     * the segment previously prefetched via [prefetchNextSegment] (i.e. on
     * `Player.Listener.onMediaItemTransition`, not `STATE_ENDED` — the whole
     * point of the prefetch is to never hit `STATE_ENDED` on this boundary).
     *
     * Promotes [PlaybackUiState.nextSegment] to [PlaybackUiState.currentSegment]
     * and rebases the playhead to the new segment's start — purely a local state
     * update, no network resolve, so there is no hitch.
     */
    fun onAdvancedToNextSegment() {
        val s = _state.value
        if (s.jumpInProgress) return // a motion-jump owns the playhead right now (RC2)
        val next = s.nextSegment ?: return
        val nextUrl = s.nextSegmentUrl ?: return
        val startMs = Time.parseToMillis(next.start)
        _state.update {
            it.copy(
                currentSegment = next,
                currentSegmentUrl = nextUrl,
                segmentOffsetMs = 0L,
                playheadMs = startMs,
                nextSegment = null,
                nextSegmentUrl = null,
                error = null,
                noFootageAtPlayhead = false,
            )
        }
    }

    /**
     * Called by the screen when ExoPlayer fires [Player.STATE_ENDED].
     * Advances by 1 ms past the end of the finished segment to fetch the next one.
     */
    fun onSegmentEnded() {
        val state = _state.value
        // A motion-jump owns the playhead right now — its own seekTo (fired at
        // the END of the step worker) is the only thing allowed to move it.
        // Previously this branch called seekTo() unconditionally, which CANCELS
        // the in-flight jump's seekJob (see seekTo) and silently loses the
        // user's press (RC2). The player is paused for the duration of a jump,
        // so STATE_ENDED firing here mid-jump would itself be stale.
        if (state.jumpInProgress) return
        val seg = state.currentSegment ?: return
        val endMs = Time.parseToMillis(seg.end)
        val spans = state.spans

        // If the playhead is still inside a recorded span, more footage follows
        // immediately — advance seamlessly into the next segment.
        val stillInSpan = spans.any { span ->
            Time.parseToMillis(span.start) <= endMs && endMs < Time.parseToMillis(span.end)
        }
        if (stillInSpan) {
            seekTo(endMs + NEXT_SEGMENT_LOOKAHEAD_MS)
            return
        }

        // At the end of a span — jump across the gap to the next recorded span,
        // or stop cleanly if there is no more footage in the window.
        val nextStart = spans
            .map { Time.parseToMillis(it.start) }
            .filter { it > endMs }
            .minOrNull()
        if (nextStart != null) {
            seekTo(nextStart)
        } else {
            _state.update { it.copy(playing = false) }
        }
    }

    /**
     * Lightweight playhead update driven by the screen's ~4x/sec position poll
     * while video plays. Unlike [seekTo] this does NOT re-resolve a segment or
     * touch the player — it only advances the displayed time so the clock (and the
     * centered timeline) move smoothly instead of jumping at segment boundaries.
     * Ignored while scrubbing (the scrub gesture owns the playhead then) OR while
     * a motion-jump is in flight (this was the ROOT CAUSE of the "buttons jump
     * around" bug: the player was never paused during a jump's resolve
     * round-trip, so this tick would overwrite `playheadMs` back to the OLD
     * position 0–250 ms after a press). The inner re-check guards a scrub/jump
     * that begins between the caller's check and this update.
     */
    fun onPlaybackTick(tsMs: Long) {
        val s = _state.value
        if (s.scrubbing || s.jumpInProgress) return
        _state.update { if (it.scrubbing || it.jumpInProgress) it else it.copy(playheadMs = tsMs) }
    }

    // ─── Motion navigation ──────────────────────────────────────────────────────
    //
    // See `docs/ANDROID-MOTION-EVENT-NAV-FIX.md` for the full root-cause + spec.
    // Summary: presses are serialized through ONE step worker; the worker does
    // cheap server edge queries per queued press but only ONE final
    // pause→resolve→seek→play. `jumpInProgress` (guarded above in
    // onPlaybackTick/onSegmentEnded/onAdvancedToNextSegment) keeps every other
    // playhead writer off the cursor for the duration.

    /**
     * Request a motion-event step. Presses are cheap to enqueue — the worker
     * coalesces a burst into one seek but still performs N edge queries, so N
     * presses always mean N steps (never a debounce that drops presses).
     */
    fun stepMotion(forward: Boolean) {
        pendingSteps.trySend(if (forward) 1 else -1)
        if (stepJob?.isActive != true) stepJob = viewModelScope.launch { runStepWorker() }
    }

    /**
     * The single serialization point for motion-event stepping. Sets
     * [PlaybackUiState.jumpInProgress] immediately (the screen pauses the
     * player and every other playhead writer goes inert), then drains
     * [pendingSteps] one direction at a time — each iteration is just an
     * indexed server query advancing the logical anchor, no player/state
     * touch — and only once the queue is momentarily empty does it perform
     * the ONE real seek at the final anchor.
     */
    private suspend fun runStepWorker() {
        _state.update { it.copy(jumpInProgress = true) } // screen pauses player NOW
        try {
            var anchor = stepAnchorMs ?: liveEdgeAwareAnchor()
            var landed: Long? = null
            while (true) {
                val dir = pendingSteps.tryReceive().getOrNull() ?: break
                val forward = dir > 0
                val from = anchor + if (forward) STEP_EPSILON_MS else -STEP_EPSILON_MS
                val next = repo.motionEdge(cameraId, from, next = forward).getOrElse {
                    // Server unreachable / older server without the endpoint —
                    // offline fallback over the loaded histogram.
                    fallbackLocalStep(anchor, forward)
                }
                if (next == null) {
                    _toast.tryEmit(
                        if (forward) "No later motion on this camera"
                        else "No earlier motion on this camera",
                    )
                    break // clamp: do not move; anchor stays put for the next press
                }
                anchor = next
                landed = next
            }
            if (landed != null) {
                stepAnchorMs = landed
                performJump(landed)
            }
        } finally {
            _state.update { it.copy(jumpInProgress = false) }
            // The screen's play/pause-sync effect restores playWhenReady = state.playing.
        }
    }

    /**
     * The anchor to start a fresh step from when there's no [stepAnchorMs] yet
     * (first press since a scrub/switch/jump). Ordinarily just the current
     * playhead — with ticks suppressed during a jump, `playheadMs` is always
     * the true last-played instant. AT the live edge (within
     * [LIVE_EDGE_THRESHOLD_MS] of the wall clock, or already past the loaded
     * window's end) the playhead can be sitting on a stale "now" marker rather
     * than a concrete recorded instant — clamp it to `min(playheadMs, now)` and
     * let the SERVER answer from there; it sees segments written after this
     * client's window load, which is what actually cures RC4 (not any special
     * casing here beyond picking a sane search origin).
     */
    private fun liveEdgeAwareAnchor(): Long {
        val s = _state.value
        val now = Instant.now().toEpochMilli()
        val atLiveEdge = (now - s.playheadMs) <= LIVE_EDGE_THRESHOLD_MS || s.playheadMs > s.windowEndMs
        return if (atLiveEdge) minOf(s.playheadMs, now) else s.playheadMs
    }

    /**
     * Land on [eventStartMs] with [PRE_ROLL_MS] of lead-in so the user sees the
     * motion begin, clamped to the start of the recorded span containing the
     * event so pre-roll never lands in a gap. If the target lies outside the
     * currently loaded window (including past the loaded motion histogram's
     * range — the RC4 live-edge case), recenter + reload the window at the
     * target instead of a bare seek, so stale spans/histogram/events refresh
     * as part of landing.
     */
    private fun performJump(eventStartMs: Long) {
        val s = _state.value
        val spanStart = s.spans
            .firstOrNull { span ->
                Time.parseToMillis(span.start) <= eventStartMs && eventStartMs < Time.parseToMillis(span.end)
            }
            ?.let { Time.parseToMillis(it.start) }
        val preRolled = eventStartMs - PRE_ROLL_MS
        val target = if (spanStart != null) maxOf(preRolled, spanStart) else preRolled

        val outsideWindow = target < s.windowStartMs || target > s.windowEndMs ||
            (s.motionEndMs > s.motionStartMs && target > s.motionEndMs)
        if (outsideWindow) {
            // Desktop's pbJumpTo pattern: recenter the data window on the target
            // and reload spans/histogram/events for it, THEN land there. This is
            // what cures live-edge staleness — a fresh window reload sees
            // segments written after the client's last load. Uses the INTERNAL
            // recenter (does not clear stepAnchorMs, unlike the public
            // jumpToTime used by scrub/date-jump/etc.) — the anchor for this
            // step was just set by the caller and must survive the recenter.
            recenterWindow(target)
            return
        }
        // Retry once at the exact event start if the pre-rolled instant 404s
        // (motion-gated camera with a pre-buffer shorter than PRE_ROLL_MS).
        seekTo(target, retryAtMs = if (target != eventStartMs) eventStartMs else null)
    }

    /**
     * Offline / older-server fallback: derive merged motion-event starts from
     * the already-loaded [PlaybackUiState.motionBuckets] histogram, desktop-
     * style — `on(i) = buckets[i] >= MOTION_EVENT_FLOOR`, bridging sub-threshold
     * gaps up to [MOTION_MERGE_GAP_MS] into the SAME event, event time = the
     * bucket's leading edge (never the center — the old bug landed up to ±7.5s
     * off the true start). Limited to the loaded window; the server path above
     * is not.
     */
    private fun fallbackLocalStep(anchorMs: Long, forward: Boolean): Long? {
        val s = _state.value
        val buckets = s.motionBuckets
        if (buckets.isEmpty() || s.motionEndMs <= s.motionStartMs) {
            _toast.tryEmit("No motion data for this camera")
            return null
        }
        val bucketMs = (s.motionEndMs - s.motionStartMs).toDouble() / buckets.size
        val mergeGapBuckets = maxOf(1, Math.round(MOTION_MERGE_GAP_MS / bucketMs).toInt())

        // An event starts at bucket i if buckets[i] is on-motion and no bucket
        // in the preceding `mergeGapBuckets` window is also on-motion (i.e. the
        // gap since the last on-bucket exceeds the merge window — bridges brief
        // sub-threshold dips into ONE event instead of splitting them).
        fun isOn(i: Int) = i in buckets.indices && buckets[i] >= MOTION_EVENT_FLOOR
        fun eventStartTimeMs(i: Int) = s.motionStartMs + (i * bucketMs).toLong()
        fun isEventStart(i: Int): Boolean {
            if (!isOn(i)) return false
            for (back in 1..mergeGapBuckets) if (isOn(i - back)) return false
            return true
        }

        return if (forward) {
            for (i in buckets.indices) {
                if (!isEventStart(i)) continue
                val t = eventStartTimeMs(i)
                if (t > anchorMs) return t
            }
            null
        } else {
            for (i in buckets.indices.reversed()) {
                if (!isEventStart(i)) continue
                val t = eventStartTimeMs(i)
                if (t < anchorMs) return t
            }
            null
        }
    }

    /** Cancels any in-flight step worker, drains queued presses, and clears the
     *  logical anchor. Called whenever something ELSE takes ownership of the
     *  playhead (scrub, jumpToTime, gotoFirst/Last, camera switch) so a stale
     *  worker can't land a step after the user has moved on. */
    private fun cancelStepWorker() {
        stepJob?.cancel()
        stepJob = null
        while (pendingSteps.tryReceive().isSuccess) { /* drain */ }
        stepAnchorMs = null
    }

    /** Jump to the earliest recorded footage in the loaded window. */
    fun gotoFirst() {
        cancelStepWorker()
        val first = _state.value.spans.minByOrNull { Time.parseToMillis(it.start) } ?: return
        jumpToTime(Time.parseToMillis(first.start))
    }

    /** Jump to the latest recorded footage in the loaded window (just before its end). */
    fun gotoLast() {
        cancelStepWorker()
        val last = _state.value.spans.maxByOrNull { Time.parseToMillis(it.end) } ?: return
        jumpToTime((Time.parseToMillis(last.end) - 1000L).coerceAtLeast(0L))
    }

    // ─── Playback controls ──────────────────────────────────────────────────────

    /** Toggle or explicitly set play/pause. */
    fun setPlaying(playing: Boolean) {
        _state.update { it.copy(playing = playing) }
    }

    /**
     * Cycle to the next speed step, or jump to an explicit value.
     * Valid values: 0.5, 1.0, 2.0, 4.0, 8.0.
     */
    fun setSpeed(speed: Float) {
        val clamped = SPEED_STEPS.minByOrNull { kotlin.math.abs(it - speed) } ?: 1f
        _state.update { it.copy(speed = clamped) }
    }

    /** Cycle through speed steps in order. */
    fun cycleSpeed() {
        val current = _state.value.speed
        val idx = SPEED_STEPS.indexOfFirst { it == current }.takeIf { it >= 0 } ?: 1
        val next = SPEED_STEPS[(idx + 1) % SPEED_STEPS.size]
        _state.update { it.copy(speed = next) }
    }

    // ─── Window / time navigation ────────────────────────────────────────────────

    /**
     * Recenter the time window around [epochMs] and reload the timeline.
     * The window is kept at [DEFAULT_WINDOW_HOURS] total width, clamped to now.
     * Invalidates the motion-step anchor and any in-flight step worker: this is
     * an externally-triggered navigation (date-jump, scrub-edge recenter),
     * taking ownership of the playhead away from the stepping feature.
     */
    fun jumpToTime(epochMs: Long) {
        cancelStepWorker()
        recenterWindow(epochMs)
    }

    /**
     * Core of [jumpToTime] WITHOUT the step-anchor invalidation — used
     * internally by [performJump] when a motion step lands outside the loaded
     * window, where the just-computed anchor must survive the recenter.
     */
    private fun recenterWindow(epochMs: Long) {
        val now = Instant.now().toEpochMilli()
        val halfWindowMs = DEFAULT_WINDOW_HOURS * 3600 * 1000 / 2
        val windowStart = (epochMs - halfWindowMs).coerceAtLeast(0L)
        val windowEnd = (epochMs + halfWindowMs).coerceAtMost(now)
        _state.update {
            it.copy(
                windowStartMs = windowStart,
                windowEndMs = windowEnd,
                playheadMs = epochMs,
            )
        }
        loadTimeline(windowStart, windowEnd)
        seekTo(epochMs)
    }

    // ─── Scrubbing ───────────────────────────────────────────────────────────────

    /** Called when the user starts dragging the scrubber. */
    fun onScrubStart() {
        // Preserve `playing` so playback resumes after release if it was running;
        // the screen pauses the player for the duration of the scrub.
        _state.update { it.copy(scrubbing = true) }
    }

    /**
     * Called continuously while the user drags. Updates the playhead immediately
     * and kicks off a debounced filmstrip fetch so thumbnails track the finger.
     */
    fun onScrub(tsMs: Long) {
        val nearestFrame = _state.value.filmstrip
            .minByOrNull { kotlin.math.abs(Time.parseToMillis(it.ts) - tsMs) }
        _state.update { it.copy(playheadMs = tsMs) }
        if (nearestFrame != null) {
            // URL construction needs the (possibly cached, possibly a fresh fetch)
            // per-camera scoped token — resolve it off the main update, then apply
            // it only if the scrub hasn't already moved past this frame.
            viewModelScope.launch {
                val frameUrl = repo.mediaUrls().scopedUrl(cameraId, nearestFrame.url)
                if (_state.value.scrubbing) _state.update { it.copy(scrubFrameUrl = frameUrl) }
            }
        } else {
            _state.update { it.copy(scrubFrameUrl = null) }
        }
        loadFilmstrip(tsMs)
    }

    /** Called when the user releases the scrubber. Seeks to the final position,
     *  and recenters the (larger) data window if the playhead neared its edge so
     *  the centered timeline always has spans to show on both sides. Scrubbing
     *  takes ownership of the playhead away from motion-stepping, exactly like
     *  every other external navigation — invalidate the step anchor + cancel
     *  any in-flight step worker. */
    fun onScrubEnd(tsMs: Long) {
        cancelStepWorker()
        _state.update { it.copy(scrubbing = false, playheadMs = tsMs, scrubFrameUrl = null) }
        val s = _state.value
        val margin = 30L * 60_000L
        if (tsMs < s.windowStartMs + margin || tsMs > s.windowEndMs - margin) {
            val now = Instant.now().toEpochMilli()
            val half = DEFAULT_WINDOW_HOURS * 3600_000L / 2
            val ws = (tsMs - half).coerceAtLeast(0L)
            val we = (tsMs + half).coerceAtMost(now)
            _state.update { it.copy(windowStartMs = ws, windowEndMs = we) }
            loadTimeline(ws, we)
        }
        seekTo(tsMs)
    }

    /** Set the centered-timeline visible span (pinch-to-zoom), clamped. */
    fun setVisibleSpan(spanMs: Long) {
        _state.update { it.copy(visibleSpanMs = spanMs.coerceIn(MIN_SPAN_MS, MAX_SPAN_MS)) }
    }

    /**
     * Debounced filmstrip fetch. Cancels any in-flight request, waits for
     * [FILMSTRIP_DEBOUNCE_MS], then fetches a window around [centerMs].
     */
    fun loadFilmstrip(centerMs: Long) {
        filmstripJob?.cancel()
        filmstripJob = viewModelScope.launch {
            delay(FILMSTRIP_DEBOUNCE_MS)
            val halfMs = FILMSTRIP_HALF_WINDOW_HOURS * 3600 * 1000
            val startIso = Time.iso(Instant.ofEpochMilli((centerMs - halfMs).coerceAtLeast(0L)))
            val endIso = Time.iso(Instant.ofEpochMilli(centerMs + halfMs))
            repo.filmstrip(cameraId, startIso, endIso, width = 160)
                .onSuccess { frames ->
                    val nearestFrame = frames.minByOrNull {
                        kotlin.math.abs(Time.parseToMillis(it.ts) - _state.value.playheadMs)
                    }
                    val frameUrl = nearestFrame?.let { repo.mediaUrls().scopedUrl(cameraId, it.url) }
                    _state.update { s ->
                        s.copy(filmstrip = frames, scrubFrameUrl = if (s.scrubbing) frameUrl else s.scrubFrameUrl)
                    }
                }
            // Silently ignore filmstrip failures — the scrubber still works without thumbnails
        }
    }

    // ─── Error recovery ──────────────────────────────────────────────────────────

    /** Clear a transient error so the UI can retry. */
    fun clearError() {
        _state.update { it.copy(error = null) }
    }

    override fun onCleared() {
        super.onCleared()
        filmstripJob?.cancel()
        seekJob?.cancel()
        prefetchJob?.cancel()
        stepJob?.cancel()
    }
}
