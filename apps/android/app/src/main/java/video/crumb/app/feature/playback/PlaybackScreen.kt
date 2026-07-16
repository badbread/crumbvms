// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowDropUp
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.FirstPage
import androidx.compose.material.icons.filled.LastPage
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.NavigateBefore
import androidx.compose.material.icons.filled.NavigateNext
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.media3.common.PlaybackException
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.datasource.HttpDataSource
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.SeekParameters
import android.view.TextureView
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import android.content.res.Configuration
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.runtime.rememberCoroutineScope
import androidx.media3.ui.PlayerView
import coil.compose.AsyncImage
import kotlinx.coroutines.launch
import video.crumb.app.data.toUserMessage
import video.crumb.app.di.appContainer
import video.crumb.app.ui.CameraNav
import video.crumb.app.ui.AddBookmarkDialog
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.JumpToDateTimeDialog
import video.crumb.app.ui.Time
import video.crumb.app.ui.player.MediaFactory
import video.crumb.app.ui.player.PlayerSurface
import video.crumb.app.ui.player.ViewTransform
import video.crumb.app.ui.player.ZoomableVideoSurface
import video.crumb.app.feature.live.rememberIsMetered
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextSecondary
import java.time.Instant

/**
 * How close to the end of the current segment (remaining playtime, ms) this
 * screen asks [PlaybackViewModel.prefetchNextSegment] to resolve the next one.
 * Segments are short (~4s), so this needs enough lead time for a resolve
 * round-trip on a slow link, without firing so early it refetches needlessly
 * on every short segment.
 *
 * Raised from 2 s to hide one more resolve+fetch round-trip on a slow link (on a
 * LAN, resolves are instant so this changes nothing). Keep in sync with
 * [PlaybackViewModel]'s own `PREFETCH_LEAD_MS`.
 */
private const val PREFETCH_LEAD_MS_SCREEN = 3_500L

/**
 * Playback quality selector values, persisted as a string in `SecureStore`.
 *
 * - [AUTO] (default): full on Wi-Fi/unmetered, [DATA_SAVER] on metered/cellular.
 * - [FULL]: always the recorded main-stream bytes (`/segments/{id}`).
 * - [DATA_SAVER]: always the server's on-demand 640p transcode
 *   (`/segments/{id}/low.mp4`).
 */
object PlaybackQuality {
    const val AUTO = "auto"
    const val FULL = "full"
    const val DATA_SAVER = "low"

    /** Cycle order for the one-tap selector: Auto → Full → Data saver → Auto. */
    fun next(current: String): String = when (current) {
        AUTO -> FULL
        FULL -> DATA_SAVER
        else -> AUTO
    }

    /** Short label for the selector's tooltip / hint. */
    fun label(current: String): String = when (current) {
        FULL -> "Quality: Full"
        DATA_SAVER -> "Quality: Data saver"
        else -> "Quality: Auto"
    }

    /** Compact badge text for the in-bar chip. */
    fun short(current: String): String = when (current) {
        FULL -> "HD"
        DATA_SAVER -> "SD"
        else -> "AUTO"
    }
}

/**
 * Full-screen single-camera recorded-playback screen.
 *
 * Wires together:
 * - [PlaybackViewModel] for all data/state.
 * - [PlayerSurface] + Media3 ExoPlayer for video decode.
 * - [CenteredTimeline] for the headline scrub feel.
 * - Coil [AsyncImage] for filmstrip thumbnails during scrubbing.
 *
 * ExoPlayer lifecycle:
 * - Built once in [remember] and released in [DisposableEffect].
 * - Paused automatically when the screen is not in the foreground via a
 *   [LifecycleEventObserver].
 * - Re-seeks whenever [PlaybackUiState.currentSegmentUrl] changes.
 *
 * Playback is a STANDALONE top-level mode (like Live), not a per-camera submenu:
 * [initialCameraId] only seeds which camera is shown first; the user can switch to
 * any other camera here via the camera picker in the title bar or a horizontal
 * swipe at 1x (same gesture as Live). [PlaybackViewModel.switchCamera] re-targets
 * the same ViewModel + player at the chosen camera.
 *
 * @param initialCameraId The camera shown first (may be blank → first enabled cam).
 * @param initialTimeMs Optional start time (epoch-millis) for the first camera —
 *   set when entered from the playback wall scrubbed to a past moment. ≤ 0 → open
 *   at the camera's latest footage (the standard behaviour).
 * @param onBack Called when the user taps the back arrow.
 */
