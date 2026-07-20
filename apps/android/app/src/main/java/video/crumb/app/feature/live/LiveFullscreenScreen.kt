// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.ControlCamera
import androidx.compose.material.icons.filled.DirectionsRun
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import video.crumb.app.LocalPipController
import video.crumb.app.ui.CameraNav
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.ImmersiveMode
import video.crumb.app.ui.KeepScreenOn
import video.crumb.app.data.HaLinkDto
import video.crumb.app.data.HaStatesResponse
import video.crumb.app.data.PtzPresetDto
import video.crumb.app.di.appContainer
import video.crumb.app.ui.player.MediaFactory
import video.crumb.app.ui.player.PlayerSurface
import video.crumb.app.ui.player.ZoomableVideoSurface
import video.crumb.app.ui.theme.DangerRed
import video.crumb.app.ui.theme.TealAccent
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Full-screen live view for a single camera.
 *
 * Plays the main RTSP stream (highest quality, suitable for a full-screen
 * single-camera view). The stream URL is resolved on composition via
 * [CrumbRepository.liveStreams]; a loading spinner is shown while the
 * network call is in-flight and while the player is buffering.
 *
 * H265-main fallback: many cameras (e.g. Uniview LPR) ship an **H265 main +
 * H264 sub**, and Media3's RTSP stack can't reliably bring up H265 over RTSP —
 * the main would spin/error forever even though the wall tiles (which play the
 * H264 sub) work fine. So if the main stream never reaches a playable frame we
 * downgrade to the **sub** stream and show a small "SD" badge. A main that
 * plays and *then* drops is treated as a transient blip and reconnects to main
 * (no permanent downgrade). Recorded playback is unaffected (fMP4 over HTTP
 * decodes H265 fine; only the live RTSP path has the depacketizer limitation).
 *
 * Controls are minimal to preserve immersion: a back arrow (top-left) and a
 * playback shortcut (top-right) float over the black video surface.
 *
 * @param cameraId The camera to display.
 * @param onBack Navigate back to the live wall.
 * @param onOpenPlayback Navigate to the timeline/playback screen for this camera.
 * @param onTuneMotion Navigate to the motion tuner for this camera (admin-only).
 */