@OptIn(ExperimentalMaterial3Api::class, UnstableApi::class)
@Composable
fun PlaybackScreen(
    initialCameraId: String,
    initialTimeMs: Long = 0L,
    onBack: () -> Unit,
) {
    val container = appContainer()
    val repo = container.repository
    val context = LocalContext.current

    // ViewModel is keyed stably (NOT per-camera) so switching cameras within
    // Playback re-uses the same VM + player instead of spinning up a new one.
    val vm: PlaybackViewModel = viewModel(
        key = "playback",
        factory = viewModelFactory {
            initializer { PlaybackViewModel(initialCameraId, repo, initialTimeMs) }
        },
    )

    val state by vm.state.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    // The camera currently shown (owned by the VM; updated on switch/swipe).
    val cameraId = state.cameraId

    // Ordered enabled-camera ids (live-wall order) for the picker + swipe nav.
    var cameraIds by remember { mutableStateOf<List<String>>(emptyList()) }
    var cameraNames by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    LaunchedEffect(Unit) {
        // Viewer-safe endpoint: repo.cameras() hits the admin-only /config/cameras
        // and 403s for non-admin accounts, silently leaving the camera picker (and
        // swipe-nav, and the auto-target-first-camera path below) empty for viewers.
        // visibleCameras() is the same viewer-scoped endpoint every other screen uses.
        repo.visibleCameras()
            .onSuccess { list ->
                val enabled = list.filter { it.enabled }
                cameraIds = enabled.map { it.id }
                cameraNames = enabled.associate { it.id to it.name }
                // If we entered without a specific camera, target the first enabled one.
                if (initialCameraId.isBlank() && enabled.isNotEmpty()) {
                    vm.switchCamera(enabled.first().id)
                }
            }
            .onFailure { t ->
                snackbarHostState.showSnackbar(t.toUserMessage())
            }
    }

    // Switch helper shared by the picker and the swipe gesture. dir = +1 next / -1 prev.
    val switchCameraByOffset: (Int) -> Unit = { dir ->
        if (cameraIds.size > 1) {
            CameraNav.next(cameraIds, cameraId, dir)?.let { vm.switchCamera(it) }
        }
    }

    // Snapshot needs the PlayerView so we can grab the current TextureView frame.
    var playerView by remember { mutableStateOf<PlayerView?>(null) }
    // Latest digital-zoom transform from the video surface — used to crop snapshots
    // to the on-screen viewport when the user opts into "Current view" snapshots.
    var viewTransform by remember { mutableStateOf(ViewTransform(1f, 0f, 0f)) }
    // Server-shared bookmarks for this camera (gold markers on the timeline). Held
    // as epoch-ms for the timeline; reloaded after each add.
    var bookmarks by remember(cameraId) { mutableStateOf<List<Long>>(emptyList()) }
    fun reloadBookmarks() {
        scope.launch {
            container.repository.bookmarks(cameraId).onSuccess { list ->
                bookmarks = list
                    .mapNotNull { runCatching { Instant.parse(it.ts).toEpochMilli() }.getOrNull() }
                    .sorted()
            }
        }
    }
    LaunchedEffect(cameraId) { reloadBookmarks() }
    // Platform-wide bookmarks toggle (server /status.bookmarks_enabled). When the
    // admin disables bookmarks, hide the Add-bookmark control everywhere. Defaults
    // shown (true) until the status fetch returns / on older servers.
    var bookmarksEnabled by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        container.repository.status().onSuccess { bookmarksEnabled = it.bookmarksEnabled }
    }
    // "Add bookmark" dialog state: capture the moment on open so it's stable while
    // the operator types an optional note; the playhead can keep moving meanwhile.
    var showBookmarkDialog by remember { mutableStateOf(false) }
    var bookmarkAtMs by remember { mutableLongStateOf(0L) }

    // ── ExoPlayer setup ─────────────────────────────────────────────────────────
    // newPlaybackPlayer declares media audio attributes (#106) and a WAN-tuned
    // buffer, unlike the muted live-wall tiles. Audio focus is applied below only
    // while sound is ON.
    val player = remember {
        MediaFactory.newPlaybackPlayer(context).apply {
            setSeekParameters(SeekParameters.EXACT) // frame-accurate stepping
        }
    }

    // Recorded-playback audio on/off (mirrors the fullscreen live view's toggle).
    // Seeded from SecureStore (default OFF — reviewing footage is silent until the
    // operator asks for sound) and persisted on every change. A segment recorded
    // without an audio track just plays silent when this is on — no crash.
    val store = container.store
    var audioOn by remember { mutableStateOf(store.playbackAudioOn) }
    // Drive volume from the toggle, and request audio focus ONLY while sound is on
    // (so a silent scrub-through doesn't pause the user's music — Fable MED#3).
    LaunchedEffect(player, audioOn) {
        player.setAudioAttributes(MediaFactory.playbackAudioAttributes, /* handleAudioFocus = */ audioOn)
        player.volume = if (audioOn) 1f else 0f
    }
    // Re-assert the intended volume across media transitions AND whenever the
    // player-level volume changes out from under us (#106). The reported symptom is
    // the AudioTrack going to volume 0 mid-playback while the toggle is on; whatever
    // drives that, onVolumeChanged catches it and restores the intended level. The
    // write converges (setting volume to the intended value re-fires onVolumeChanged
    // with a matching value, which is then a no-op), so there is no feedback loop.
    val currentAudioOn by rememberUpdatedState(audioOn)
    DisposableEffect(player) {
        val listener = object : Player.Listener {
            private fun reassert() {
                val intended = if (currentAudioOn) 1f else 0f
                if (player.volume != intended) player.volume = intended
            }
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = reassert()
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) reassert()
            }
            override fun onAudioSessionIdChanged(audioSessionId: Int) = reassert()
            override fun onVolumeChanged(volume: Float) = reassert()
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }

    // ── Playback quality (Auto / Full / Data saver) ─────────────────────────────
    // Auto (default) = full on unmetered, low on metered/cellular; Full = always
    // the recorded main-stream bytes; Data saver = always the server's on-demand
    // 640p `low.mp4` transcode. The chosen "low" decision drives which segment URL
    // the ViewModel builds (see PlaybackViewModel.setLowQuality).
    var quality by remember { mutableStateOf(store.playbackQuality) }
    val isMetered by rememberIsMetered()
    val useLow = when (quality) {
        PlaybackQuality.FULL -> false
        PlaybackQuality.DATA_SAVER -> true
        else -> isMetered // AUTO
    }
    LaunchedEffect(useLow) { vm.setLowQuality(useLow) }

    // Frame step (paused): nudge the player by ~one frame within the current
    // segment. We derive the frame interval from the decoded stream's actual frame
    // rate (player.videoFormat.frameRate) once it's known, falling back to ~30 fps
    // (33 ms) before the first frame is decoded. SeekParameters.EXACT (set on the
    // player above) makes the seek land on the nearest frame rather than the
    // preceding keyframe, so each tap visibly advances/retreats one frame. We pause
    // and clear playWhenReady so the stepped frame is shown and held, and clamp the
    // target into [0, duration] so we never step off the ends of the segment.
    val frameStep: (Boolean) -> Unit = remember(player) {
        { forward ->
            vm.setPlaying(false)
            player.pause()
            player.playWhenReady = false
            // Clamp to a sane frame rate: some containers report garbage (e.g.
            // 90000 fps → frameMs 0 → a 1 ms no-op step) or 0/undecoded. Anything
            // outside 1.5–120 fps is not a real playback rate; fall back to 30.
            val fps = player.videoFormat?.frameRate?.takeIf { it in 1.5f..120f } ?: 30f
            val frameMs = (1000f / fps).toLong().coerceAtLeast(1L)
            val duration = player.duration.takeIf { it > 0L } ?: Long.MAX_VALUE
            // currentPosition sits at (roughly) the START of the frame on screen, so
            // seeking by exactly one frame can round back INTO the current frame's
            // window and not visibly move. Overshoot into the ADJACENT frame's
            // window — ~1.5 frames forward, ~0.5 back — and let SeekParameters.EXACT
            // (set on the player) snap to that neighbouring frame. Requires a
            // seekable SeekMap, which the recorder's `+global_sidx` segments provide;
            // without it every seek collapsed to 0 (the original bug).
            val deltaMs = if (forward) frameMs + frameMs / 2 else -(frameMs / 2 + 1)
            val target = (player.currentPosition + deltaMs).coerceIn(0L, duration)
            player.seekTo(target)
        }
    }

    // Track the last URL we fed to the player so we don't re-seek unnecessarily.
    var lastFedUrl by remember { mutableStateOf<String?>(null) }
    var lastFedOffsetMs by remember { mutableLongStateOf(-1L) }
    // The next-segment URL already appended to ExoPlayer's playlist via
    // addMediaSource (see the prefetch-queue effect below), if any. Lets the feed
    // effect below tell a GAPLESS auto-advance (the player already switched to
    // this item on its own, per onMediaItemTransition) apart from a genuinely new
    // URL that needs a hard setMediaSource — the fix for #10's segment-boundary
    // hitch is exactly this distinction: don't re-load what ExoPlayer already
    // transitioned to internally.
    var queuedNextUrl by remember { mutableStateOf<String?>(null) }

    // Feed a new segment to ExoPlayer whenever the VM resolves one.
    LaunchedEffect(state.currentSegmentUrl, state.segmentOffsetMs) {
        val url = state.currentSegmentUrl ?: return@LaunchedEffect
        if (url != lastFedUrl) {
            if (url == queuedNextUrl) {
                // Gapless promotion (#10): the VM already had this segment queued
                // on the playlist (added via addMediaSource) and ExoPlayer has
                // ALREADY transitioned to it internally (onMediaItemTransition
                // fired onAdvancedToNextSegment(), which is what put currentSegmentUrl
                // here). Do NOT setMediaSource/prepare again — that would tear
                // down and reload the item that's already playing, causing
                // exactly the visible freeze this fix removes. Just update our
                // bookkeeping to match.
                queuedNextUrl = null
                lastFedUrl = url
                lastFedOffsetMs = 0L
            } else {
                // Hard jump: initial load, scrub, motion-jump, or crossing a
                // recording gap. Replaces the whole playlist.
                val source = MediaFactory.httpSource(url)
                player.setMediaSource(source)
                player.prepare()
                if (state.segmentOffsetMs > 0L) {
                    player.seekTo(state.segmentOffsetMs)
                }
                player.playWhenReady = state.playing
                lastFedUrl = url
                lastFedOffsetMs = state.segmentOffsetMs
                // Whatever was queued (if anything) belonged to the segment we're
                // jumping away from — it's no longer valid to skip-load later.
                queuedNextUrl = null
            }
        } else if (state.segmentOffsetMs != lastFedOffsetMs && state.segmentOffsetMs >= 0L) {
            player.seekTo(state.segmentOffsetMs)
            lastFedOffsetMs = state.segmentOffsetMs
        }
    }

    // Queue the VM's pre-resolved next segment onto ExoPlayer's playlist ahead of
    // time (#10 gapless fix). addMediaSource APPENDS after the currently playing
    // item rather than replacing it, so ExoPlayer can transition into it on its
    // own the instant the current item ends — no STATE_ENDED, no network wait,
    // no visible hitch. Guarded so we only ever queue a given URL once.
    LaunchedEffect(state.nextSegmentUrl) {
        val nextUrl = state.nextSegmentUrl ?: return@LaunchedEffect
        if (nextUrl == queuedNextUrl || nextUrl == lastFedUrl) return@LaunchedEffect
        player.addMediaSource(MediaFactory.httpSource(nextUrl))
        queuedNextUrl = nextUrl
    }

    // Sync play/pause from VM state.
    //
    // Use explicit play()/pause() (not just playWhenReady) and handle the
    // end-of-media case: after gotoLatest we land ~1.5 s inside the last segment,
    // which can play out its buffered tail and hit STATE_ENDED almost at once. At
    // STATE_ENDED ExoPlayer IGNORES a fresh playWhenReady=true until you seek — so
    // the play button would no-op (the reported bug). Seek back into the segment
    // first, then play, so the button always starts playback.
    LaunchedEffect(state.playing) {
        if (state.scrubbing || state.jumpInProgress) return@LaunchedEffect
        if (state.playing) {
            if (player.playbackState == Player.STATE_ENDED) {
                val restart = (player.duration.takeIf { it > 0L }?.minus(200L) ?: 0L)
                    .coerceAtLeast(0L)
                player.seekTo(restart)
            }
            player.play()
        } else {
            player.pause()
        }
    }

    // Motion-event step in flight (prev/next-motion buttons): pause the player
    // IMMEDIATELY so nothing but the step itself can move the playhead (closes
    // the playhead-overwrite race — see docs/ANDROID-MOTION-EVENT-NAV-FIX.md).
    // Restores playWhenReady from state.playing once the jump lands, so a
    // paused user stays paused on the new frame and a playing user resumes.
    LaunchedEffect(state.jumpInProgress) {
        if (state.jumpInProgress) {
            player.pause()
        } else if (state.playing && !state.scrubbing) {
            player.play()
        }
    }

    // Sync playback speed from VM state.
    LaunchedEffect(state.speed) {
        player.setPlaybackSpeed(state.speed)
    }

    // Drive the playhead clock from the ACTUAL player position while playing.
    // Without this, playheadMs only advances at segment boundaries (onSegmentEnded
    // → seekTo), so the on-screen time jumps every few seconds (one short recording
    // segment at a time) instead of ticking smoothly. Poll ~4x/sec; the in-segment
    // epoch time is segment.start + player.currentPosition (position 0 == segment
    // start, since the media source begins there). Re-keys on play/scrub/segment so
    // it stops while paused or scrubbing and re-reads the new segment's start.
    //
    // This loop also triggers the #10 gapless-prefetch: once the playhead is
    // within PREFETCH_LEAD_MS_SCREEN of the segment's end, ask the VM to
    // pre-resolve the next segment so it can be queued on the ExoPlayer playlist
    // (see the addMediaSource effect above) well before STATE_ENDED would fire.
    LaunchedEffect(state.playing, state.scrubbing, state.jumpInProgress, state.currentSegment?.start) {
        if (!state.playing || state.scrubbing || state.jumpInProgress) return@LaunchedEffect
        val seg = state.currentSegment ?: return@LaunchedEffect
        val segStartMs = Time.parseToMillis(seg.start)
        while (isActive) {
            if (player.isPlaying && !state.scrubbing && !state.jumpInProgress) {
                vm.onPlaybackTick(segStartMs + player.currentPosition)
                val duration = player.duration
                if (duration > 0L && duration - player.currentPosition <= PREFETCH_LEAD_MS_SCREEN) {
                    vm.prefetchNextSegment()
                }
            }
            delay(250L)
        }
    }

    // Pause during scrub so the user gets thumbnail feedback instead of a stutter.
    LaunchedEffect(state.scrubbing) {
        if (state.scrubbing) {
            player.pause()
        } else {
            player.playWhenReady = state.playing
        }
    }

    // Listen for segment-ended (→ next segment), gapless auto-advance, and player
    // errors. Without the error path, a mid-stream 404 / dropped connection /
    // expired token drops the player to STATE_IDLE and the screen just freezes —
    // no error, no Retry, and auto-advance stalls (review A1). onPlayerError
    // re-resolves the playhead.
    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) {
                    // Fallback path only: if a prefetched next segment was queued
                    // and ExoPlayer auto-advanced into it, onMediaItemTransition
                    // below already handled it and the player would be PLAYING,
                    // not ENDED, by the time this fires (or there was no next
                    // item queued — e.g. across a recording gap — in which case
                    // this is exactly the existing behaviour: resolve fresh).
                    vm.onSegmentEnded()
                }
            }
            override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) {
                // #10 gapless fix: ExoPlayer advanced ON ITS OWN to the next
                // playlist item (the one queued via addMediaSource from the VM's
                // prefetch) — promote it locally with zero network/hitch instead
                // of waiting for STATE_ENDED. AUTO is specifically "the playlist
                // advanced without an explicit seek/command", which is exactly
                // this case; a manual seek (motion-jump, scrub-release, retry)
                // reports a different reason and is already handled by seekTo's
                // own state update, so it's excluded here to avoid double-applying.
                if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) {
                    vm.onAdvancedToNextSegment()
                }
            }
            override fun onPlayerError(error: PlaybackException) {
                // Fall back off the low variant ONLY when the `/low.mp4` URL itself
                // HTTP-errored (server has no such endpoint, or a transcode 5xx'd).
                // A generic error — expired media token, a transient network blip —
                // must NOT permanently disable Data saver for the session (Fable
                // HIGH#1); the normal re-resolve below already refreshes the token.
                var c: Throwable? = error
                var badLowUrl = false
                while (c != null) {
                    if (c is HttpDataSource.InvalidResponseCodeException) {
                        badLowUrl = c.dataSpec.uri.toString().contains("/low.mp4")
                        break
                    }
                    c = c.cause
                }
                if (badLowUrl) vm.noteLowQualityFailed()
                vm.onPlayerError()
            }
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }

    // Position-stall watchdog (review A1): a silent freeze — decoder wedge or a
    // stalled socket that emits no error — leaves the player READY + playWhenReady
    // but currentPosition frozen, so the clock stops with no error event. Detect
    // no progress over ~6s and re-resolve to recover.
    LaunchedEffect(state.playing, state.currentSegment?.start) {
        if (!state.playing) return@LaunchedEffect
        var lastPos = -1L
        var stalledMs = 0L
        while (isActive) {
            delay(1000L)
            if (state.scrubbing) { lastPos = -1L; stalledMs = 0L; continue }
            val active = player.playWhenReady && player.playbackState == Player.STATE_READY
            if (active) {
                val pos = player.currentPosition
                if (pos == lastPos) {
                    stalledMs += 1000L
                    if (stalledMs >= 6000L) { vm.onPlayerError(); stalledMs = 0L }
                } else {
                    stalledMs = 0L
                }
                lastPos = pos
            } else {
                lastPos = -1L; stalledMs = 0L
            }
        }
    }

    // Pause when backgrounded; release on full dispose.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, player) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> player.pause()
                Lifecycle.Event.ON_RESUME -> if (state.playing && !state.scrubbing) player.play()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            player.release()
        }
    }

    // Show transient errors in the snackbar; clear them from VM after display.
    LaunchedEffect(state.error) {
        val msg = state.error ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(msg)
        vm.clearError()
    }

    // Motion-event step feedback (first/last event reached, no motion data, or
    // the offline fallback exhausted) — never a silent no-op (RC5).
    LaunchedEffect(Unit) {
        vm.toast.collect { msg -> snackbarHostState.showSnackbar(msg) }
    }

    // Snapshot: capture the current video frame (TextureView) → device gallery.
    //
    // Honour the "Snapshot captures" preference: when set to "Current view" AND the
    // frame is actually zoomed (scale > 1), crop the captured bitmap to the visible
    // viewport derived from the zoom/pan transform; otherwise save the full frame.
    // The TextureView captures at view-space resolution, so the transform's
    // view-space offset/scale map directly onto the bitmap (visible source-rect =
    // [offset, offset + dim/scale]).
    val onSnapshot: () -> Unit = {
        val tv = playerView?.videoSurfaceView as? TextureView
        val full = tv?.takeIf { it.isAvailable }?.bitmap
        scope.launch {
            if (full != null) {
                val bmp = if (container.store.snapshotCapturesView && viewTransform.scale > 1.001f) {
                    cropToViewport(full, viewTransform)
                } else {
                    full
                }
                val saved = saveFrameToGallery(context, bmp, state.cameraName ?: cameraId)
                if (saved != null) {
                    val res = snackbarHostState.showSnackbar(
                        message = "Snapshot saved to ${saved.displayPath}",
                        actionLabel = "Share",
                        duration = SnackbarDuration.Long,
                    )
                    if (res == SnackbarResult.ActionPerformed) {
                        shareImageUri(context, saved.shareUri)
                    }
                } else {
                    snackbarHostState.showSnackbar("Snapshot failed")
                }
            } else {
                snackbarHostState.showSnackbar("Snapshot unavailable — video not ready")
            }
        }
    }
    // Bookmark: capture the current playhead, then open a dialog for an optional
    // note before saving the moment server-side.
    val onBookmark: () -> Unit = {
        bookmarkAtMs = state.playheadMs
        showBookmarkDialog = true
    }

    // In landscape the phone is short: a fixed top app bar + bottom transport eat
    // most of the height, leaving the video SMALLER than in portrait. So in
    // landscape we drop the top app bar (Back/Snapshot/Bookmark float over the
    // video) and compact the transport, giving the video the height it should have.
    val isLandscape =
        LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE

    // ── UI ───────────────────────────────────────────────────────────────────────
    Scaffold(
        containerColor = NavyDeep,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            if (!isLandscape) {
            TopAppBar(
                title = {
                    // Clickable title → camera picker dropdown. This is what makes
                    // Playback a standalone mode: the user can pick ANY camera here,
                    // not just the one they entered with.
                    var pickerOpen by remember { mutableStateOf(false) }
                    Box {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable(enabled = cameraIds.size > 1) {
                                pickerOpen = true
                            },
                        ) {
                            Column {
                                Text(
                                    text = state.cameraName ?: cameraId.ifBlank { "Select camera" },
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                if (!state.loading && state.error == null && cameraId.isNotBlank()) {
                                    Text(
                                        // Date + time so the day is always clear, not just the clock.
                                        // Re-format only when the SECOND changes (display
                                        // granularity), not 4×/sec on every tick (review B3).
                                        text = remember(state.playheadMs / 1000) {
                                            Time.dateTime(Instant.ofEpochMilli(state.playheadMs))
                                        },
                                        style = MaterialTheme.typography.labelSmall,
                                        color = TextSecondary,
                                    )
                                }
                            }
                            if (cameraIds.size > 1) {
                                Icon(
                                    imageVector = Icons.Default.ArrowDropDown,
                                    contentDescription = "Switch camera",
                                    modifier = Modifier.padding(start = 2.dp),
                                )
                            }
                        }
                        DropdownMenu(
                            expanded = pickerOpen,
                            onDismissRequest = { pickerOpen = false },
                        ) {
                            cameraIds.forEach { id ->
                                DropdownMenuItem(
                                    text = { Text(cameraNames[id] ?: id) },
                                    onClick = {
                                        pickerOpen = false
                                        vm.switchCamera(id)
                                    },
                                )
                            }
                        }
                    }
                },
                navigationIcon = {
                    HintTooltip("Back to live") {
                        IconButton(onClick = onBack) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back",
                            )
                        }
                    }
                },
                // Audio on/off toggle lives here (portrait): a primary, always-
                // visible control docked in the app bar, out of the video — NOT a
                // floating overlay that lands over the footage on a letterboxed
                // pane. Only meaningful once a segment is resolved to hear.
                actions = {
                    // Quality selector (Auto / Full / Data saver) — always visible so
                    // the operator can pick a cellular-friendly stream before playing.
                    HintTooltip(PlaybackQuality.label(quality)) {
                        IconButton(
                            onClick = {
                                quality = PlaybackQuality.next(quality)
                                store.playbackQuality = quality
                            },
                        ) {
                            Text(
                                text = PlaybackQuality.short(quality),
                                color = if (quality == PlaybackQuality.AUTO) Color.White else TealAccent,
                            )
                        }
                    }
                    if (state.currentSegment != null) {
                        HintTooltip(if (audioOn) "Mute audio" else "Play audio") {
                            IconButton(
                                onClick = {
                                    audioOn = !audioOn
                                    store.playbackAudioOn = audioOn
                                },
                            ) {
                                Icon(
                                    imageVector = if (audioOn) Icons.Default.VolumeUp else Icons.Default.VolumeOff,
                                    contentDescription = if (audioOn) "Mute audio" else "Play audio",
                                    tint = if (audioOn) TealAccent else Color.White,
                                )
                            }
                        }
                    }
                },
                // Snapshot + Bookmark moved OUT of the app bar into the transport's
                // 3-dot overflow menu (portrait), keeping the bar uncluttered and the
                // secondary actions grouped where the user controls playback.
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NavySurface,
                    titleContentColor = MaterialTheme.colorScheme.onSurface,
                    navigationIconContentColor = MaterialTheme.colorScheme.onSurface,
                ),
            )
            }
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            // ── VIDEO WINDOW — bounded area that fills all space ABOVE the pinned
            //    controls; the video is letterboxed (RESIZE_MODE_FIT) within it so
            //    it stays in its own window and never grows past the screen. ──────
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    state.loading && state.currentSegment == null -> {
                        CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                    }

                    state.error != null && state.currentSegment == null && !state.loading -> {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(
                                text = state.error ?: "Unknown error",
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            Spacer(Modifier.height(8.dp))
                            Button(onClick = { vm.seekTo(state.playheadMs) }) { Text("Retry") }
                        }
                    }

                    // Scrubbed into a recording GAP (motion camera, quiet period): a
                    // 404 is expected here, not an error. Show a calm message — NOT the
                    // red error + Retry, and no snackbar (the VM left `error` null).
                    state.noFootageAtPlayhead && state.currentSegment == null && !state.loading -> {
                        Text(
                            text = "No footage at this time",
                            color = TextSecondary,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }

                    state.spans.isEmpty() && !state.loading -> {
                        Text(
                            text = "No footage in this time window",
                            color = TextSecondary,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }

                    else -> {
                        ZoomableVideoSurface(
                            modifier = Modifier.fillMaxSize(),
                            // Same gesture as Live: a horizontal swipe at 1x (fully
                            // zoomed out) advances to the next/previous camera. -1 =
                            // previous, +1 = next. Suppressed once zoomed in (the drag
                            // pans the frame instead) — handled inside the surface.
                            onSwipeCamera = if (cameraIds.size > 1) {
                                { dir -> switchCameraByOffset(dir) }
                            } else {
                                null
                            },
                            // Track zoom/pan so a "Current view" snapshot can crop to
                            // exactly what's on screen.
                            onTransformChange = { viewTransform = it },
                        ) {
                            PlayerSurface(
                                player = player,
                                modifier = Modifier.fillMaxSize(),
                                textureView = true,
                                onViewReady = { playerView = it },
                            )
                        }
                        // Filmstrip thumbnail overlay during scrubbing
                        if (state.scrubbing && state.scrubFrameUrl != null) {
                            Box(
                                modifier = Modifier
                                    .fillMaxSize()
                                    .background(Color.Black.copy(alpha = 0.55f)),
                                contentAlignment = Alignment.Center,
                            ) {
                                AsyncImage(
                                    model = state.scrubFrameUrl,
                                    contentDescription = "Scrub preview",
                                    contentScale = ContentScale.Fit,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }
                        }
                        // Loading spinner when buffering mid-segment
                        if (state.loading && state.currentSegment != null) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(40.dp),
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                }

                // Landscape: top app bar is hidden, so float Back over the video
                // (Snapshot/Bookmark live in the bottom transport bar below).
                if (isLandscape) {
                    HintTooltip("Back to live") {
                        IconButton(
                            onClick = onBack,
                            modifier = Modifier.align(Alignment.TopStart).padding(2.dp),
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back",
                                tint = Color.White,
                            )
                        }
                    }
                }
                // (Audio toggle: portrait → top app bar actions; landscape → inline
                // on the transport row below, next to Snapshot/Bookmark. It is NOT
                // floated over the video in either orientation.)
            }

            // ── PINNED transport bar (controls + timeline) at the bottom ──────────
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(NavySurface),
            ) {
                // Top breathing room above the transport. Snapshot + Bookmark are no
                // longer a separate landscape row (that made the bar too tall) — in
                // landscape they ride along ON the transport row itself; in portrait
                // they live in the top app bar.
                Spacer(Modifier.height(if (isLandscape) 2.dp else 6.dp))
                PlaybackControls(
                    playing = state.playing,
                    speed = state.speed,
                    onPlayPause = { vm.setPlaying(!state.playing) },
                    onPrevMotion = { vm.stepMotion(forward = false) },
                    onNextMotion = { vm.stepMotion(forward = true) },
                    onSetSpeed = { vm.setSpeed(it) },
                    onJumpToTime = { epochMs -> vm.jumpToTime(epochMs) },
                    onGotoFirst = { vm.gotoFirst() },
                    onGotoLast = { vm.gotoLast() },
                    onStepBack = { frameStep(false) },
                    onStepFwd = { frameStep(true) },
                    currentPlayheadMs = state.playheadMs,
                    // Landscape: the top app bar is hidden, so the transport runs a
                    // notch smaller and hosts Snapshot + Bookmark on the same line.
                    compact = isLandscape,
                    onSnapshot = onSnapshot,
                    // null hides the bookmark control (transport uses onBookmark?.let)
                    onBookmark = if (bookmarksEnabled) onBookmark else null,
                    // Landscape hosts the audio toggle inline on this row (portrait
                    // uses the app bar). Gate on a resolved segment, same as portrait.
                    audioOn = audioOn,
                    onToggleAudio = if (state.currentSegment != null) {
                        { audioOn = !audioOn; store.playbackAudioOn = audioOn }
                    } else {
                        null
                    },
                    // Landscape hosts the quality selector inline too (portrait uses
                    // the app bar).
                    quality = quality,
                    onCycleQuality = {
                        quality = PlaybackQuality.next(quality)
                        store.playbackQuality = quality
                    },
                    // Portrait can't fit every control inline (the snapshot button was
                    // being clipped), so the SECONDARY actions (snapshot, bookmark,
                    // jump-to-time, speed) collapse into a 3-dot overflow menu. In
                    // landscape they ride inline on the (taller-width) transport row.
                    useOverflowMenu = !isLandscape,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp),
                )
                CenteredTimeline(
                    spans = state.spans,
                    motionBuckets = state.motionBuckets,
                    motionStartMs = state.motionStartMs,
                    motionEndMs = state.motionEndMs,
                    detectionEvents = state.detectionEvents,
                    bookmarks = bookmarks,
                    playheadMs = state.playheadMs,
                    spanMs = state.visibleSpanMs,
                    onScrubStart = { vm.onScrubStart() },
                    onScrub = { ts -> vm.onScrub(ts) },
                    onScrubEnd = { ts -> vm.onScrubEnd(ts) },
                    onSpanChange = { sp -> vm.setVisibleSpan(sp) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(if (isLandscape) 40.dp else 72.dp)
                        .padding(horizontal = 8.dp),
                )
                Spacer(Modifier.height(if (isLandscape) 2.dp else 6.dp))
            }
        }
    }

    // "Add bookmark" dialog — easy one-tap Save, with an optional note.
    if (showBookmarkDialog) {
        val atMs = bookmarkAtMs
        AddBookmarkDialog(
            atMs = atMs,
            onConfirm = { desc, protectDays, preS, postS ->
                showBookmarkDialog = false
                scope.launch {
                    container.repository.addBookmark(
                        cameraId,
                        Time.iso(Instant.ofEpochMilli(atMs)),
                        desc,
                        protectDays = protectDays,
                        protectPreSeconds = preS,
                        protectPostSeconds = postS,
                    ).onSuccess {
                        reloadBookmarks()
                        snackbarHostState.showSnackbar(
                            "Bookmark added · ${Time.dateTime(Instant.ofEpochMilli(atMs))}",
                        )
                    }.onFailure {
                        snackbarHostState.showSnackbar("Couldn't add bookmark")
                    }
                }
            },
            onDismiss = { showBookmarkDialog = false },
        )
    }
}