@OptIn(UnstableApi::class)
@Composable
fun LiveFullscreenScreen(
    cameraId: String,
    onBack: () -> Unit,
    onOpenPlayback: (String) -> Unit,
    onTuneMotion: (String) -> Unit = {},
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val container = appContainer()
    val repo = container.repository
    val store = container.store
    val scope = rememberCoroutineScope()

    // The camera currently shown. Initialised from the nav arg; a horizontal
    // swipe at 1x (handled in ZoomableVideoSurface) moves to the next/previous
    // camera in wall order without leaving this screen — every cameraId-keyed
    // effect below re-runs to swap the stream, PTZ probe, etc.
    var currentCameraId by remember { mutableStateOf(cameraId) }
    // Ordered enabled-camera ids (same order as the live wall) for swipe nav.
    var cameraIds by remember { mutableStateOf<List<String>>(emptyList()) }
    var cameraNames by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    LaunchedEffect(Unit) {
        repo.visibleCameras().onSuccess { list ->
            cameraIds = list.filter { it.enabled }.map { it.id }
            cameraNames = list.associate { it.id to it.name }
        }
    }

    // Home Assistant: the entities linked to the current camera. Drives BOTH the
    // read-only list sheet (HA button) and the on-video badges the operator
    // placed on the desktop overlay editor (issue #263) — placed links render as
    // badges pinned to the video frame; tapping one opens the same detail dialog.
    var haLinks by remember { mutableStateOf<List<HaLinkDto>>(emptyList()) }
    var haStates by remember { mutableStateOf<HaStatesResponse?>(null) }
    var haSheetOpen by remember { mutableStateOf(false) }
    var haBadgeSelected by remember { mutableStateOf<HaLinkDto?>(null) }
    LaunchedEffect(currentCameraId) {
        haLinks = emptyList()
        haSheetOpen = false
        haBadgeSelected = null
        repo.haLinks(currentCameraId).onSuccess { haLinks = it }
    }
    // Poll HA states while this camera has linked entities (to keep the on-video
    // badges live) or the sheet is open. Server demand-caches with a ~2s TTL.
    // Gate on lifecycle so it doesn't poll while backgrounded, and back off under
    // failure (matches the motion poll below).
    val haHasPlaced = haLinks.any { it.hasPlacement }
    LaunchedEffect(currentCameraId, haHasPlaced, haSheetOpen) {
        if (!haHasPlaced && !haSheetOpen) return@LaunchedEffect
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            var failStreak = 0
            while (true) {
                val res = repo.haStates().onSuccess { haStates = it }
                failStreak = if (res.isSuccess) 0 else failStreak + 1
                kotlinx.coroutines.delay(
                    if (failStreak == 0) 2000L else (2000L shl (failStreak - 1)).coerceAtMost(30000L),
                )
            }
        }
    }
    // Decoded video pixel size (for contain-fit badge placement) and the current
    // digital-zoom scale (badges hide while zoomed — they'd misalign, matching
    // the desktop `hideBadges: scale > 1.01` rule). Both feed HaBadgeOverlayLayer.
    var videoSize by remember { mutableStateOf(IntSize.Zero) }
    var zoomScale by remember { mutableStateOf(1f) }

    // Picture-in-Picture: while this full-screen camera is up, let the Activity
    // auto-enter PiP when the user leaves the app so the video keeps playing in a
    // floating window. `inPip` drives chrome hiding (PiP shows only the video).
    val pip = LocalPipController.current
    val inPip = pip.isInPip
    DisposableEffect(Unit) {
        pip.setVideoActive(true)
        onDispose { pip.setVideoActive(false) }
    }

    // Enter true fullscreen (hide system bars) while the single-cam view is up.
    // Disabled in PiP so the floating window chrome is unaffected.
    ImmersiveMode(enabled = !inPip)
    // Keep the display awake while watching a single camera (not in PiP, where the
    // system manages the floating window's own lifecycle).
    KeepScreenOn(enabled = !inPip)

    // Resolved RTSP URLs. `rtspUrl` is the ACTIVE url fed to the player: it starts
    // as the main (HD) stream and is swapped to `subUrl` if the main can't play on
    // this device (H265-over-RTSP — see the header). `mainUrl`/`subUrl` are the two
    // resolved endpoints; all are re-keyed on the shown camera so a swipe resets them.
    var rtspUrl by remember { mutableStateOf<String?>(null) }
    var mainUrl by remember(currentCameraId) { mutableStateOf<String?>(null) }
    var subUrl by remember(currentCameraId) { mutableStateOf<String?>(null) }
    // True once we've downgraded to the sub stream because the main never played.
    var usingSub by remember(currentCameraId) { mutableStateOf(false) }
    // Drives the subtle "SD" badge: the main (HD) stream was unplayable, on sub now.
    var hdUnavailable by remember(currentCameraId) { mutableStateOf(false) }
    var resolveError by remember { mutableStateOf<String?>(null) }
    var isResolving by remember { mutableStateOf(true) }

    // Player playback state.
    var isBuffering by remember { mutableStateOf(true) }
    // Hard error: only set after auto-reconnect exhausts its FAST attempts (the
    // manual-fallback message). No longer a dead end (#2) — the message is
    // tappable to retry immediately, and a slow background cadence keeps trying
    // on its own regardless. Distinct from the soft reconnecting state below.
    var playerError by remember { mutableStateOf(false) }
    // Soft reconnect state: an exponential-backoff re-prepare is pending; show a
    // subtle "Reconnecting…" badge while the last frame stays on screen.
    var isReconnecting by remember { mutableStateOf(false) }

    // Device connectivity (#3, mirrors the live-wall tiles): while offline, the
    // fullscreen reconnect loop pauses instead of burning its fast-attempt budget
    // against a link that can't reach the server at all.
    val isOnline by rememberIsOnline()

    // Metered/cellular signal: on a metered link, fullscreen live starts on a
    // data-saver stream (sub, or the on-demand mobile transcode when there is no
    // sub) instead of the HD main — the SD badge lets the user tap for HD.
    val isMetered by rememberIsMetered()

    // Bumped to force a fresh `remember(rtspUrl, playerGeneration)` player without
    // touching rtspUrl — tap-to-retry (#2) rebuilds from scratch (fresh backoff
    // `attempt`) instead of waiting out the rest of the slow retry cadence.
    var playerGeneration by remember(rtspUrl) { mutableStateOf(0) }

    // Audio (play-on-focus). The fullscreen camera is the "focused" one, so it
    // plays audio by default; the user's choice is persisted across sessions.
    var audioOn by remember { mutableStateOf(store.liveAudioOn) }

    // PTZ: probe whether this camera supports it AND the user has the ptz capability.
    // Admins always get PTZ; viewers need capabilities.ptz = true.
    val ptzAllowed = store.isAdmin || store.capabilities.ptz
    var isPtz by remember(currentCameraId) { mutableStateOf(false) }
    var ptzVisible by remember(currentCameraId) { mutableStateOf(false) }
    // The camera's recallable PTZ presets (empty until probed / if none configured).
    var ptzPresets by remember(currentCameraId) { mutableStateOf<List<PtzPresetDto>>(emptyList()) }
    var presetsMenuOpen by remember(currentCameraId) { mutableStateOf(false) }
    // On-screen control style: "wheel" (joystick ring) or "edges" (edge-pinned
    // arrows). User-selectable + persisted; the toggle lives in the PTZ overlay.
    var ptzStyle by remember { mutableStateOf(store.ptzStyle) }
    // Throttle ContinuousMove sends — each ONVIF call is a full round-trip, so we
    // only send when the velocity changes meaningfully (ContinuousMove persists).
    var lastPan by remember { mutableStateOf(0f) }
    var lastTilt by remember { mutableStateOf(0f) }

    LaunchedEffect(currentCameraId) {
        if (ptzAllowed) {
            repo.ptzPresets(currentCameraId)
                .onSuccess { isPtz = true; ptzPresets = it }
                .onFailure { isPtz = false; ptzPresets = emptyList() }
        } else {
            isPtz = false
            ptzPresets = emptyList()
        }
    }

    // Poll /status every 2s for this camera's "motion now" state → red running-
    // person badge (commercial-VMS-style). Re-keyed when the shown camera changes.
    var motionNow by remember(currentCameraId) { mutableStateOf(false) }
    LaunchedEffect(currentCameraId) {
        // Gate on lifecycle so it doesn't poll while backgrounded (review D3) and
        // back off under failure (matches the live wall).
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            var failStreak = 0
            while (true) {
                val res = repo.status().onSuccess { st ->
                    motionNow = st.cameras.firstOrNull { it.id == currentCameraId }?.recentMotion == true
                }
                failStreak = if (res.isSuccess) 0 else failStreak + 1
                delay(if (failStreak == 0) 2000L else (2000L shl (failStreak - 1)).coerceAtMost(30000L))
            }
        }
    }

    // Bumped by tap-to-retry (#2) on a resolve failure to force the URL-resolve
    // effect below to re-run without needing a camera change.
    var resolveGeneration by remember(currentCameraId) { mutableStateOf(0) }

    // Resolve the main RTSP URL whenever the shown camera changes (or a retry is
    // requested via resolveGeneration).
    DisposableEffect(currentCameraId, resolveGeneration) {
        val job = scope.launch {
            isResolving = true
            resolveError = null
            // Drop the previous camera's URL so its player tears down immediately
            // (clean swap to a spinner) instead of lingering on the old frame.
            rtspUrl = null
            repo.liveStreams(currentCameraId).fold(
                onSuccess = { streams ->
                    mainUrl = streams.rtspMainUrl
                    subUrl = streams.rtspSubUrl
                    // On a metered link, start on a data-saver stream: the camera's
                    // sub when it has one, else the server's on-demand mobile
                    // transcode. Off metered (Wi-Fi/LAN), start on the main (HD)
                    // stream. Either way the codec-failure fallback + "tap for HD"
                    // badge below still apply.
                    val lowFirst = if (isMetered) (streams.rtspSubUrl ?: streams.rtspMobileUrl) else null
                    if (lowFirst != null) {
                        usingSub = true
                        hdUnavailable = true
                        rtspUrl = lowFirst
                    } else {
                        usingSub = false
                        hdUnavailable = false
                        rtspUrl = streams.rtspMainUrl
                    }
                    isResolving = false
                },
                onFailure = { cause ->
                    resolveError = cause.message ?: "Could not resolve stream"
                    isResolving = false
                },
            )
        }
        onDispose { job.cancel() }
    }

    // Build the ExoPlayer when the URL is available; tear it down on dispose.
    // Live uses the low-latency player (thin buffers + async queueing). Keyed on
    // playerGeneration too so tap-to-retry (#2) can force a fresh instance.
    val player = remember(rtspUrl, playerGeneration) {
        val url = rtspUrl ?: return@remember null
        MediaFactory.newLivePlayer(context).also { exo ->
            val source = MediaFactory.rtspSource(url)
            exo.setMediaSource(source)
            exo.prepare()
            exo.playWhenReady = true
        }
    }


    // Player.Listener for playback / error state + automatic reconnect.
    //
    // NOTE: do NOT seek here. RTSP live streams are not seekable — an earlier
    // "seek to the buffered live edge to cut latency" left the player stuck in
    // STATE_BUFFERING forever (a frozen first frame under a perpetual spinner),
    // which is exactly the spinner bug. The grid tiles work because they never
    // seek; the low-latency LoadControl (newLivePlayer) already keeps latency low.
    //
    // For 24/7 reliability we recover from transient drops (camera reboot, Wi-Fi
    // blip, AP roam) by RE-PREPARING with exponential backoff — never seeking.
    DisposableEffect(player) {
        val url = rtspUrl // captured; non-null whenever player != null
        var attempt = 0
        var reconnectJob: Job? = null
        // Did this stream ever reach a playable frame? Gates the H265-main fallback:
        // only a main that NEVER played downgrades to sub (a main that played then
        // dropped is transient and reconnects to main).
        var everReady = false

        fun scheduleReconnect() {
            if (player == null || url == null) return
            if (reconnectJob?.isActive == true) return // one already in flight
            // ── H265 / unplayable-main fallback ─────────────────────────────────
            // If the MAIN stream never reached a playable state, it's almost always a
            // codec the RTSP path can't handle on this device (Uniview LPR & many cams
            // ship an H265 main + H264 sub; Media3's RTSP HEVC depacketizer is
            // unreliable). Reconnecting to main would loop forever, so downgrade to the
            // sub stream — the same one the wall tiles play successfully.
            if (!usingSub && !everReady && subUrl != null) {
                usingSub = true
                hdUnavailable = true
                isReconnecting = false
                playerError = false
                rtspUrl = subUrl // re-keys remember(rtspUrl,…) → fresh player on sub
                return
            }
            // Offline (#3): don't burn the attempt budget on a doomed re-prepare.
            // Park in the reconnecting state; the connectivity-regained effect
            // below kicks a fresh attempt the moment isOnline flips back to true.
            if (!isOnline) {
                isReconnecting = true
                playerError = false
                return
            }
            // Past the fast-backoff budget: DON'T stop forever (#2) — fall back to
            // a slow, indefinite retry cadence so the view keeps quietly trying to
            // recover even if the user never taps the error message.
            val delayMs = if (attempt >= MAX_RECONNECT_ATTEMPTS) {
                SLOW_RETRY_INTERVAL_MS
            } else {
                // 1s, 2s, 4s, 8s … capped at MAX_BACKOFF_MS (~15s).
                (BASE_BACKOFF_MS shl attempt).coerceAtMost(MAX_BACKOFF_MS)
            }
            attempt += 1
            isReconnecting = attempt < MAX_RECONNECT_ATTEMPTS
            // Surface the hard-error message once the fast budget is exhausted,
            // but keep retrying underneath at the slow cadence (attempt keeps
            // climbing past MAX_RECONNECT_ATTEMPTS so delayMs stays at the slow
            // interval on every subsequent call).
            playerError = attempt >= MAX_RECONNECT_ATTEMPTS
            reconnectJob = scope.launch {
                delay(delayMs)
                // Re-prepare from scratch with a fresh source. Never seek.
                val source = MediaFactory.rtspSource(url)
                player.setMediaSource(source)
                player.prepare()
                player.playWhenReady = true
            }
        }

        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        isBuffering = true
                        playerError = false
                    }
                    Player.STATE_READY -> {
                        // Clear error/reconnect UI. Backoff reset is deferred to the
                        // watchdog (only after READY holds a sustained stretch) so a
                        // flapping camera keeps escalating instead of thrashing (A3).
                        isBuffering = false
                        playerError = false
                        isReconnecting = false
                        // A real frame played — this stream is good; no sub downgrade.
                        everReady = true
                    }
                    Player.STATE_ENDED, Player.STATE_IDLE -> {
                        isBuffering = false
                    }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                isBuffering = false
                // Try to reconnect before showing the hard error.
                scheduleReconnect()
            }

            override fun onVideoSizeChanged(vs: VideoSize) {
                // Decoded frame size — drives the contain-fit rect the on-video HA
                // badges are placed against (issue #263).
                if (vs.width > 0 && vs.height > 0) videoSize = IntSize(vs.width, vs.height)
            }
        }
        player?.addListener(listener)
        // Seed from the current size in case the first frame arrived before this
        // listener attached (stream swap / recomposition).
        player?.videoSize?.let { if (it.width > 0 && it.height > 0) videoSize = IntSize(it.width, it.height) }

        // ── Stall watchdog ──────────────────────────────────────────────────────
        // RTSP-over-TCP can stall WITHOUT firing onPlayerError, so the error-only
        // reconnect above can't see it and the view freezes/spins forever:
        //   (a) frozen frame — STATE_READY but no new RENDERED frames (encoder hang,
        //       AP roam, RTP stops, TCP still open) — detected via lastFrameMs (A2);
        //   (b) stuck buffering — STATE_BUFFERING that never reaches READY (the
        //       root of the direct-cam PTZ substream "spins forever" report).
        val watchdogJob = scope.launch {
            val p = player ?: return@launch
            var lastPos = -1L
            var stuckMs = 0L
            var bufferingMs = 0L
            var readyHeldMs = 0L
            while (true) {
                delay(WATCHDOG_TICK_MS)
                when (p.playbackState) {
                    Player.STATE_READY -> {
                        bufferingMs = 0L
                        // Frozen-feed detection off the PLAYBACK POSITION (reliable;
                        // a healthy stream advances it every tick) — the frame-callback
                        // approach falsely tripped reconnects. Gate on playWhenReady.
                        if (p.playWhenReady) {
                            val pos = p.currentPosition
                            if (pos == lastPos) {
                                stuckMs += WATCHDOG_TICK_MS
                                if (stuckMs >= FRAME_STALL_MS) {
                                    stuckMs = 0L; lastPos = -1L; readyHeldMs = 0L
                                    scheduleReconnect()
                                }
                            } else {
                                lastPos = pos; stuckMs = 0L
                                readyHeldMs += WATCHDOG_TICK_MS
                                if (readyHeldMs >= READY_SUSTAINED_MS && attempt != 0) attempt = 0
                            }
                        } else { lastPos = -1L; stuckMs = 0L; readyHeldMs = 0L }
                    }
                    Player.STATE_BUFFERING -> {
                        lastPos = -1L; stuckMs = 0L; readyHeldMs = 0L
                        bufferingMs += WATCHDOG_TICK_MS
                        // A main that never reaches READY can sit in BUFFERING instead
                        // of erroring (H265 the RTSP path can't decode). Fall back to
                        // sub fast in that case; once on sub, use the patient threshold.
                        val limit = if (!everReady && !usingSub && subUrl != null) {
                            MAIN_FIRSTLOAD_BUFFER_MS
                        } else {
                            STALL_BUFFERING_MS
                        }
                        if (bufferingMs >= limit) { bufferingMs = 0L; scheduleReconnect() }
                    }
                    else -> { bufferingMs = 0L; lastPos = -1L; stuckMs = 0L; readyHeldMs = 0L }
                }
            }
        }

        onDispose {
            watchdogJob.cancel()
            reconnectJob?.cancel()
            player?.removeListener(listener)
        }
    }

    // Connectivity regained (#3): scheduleReconnect() parks itself (isReconnecting,
    // no job scheduled) while offline rather than consuming the attempt budget.
    // The moment isOnline flips back to true, kick a fresh reconnect attempt
    // (jittered, though there's only one fullscreen player so the jitter mainly
    // just avoids racing a reconnect that's already about to fire from elsewhere).
    DisposableEffect(isOnline, player) {
        var job: Job? = null
        val url = rtspUrl
        if (isOnline && isReconnecting && player != null && url != null) {
            job = scope.launch {
                delay(kotlin.random.Random.nextLong(0L, 1_000L))
                val source = MediaFactory.rtspSource(url)
                player.setMediaSource(source)
                player.prepare()
                player.playWhenReady = true
            }
        }
        onDispose { job?.cancel() }
    }

    // Apply the audio on/off choice to the player whenever either changes.
    LaunchedEffect(player, audioOn) {
        player?.volume = if (audioOn) 1f else 0f
    }

    // Lifecycle-aware pause/resume and final release. We pause on ON_STOP (not
    // ON_PAUSE) so the video keeps playing while in a PiP window: entering PiP
    // fires ON_PAUSE but the Activity stays STARTED, so ON_STOP only fires when
    // the app is truly backgrounded (or the PiP window is dismissed) — at which
    // point we pause. This is what makes the camera "stay open" in PiP. IMPORTANT:
    // unlike the tile players ([LiveRtspContent]'s #9 release-on-ON_STOP), this
    // player is NEVER released here — staying alive across ON_STOP is deliberate,
    // it's the whole PiP mechanism. Only the STALENESS check below is new (#11).
    DisposableEffect(lifecycleOwner, player) {
        var stoppedAt = 0L
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    val p = player
                    val url = rtspUrl
                    val bgMs = if (stoppedAt > 0L) System.currentTimeMillis() - stoppedAt else 0L
                    // (#11) A plain play() on a long-stopped player just resumes
                    // rendering the frozen last decoded frame — reopening after
                    // hours showed that stale frame for ~4-5s before the stall
                    // watchdog eventually kicked in and forced a reconnect. Mirror
                    // the tile's staleness check: past the threshold, re-prepare
                    // from scratch (like a background reconnect) instead of
                    // trusting resume to still be live.
                    if (p != null && url != null && bgMs > LIVE_RECONNECT_AFTER_BG_MS) {
                        val source = MediaFactory.rtspSource(url)
                        p.setMediaSource(source)
                        p.prepare()
                        p.playWhenReady = true
                    } else {
                        p?.play()
                    }
                }
                Lifecycle.Event.ON_STOP -> {
                    stoppedAt = System.currentTimeMillis()
                    player?.pause()
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            player?.release()
        }
    }

    // Full-screen black canvas.
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        // Video surface — wrapped for pinch-to-zoom + pan (TextureView so the
        // graphicsLayer transform actually moves the pixels). One-finger pan is
        // suppressed while the PTZ wheel is up so single-touch reaches the wheel.
        if (player != null && !playerError) {
            ZoomableVideoSurface(
                modifier = Modifier.fillMaxSize(),
                suppressPan = ptzVisible,
                onSwipeCamera = { dir ->
                    if (cameraIds.size > 1) {
                        CameraNav.next(cameraIds, currentCameraId, dir)?.let {
                            currentCameraId = it
                            store.lastLiveCameraId = it
                        }
                    }
                },
                onTransformChange = { zoomScale = it.scale },
            ) {
                PlayerSurface(
                    player = player,
                    modifier = Modifier.fillMaxSize(),
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT,
                    textureView = true,
                )
            }
        }

        // On-video Home Assistant badges (issue #263) — the entities the operator
        // placed on the desktop overlay, pinned to the video frame. A sibling of
        // the zoom surface (not inside it), so it is hidden while digitally zoomed
        // (badges would misalign) and in PiP (video only). Only badge hit-boxes
        // are interactive; the rest passes touches through to the video/PTZ.
        if (player != null && !playerError && !inPip && zoomScale <= 1.01f) {
            HaBadgeOverlayLayer(
                links = haLinks,
                states = haStates,
                videoWidth = videoSize.width,
                videoHeight = videoSize.height,
                onBadgeTap = { haBadgeSelected = it },
            )
        }

        // Spinner while resolving URL or buffering. Suppressed during reconnect
        // (the "Reconnecting…" badge covers that). Hidden in PiP (video only).
        if (!inPip && (isResolving || (isBuffering && !playerError && !isReconnecting))) {
            CircularProgressIndicator(
                modifier = Modifier.align(Alignment.Center),
                color = TealAccent,
            )
        }

        // Subtle reconnecting badge — distinct from the hard error. The last
        // frame stays visible underneath. Hidden in PiP (video only).
        if (!inPip && isReconnecting && !playerError) {
            Row(
                modifier = Modifier
                    .align(Alignment.Center)
                    .background(
                        color = Color.Black.copy(alpha = 0.55f),
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
                    )
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    color = TealAccent,
                    strokeWidth = 2.dp,
                )
                Text(
                    text = "Reconnecting…",
                    style = MaterialTheme.typography.bodyMedium,
                    color = Color.White,
                )
            }
        }

        // "SD" badge — running the sub (or mobile) stream rather than HD main,
        // either because the main couldn't decode on this device (H265-over-RTSP)
        // or because we're on a metered link (data-saver start). TAPPABLE: forces
        // the HD (main) stream — the manual HD/SD override. Hidden in PiP.
        if (!inPip && hdUnavailable && !isResolving && !playerError) {
            Text(
                text = "SD · tap for HD",
                style = MaterialTheme.typography.labelMedium,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 8.dp)
                    .background(
                        color = Color.Black.copy(alpha = 0.55f),
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(6.dp),
                    )
                    .clickable {
                        mainUrl?.let {
                            usingSub = false
                            hdUnavailable = false
                            rtspUrl = it
                            playerGeneration += 1
                        }
                    }
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }

        // Hard error state — resolve failure, or reconnect exhausted its FAST
        // attempts (a slow background retry keeps trying regardless — see
        // scheduleReconnect above). Hidden in PiP. Tap-to-retry (#2): a resolve
        // failure re-triggers URL resolution (resolveGeneration); a player error
        // rebuilds the player from scratch (playerGeneration), resetting the
        // backoff `attempt` counter instead of waiting out the slow cadence.
        if (!inPip && !isResolving && (resolveError != null || playerError)) {
            val msg = (resolveError ?: "Stream playback failed") + "\nTap to retry"
            Text(
                text = msg,
                style = MaterialTheme.typography.bodyMedium,
                color = DangerRed,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                modifier = Modifier
                    .align(Alignment.Center)
                    .clickable {
                        if (resolveError != null) {
                            resolveGeneration += 1
                        } else {
                            // Manual retry gives the HD (main) stream another chance,
                            // even if we'd previously downgraded to sub.
                            if (mainUrl != null) {
                                usingSub = false
                                hdUnavailable = false
                                rtspUrl = mainUrl
                            }
                            playerGeneration += 1
                        }
                    },
            )
        }

        // Back button (top-left, respects status bar inset). Hidden in PiP.
        if (!inPip) {
            HintTooltip("Back to camera wall") {
                IconButton(
                    onClick = onBack,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .statusBarsPadding()
                        .padding(8.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.ArrowBack,
                        contentDescription = "Back",
                        tint = Color.White,
                    )
                }
            }
        }

        // Motion-now badge (top-start, offset past back button): red running-person,
        // commercial-VMS-style. Moved from TopCenter to avoid overlap with the top-right
        // controls row on PTZ cameras.
        if (!inPip && motionNow) {
            Row(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(start = 52.dp, top = 8.dp)
                    .background(
                        color = Color.Black.copy(alpha = 0.55f),
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(6.dp),
                    )
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Default.DirectionsRun,
                    contentDescription = "Motion detected",
                    tint = DangerRed,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = "Motion",
                    style = MaterialTheme.typography.labelMedium,
                    color = Color.White,
                )
            }
        }

        // Top-right controls: audio toggle + playback shortcut. Hidden in PiP.
        if (!inPip) {
        Row(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(8.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // PTZ toggle (only for PTZ-capable cameras) — shows the in-view controls.
            if (isPtz) {
                HintTooltip(if (ptzVisible) "Hide PTZ controls" else "Show PTZ controls") {
                    IconButton(onClick = { ptzVisible = !ptzVisible }) {
                        Icon(
                            imageVector = Icons.Default.ControlCamera,
                            contentDescription = if (ptzVisible) "Hide PTZ controls" else "Show PTZ controls",
                            tint = if (ptzVisible) TealAccent else Color.White,
                        )
                    }
                }
            }

            // PTZ presets picker — shown whenever this PTZ camera has saved presets,
            // NOT gated behind the PTZ control overlay, so recalling a saved position
            // is always one tap. Uses a location icon (distinct from the Bookmarks
            // icon, which is the unrelated saved-clip bookmark feature).
            if (isPtz && ptzPresets.isNotEmpty()) {
                Box {
                    HintTooltip("PTZ presets") {
                        IconButton(onClick = { presetsMenuOpen = true }) {
                            Icon(
                                imageVector = Icons.Default.MyLocation,
                                contentDescription = "PTZ presets",
                                tint = Color.White,
                            )
                        }
                    }
                    DropdownMenu(
                        expanded = presetsMenuOpen,
                        onDismissRequest = { presetsMenuOpen = false },
                    ) {
                        ptzPresets.forEach { preset ->
                            DropdownMenuItem(
                                text = { Text(preset.name.ifBlank { preset.token }) },
                                onClick = {
                                    presetsMenuOpen = false
                                    scope.launch { repo.ptzPreset(currentCameraId, preset.token) }
                                },
                            )
                        }
                    }
                }
            }

            // Audio toggle (play-on-focus). Persists the choice.
            HintTooltip(if (audioOn) "Mute audio" else "Play audio") {
                IconButton(
                    onClick = {
                        audioOn = !audioOn
                        store.liveAudioOn = audioOn
                    },
                ) {
                    Icon(
                        imageVector = if (audioOn) Icons.Default.VolumeUp else Icons.Default.VolumeOff,
                        contentDescription = if (audioOn) "Mute audio" else "Play audio",
                        tint = if (audioOn) TealAccent else Color.White,
                    )
                }
            }

            // Home Assistant — the camera's linked entities in an HA-style sheet.
            // Shown only when this camera has links, so a non-HA camera stays clean.
            if (haLinks.isNotEmpty()) {
                HintTooltip("Home Assistant") {
                    IconButton(onClick = { haSheetOpen = true }) {
                        Icon(
                            imageVector = Icons.Default.Home,
                            contentDescription = "Home Assistant entities",
                            tint = Color.White,
                        )
                    }
                }
            }

            // Motion tuner (admin-only, and hideable once cameras are dialled in).
            if (store.isAdmin && store.motionTunerEnabled) {
                HintTooltip("Tune motion detection") {
                    IconButton(onClick = { onTuneMotion(currentCameraId) }) {
                        Icon(
                            imageVector = Icons.Default.Tune,
                            contentDescription = "Tune motion detection",
                            tint = Color.White,
                        )
                    }
                }
            }

            // Playback shortcut — gated on the playback capability (viewers without
            // it see only live; the recorded timeline is not accessible to them).
            if (store.isAdmin || store.capabilities.playback) {
                HintTooltip("Open playback for this camera") {
                    IconButton(
                        onClick = { onOpenPlayback(currentCameraId) },
                    ) {
                        Icon(
                            imageVector = Icons.Default.VideoLibrary,
                            contentDescription = "Open playback",
                            tint = Color.White,
                        )
                    }
                }
            }
        }
        }

        // Home Assistant entity sheet (read-only status). Opens over the video
        // from the HA button; renders in HA's own dark theme so it feels native.
        if (haSheetOpen) {
            HaEntitiesSheet(
                cameraName = cameraNames[currentCameraId] ?: "Camera",
                links = haLinks,
                states = haStates,
                onDismiss = { haSheetOpen = false },
            )
        }

        // Tapping an on-video HA badge opens the same read-only detail dialog the
        // list sheet uses (issue #263).
        haBadgeSelected?.let { link ->
            val st = haStates?.stateFor(link.entityId)
            HaMoreInfoDialog(link, st?.state, st?.lastChanged, onDismiss = { haBadgeSelected = null })
        }

        // ── In-view PTZ controls — wheel (joystick ring) OR edge-pinned arrows ──
        // Shared move/stop/home/zoom handlers; only the on-screen layout differs.
        if (!inPip && isPtz && ptzVisible) {
            val onMove: (Float, Float) -> Unit = { pan, tilt ->
                // Throttle: only send when the velocity changes meaningfully.
                if (kotlin.math.abs(pan - lastPan) > 0.12f || kotlin.math.abs(tilt - lastTilt) > 0.12f) {
                    lastPan = pan; lastTilt = tilt
                    scope.launch { repo.ptzMove(currentCameraId, pan, tilt) }
                }
            }
            val onStop: () -> Unit = { lastPan = 0f; lastTilt = 0f; scope.launch { repo.ptzStop(currentCameraId) } }
            val onHome: () -> Unit = { scope.launch { repo.ptzHome(currentCameraId) } }
            val onZoom: (Float) -> Unit = { z -> scope.launch { repo.ptzMove(currentCameraId, 0f, 0f, z * 0.6f) } }
            val onZoomStop: () -> Unit = { scope.launch { repo.ptzStop(currentCameraId) } }

            if (ptzStyle == "edges") {
                PtzEdgeControls(
                    onMove = onMove, onStop = onStop, onHome = onHome,
                    onZoom = onZoom, onZoomStop = onZoomStop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                PtzWheel(
                    onMove = onMove, onStop = onStop, onHome = onHome,
                    onZoom = onZoom, onZoomStop = onZoomStop,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 28.dp),
                )
            }
        }
    }
}