/**
 * Row of playback transport controls.
 *
 * PRIMARY controls are always inline: go-to-first, frame step back, prev-motion,
 * play/pause, next-motion, frame step forward, go-to-last.
 *
 * SECONDARY actions (speed, jump-to-time, snapshot, bookmark) either ride inline
 * (landscape, where the row is wide enough) or collapse into a 3-dot overflow
 * [DropdownMenu] ([useOverflowMenu] = true, portrait) so nothing is clipped — this
 * is the N1 fix for the cut-off snapshot button in portrait.
 */
@Composable
private fun PlaybackControls(
    playing: Boolean,
    speed: Float,
    onPlayPause: () -> Unit,
    onPrevMotion: () -> Unit,
    onNextMotion: () -> Unit,
    onSetSpeed: (Float) -> Unit,
    onJumpToTime: (Long) -> Unit,
    onGotoFirst: () -> Unit,
    onGotoLast: () -> Unit,
    onStepBack: () -> Unit,
    onStepFwd: () -> Unit,
    currentPlayheadMs: Long,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
    useOverflowMenu: Boolean = false,
    onSnapshot: (() -> Unit)? = null,
    onBookmark: (() -> Unit)? = null,
    // Audio toggle rides inline on the landscape transport row (in portrait it
    // lives in the top app bar instead). null hides it.
    audioOn: Boolean = false,
    onToggleAudio: (() -> Unit)? = null,
    // Quality selector (Auto/Full/Data saver) rides inline on the landscape row
    // too. null hides it (portrait uses the app bar chip).
    quality: String = PlaybackQuality.AUTO,
    onCycleQuality: (() -> Unit)? = null,
) {
    // Landscape is vertically cramped, so the transport runs a notch smaller there
    // (this is what "shrinks the play/pause bar"). Portrait keeps its roomier sizes.
    val ctlSize = if (compact) 30.dp else 38.dp
    val ctlIcon = if (compact) 18.dp else 22.dp
    val playSize = if (compact) 38.dp else 50.dp
    val playIcon = if (compact) 22.dp else 28.dp

    // Shared launcher for the date+time "jump to" picker (used inline AND from the
    // overflow menu). Opens the reliable Material3 date→time dialog rendered below
    // (replaces the old native spinner DatePickerDialog, whose date step never
    // advanced to the time step on modern Android — "only picks date").
    var showJump by remember { mutableStateOf(false) }
    val launchJumpPicker: () -> Unit = { showJump = true }

    if (showJump) {
        JumpToDateTimeDialog(
            initialMs = currentPlayheadMs,
            onDismiss = { showJump = false },
            onPicked = { target ->
                showJump = false
                onJumpToTime(target)
            },
        )
    }

    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // ── PRIMARY transport (always inline) ────────────────────────────────────
        // Go to first (earliest footage)
        SmallControl(Icons.Default.FirstPage, "Go to first recording", ctlSize, ctlIcon, onGotoFirst)
        // Frame step back
        SmallControl(Icons.Default.NavigateBefore, "Step back one frame", ctlSize, ctlIcon, onStepBack)
        // Previous motion — chevron + running-person so it reads "jump to MOTION".
        MotionJumpControl(forward = false, size = ctlSize, iconSize = ctlIcon, onClick = onPrevMotion)

        Spacer(Modifier.width(2.dp))

        // Play / Pause
        HintTooltip(if (playing) "Pause" else "Play") {
            IconButton(
                onClick = onPlayPause,
                modifier = Modifier
                    .size(playSize)
                    .background(color = MaterialTheme.colorScheme.primary, shape = CircleShape),
            ) {
                Icon(
                    imageVector = if (playing) Icons.Default.Pause else Icons.Default.PlayArrow,
                    contentDescription = if (playing) "Pause" else "Play",
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(playIcon),
                )
            }
        }

        Spacer(Modifier.width(2.dp))

        // Next motion — running-person + chevron (mirror of previous-motion).
        MotionJumpControl(forward = true, size = ctlSize, iconSize = ctlIcon, onClick = onNextMotion)
        // Frame step forward
        SmallControl(Icons.Default.NavigateNext, "Step forward one frame", ctlSize, ctlIcon, onStepFwd)
        // Go to last (latest footage)
        SmallControl(Icons.Default.LastPage, "Go to last recording", ctlSize, ctlIcon, onGotoLast)

        Spacer(Modifier.width(6.dp))

        if (useOverflowMenu) {
            // ── SECONDARY actions in a 3-dot overflow menu (portrait) ─────────────
            // Keeps the row inside the screen width — the snapshot button was being
            // clipped when all of these rode inline. Menu items carry text labels.
            Box {
                var menuOpen by remember { mutableStateOf(false) }
                HintTooltip("More controls") {
                    IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(ctlSize)) {
                        Icon(
                            Icons.Default.MoreVert,
                            contentDescription = "More controls",
                            tint = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.size(ctlIcon),
                        )
                    }
                }
                DropdownMenu(
                    expanded = menuOpen,
                    onDismissRequest = { menuOpen = false },
                ) {
                    onSnapshot?.let { cb ->
                        DropdownMenuItem(
                            text = { Text("Snapshot") },
                            leadingIcon = { Icon(Icons.Default.PhotoCamera, contentDescription = null) },
                            onClick = { menuOpen = false; cb() },
                        )
                    }
                    onBookmark?.let { cb ->
                        DropdownMenuItem(
                            text = { Text("Add bookmark") },
                            leadingIcon = { Icon(Icons.Default.BookmarkAdd, contentDescription = null) },
                            onClick = { menuOpen = false; cb() },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("Jump to date & time") },
                        leadingIcon = { Icon(Icons.Default.Schedule, contentDescription = null) },
                        onClick = { menuOpen = false; launchJumpPicker() },
                    )
                    // Speed — a small inline radio-ish list inside the menu (each speed
                    // is its own item; the current one is bold/accented).
                    Box1pxMenuDivider()
                    Text(
                        text = "Playback speed",
                        style = MaterialTheme.typography.labelSmall,
                        color = TextSecondary,
                        modifier = Modifier.padding(start = 12.dp, top = 6.dp, bottom = 2.dp),
                    )
                    listOf(8f, 4f, 2f, 1f, 0.5f).forEach { s ->
                        val isCurrent = s == speed
                        DropdownMenuItem(
                            text = {
                                Text(
                                    speedLabel(s),
                                    fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                                    color = if (isCurrent) MaterialTheme.colorScheme.primary
                                            else MaterialTheme.colorScheme.onSurface,
                                )
                            },
                            onClick = { onSetSpeed(s); menuOpen = false },
                        )
                    }
                }
            }
        } else {
            // ── SECONDARY actions inline (landscape — the row is wide enough) ──────
            // Speed picker — tap to EXPAND a menu of speeds and pick one (instead of
            // cycling). The transport bar sits at the bottom of the screen, so the
            // menu opens UPWARD; fastest is at the top so scanning up = faster.
            Box {
                var speedMenuOpen by remember { mutableStateOf(false) }
                HintTooltip("Playback speed") {
                    FilledTonalButton(
                        onClick = { speedMenuOpen = true },
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 10.dp, end = 4.dp),
                        colors = ButtonDefaults.filledTonalButtonColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant,
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                    ) {
                        Text(speedLabel(speed), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
                        Icon(Icons.Default.ArrowDropUp, contentDescription = "Pick speed", modifier = Modifier.size(18.dp))
                    }
                }
                DropdownMenu(
                    expanded = speedMenuOpen,
                    onDismissRequest = { speedMenuOpen = false },
                ) {
                    listOf(8f, 4f, 2f, 1f, 0.5f).forEach { s ->
                        val isCurrent = s == speed
                        DropdownMenuItem(
                            text = {
                                Text(
                                    speedLabel(s),
                                    fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                                    color = if (isCurrent) MaterialTheme.colorScheme.primary
                                            else MaterialTheme.colorScheme.onSurface,
                                )
                            },
                            onClick = { onSetSpeed(s); speedMenuOpen = false },
                        )
                    }
                }
            }

            // Jump-to-date-and-time button — DatePicker → TimePicker.
            SmallControl(Icons.Default.Schedule, "Jump to date & time", ctlSize, ctlIcon, launchJumpPicker)

            // Snapshot + Bookmark share this transport row in landscape (the app bar
            // is hidden there). In portrait they live in the overflow menu above.
            if (onSnapshot != null || onBookmark != null || onToggleAudio != null || onCycleQuality != null) {
                Spacer(Modifier.width(6.dp))
                onSnapshot?.let {
                    SmallControl(Icons.Default.PhotoCamera, "Snapshot", ctlSize, ctlIcon, it)
                }
                onBookmark?.let {
                    SmallControl(Icons.Default.BookmarkAdd, "Add bookmark", ctlSize, ctlIcon, it)
                }
                // Quality selector (Auto/Full/Data saver) — a compact text chip
                // matching the portrait app-bar control.
                onCycleQuality?.let { cycle ->
                    HintTooltip(PlaybackQuality.label(quality)) {
                        IconButton(onClick = cycle, modifier = Modifier.size(ctlSize)) {
                            Text(
                                text = PlaybackQuality.short(quality),
                                color = if (quality == PlaybackQuality.AUTO) Color.White else TealAccent,
                            )
                        }
                    }
                }
                // Audio on/off — same row as Snapshot/Bookmark in landscape (teal
                // when on), instead of a float that lands over the video.
                onToggleAudio?.let { toggle ->
                    HintTooltip(if (audioOn) "Mute audio" else "Play audio") {
                        IconButton(onClick = toggle, modifier = Modifier.size(ctlSize)) {
                            Icon(
                                imageVector = if (audioOn) Icons.Default.VolumeUp else Icons.Default.VolumeOff,
                                contentDescription = if (audioOn) "Mute audio" else "Play audio",
                                tint = if (audioOn) TealAccent else Color.White,
                                modifier = Modifier.size(ctlIcon),
                            )
                        }
                    }
                }
            }
        }
    }
}

/** A thin divider used inside the transport overflow DropdownMenu. */
@Composable
private fun Box1pxMenuDivider() {
    Spacer(
        Modifier
            .fillMaxWidth()
            .padding(top = 4.dp)
            .height(1.dp)
            .background(NavyDeep),
    )
}

/**
 * Prev/next-**motion** transport control: a directional chevron paired with the
 * running-person motion glyph, so it's obvious the jump targets a MOTION event
 * rather than a generic skip/fast-forward. Chevron points the travel direction;
 * the accent-tinted runner is the "motion" cue.
 */
@Composable
private fun MotionJumpControl(
    forward: Boolean,
    size: Dp,
    iconSize: Dp,
    onClick: () -> Unit,
) {
    val glyph = iconSize * 0.74f
    HintTooltip(if (forward) "Next motion event" else "Previous motion event") {
    IconButton(
        onClick = onClick,
        modifier = Modifier.width(size * 1.3f).height(size),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (!forward) {
                Icon(
                    Icons.Default.ChevronLeft,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.size(glyph),
                )
            }
            Icon(
                imageVector = Icons.Default.DirectionsRun,
                contentDescription = if (forward) "Next motion event" else "Previous motion event",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(glyph),
            )
            if (forward) {
                Icon(
                    Icons.Default.ChevronRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.size(glyph),
                )
            }
        }
    }
    }
}