// ─── reconnect tuning ─────────────────────────────────────────────────────────

/** First backoff delay (ms). Doubles each attempt: 1s, 2s, 4s, 8s … */
private const val BASE_BACKOFF_MS = 1_000L
/** Backoff cap (ms). Steady-state retry cadence once the curve flattens. */
private const val MAX_BACKOFF_MS = 15_000L
/**
 * Max FAST-backoff attempts before surfacing the hard-error message + falling
 * back to [SLOW_RETRY_INTERVAL_MS]. With the curve above, 30 attempts ≈ ~7 min
 * of retrying — past any transient blip. Past this point we no longer stop
 * retrying (#2): the view keeps trying, slowly, indefinitely, so it recovers on
 * its own if the outage ends without the user having to notice and tap Retry.
 */
private const val MAX_RECONNECT_ATTEMPTS = 30

/**
 * Steady-state retry cadence (ms) once [MAX_RECONNECT_ATTEMPTS] is exhausted
 * (#2). Matches the live-wall tile's cadence.
 */
private const val SLOW_RETRY_INTERVAL_MS = 60_000L

/** Stall-watchdog tick (ms). 1s tick + accumulator → ~3s detection. */
private const val WATCHDOG_TICK_MS = 1_000L
/** Playback position unchanged for this long while READY+playWhenReady ⇒ frozen. */
private const val FRAME_STALL_MS = 4_000L
/** READY must hold this long with frames flowing before the backoff resets (A3). */
private const val READY_SUSTAINED_MS = 30_000L
/** Stuck-BUFFERING limit (ms) before forcing a reconnect — the spinner-forever cap. */
private const val STALL_BUFFERING_MS = 15_000L
/**
 * Shorter buffering limit (ms) applied ONLY to a main stream that has never
 * reached READY and has a sub stream to fall back to. An H265 main the RTSP path
 * can't decode may sit in BUFFERING rather than erroring; this bounds how long
 * the HD attempt spins before downgrading to the (H264) sub stream.
 */
private const val MAIN_FIRSTLOAD_BUFFER_MS = 6_000L

/**
 * If the fullscreen view was stopped (ON_STOP) longer than this, ON_START (#11)
 * re-prepares a fresh RTSP source instead of just calling play() on the same
 * (still-alive, PiP-preserved) player — a feed idle this long has almost
 * certainly dropped, and play() would just resume rendering the frozen last
 * frame for several seconds before the stall watchdog eventually caught up.
 * Matches [LiveRtspContent]'s tile-side constant of the same name/value.
 */
private const val LIVE_RECONNECT_AFTER_BG_MS = 20_000L