/** Compact transport icon button, sized by the caller (smaller in landscape). The
 *  [desc] doubles as the long-press hint tooltip text. */
@Composable
private fun SmallControl(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    desc: String,
    size: Dp,
    iconSize: Dp,
    onClick: () -> Unit,
) {
    HintTooltip(desc) {
        IconButton(onClick = onClick, modifier = Modifier.size(size)) {
            Icon(icon, contentDescription = desc, tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(iconSize))
        }
    }
}

private fun speedLabel(speed: Float): String = when (speed) {
    0.5f -> "0.5x"
    1f -> "1x"
    2f -> "2x"
    4f -> "4x"
    8f -> "8x"
    else -> "${speed}x"
}

/**
 * Crop a captured full-frame [bitmap] down to the on-screen viewport described by
 * [transform] (from [ZoomableVideoSurface]). The surface captures at view-space
 * resolution and uses a top-left transform origin with `translation = -offset *
 * scale`, so the visible region in view-space px is
 * `[offsetX, offsetX + viewW/scale] × [offsetY, offsetY + viewH/scale]`. Because the
 * TextureView bitmap matches the view's pixel size, those view-space coordinates map
 * 1:1 onto the bitmap. Returns the original bitmap unchanged if not zoomed or if the
 * computed crop is degenerate.
 */
private fun cropToViewport(bitmap: android.graphics.Bitmap, transform: ViewTransform): android.graphics.Bitmap {
    val scale = transform.scale
    if (scale <= 1.001f) return bitmap
    val w = bitmap.width
    val h = bitmap.height
    if (w <= 0 || h <= 0) return bitmap
    val cropW = (w / scale).toInt().coerceIn(1, w)
    val cropH = (h / scale).toInt().coerceIn(1, h)
    val left = transform.offsetX.toInt().coerceIn(0, w - cropW)
    val top = transform.offsetY.toInt().coerceIn(0, h - cropH)
    return try {
        android.graphics.Bitmap.createBitmap(bitmap, left, top, cropW, cropH)
    } catch (e: Exception) {
        android.util.Log.w("Snapshot", "viewport crop failed; saving full frame", e)
        bitmap
    }
}
