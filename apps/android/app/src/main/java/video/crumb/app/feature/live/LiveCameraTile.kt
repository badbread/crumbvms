// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import android.graphics.drawable.BitmapDrawable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.SignalWifiStatusbarConnectedNoInternet4
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.imageLoader
import coil.request.CachePolicy
import coil.request.ImageRequest
import coil.request.SuccessResult
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import video.crumb.app.data.CameraDto
import video.crumb.app.data.DetectionIcons
import video.crumb.app.data.LiveStreamsResponse
import video.crumb.app.data.MediaUrls
import video.crumb.app.ui.player.MediaFactory
import video.crumb.app.ui.player.PlayerSurface
import video.crumb.app.ui.theme.DangerRed
import video.crumb.app.ui.theme.TealAccent
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * A single camera tile for the live wall grid.
 *
 * Playback notes:
 * - Uses rtspSubUrl when available (low-res, conserves bandwidth in grid view),
 *   otherwise falls back to rtspMainUrl.
 * - The [LiveStreamsResponse] is pre-resolved by [LiveViewModel] so this
 *   composable never performs network I/O.
 * - The ExoPlayer is built once in [remember], starts playing immediately, and
 *   is released in a [DisposableEffect]. Lifecycle-aware: pauses when the
 *   screen is backgrounded and resumes on return.
 *
 * Low-bandwidth mode:
 * - When [lowBandwidthMode] is true, the ExoPlayer is NOT created and the tile
 *   instead uses [SnapshotPollingTile] — an independent JPEG GET on an adaptive
 *   timer (~1 fps, backing off toward 3–5 s on slow/failing responses). Each GET
 *   is independent (not MJPEG) so a single stale/failed frame never wedges the
 *   tile; the next tick always retries.
 *
 * @param camera Camera metadata for label rendering.
 * @param streams Pre-resolved RTSP endpoints for this camera, or null if
 *   resolution failed (shows an error badge immediately in that case).
 * @param onClick Callback for the "open fullscreen" tap on the video area.
 * @param mediaUrls Builder for this camera's still-frame URL (`/cameras/{id}/frame.jpg`),
 *   used for the snapshot placeholder (normal mode) and for the polling tile
 *   (low-bandwidth mode). Each fetch/poll tick resolves a fresh scoped-token URL
 *   through this rather than a URL built once up front, since the polling tile's
 *   loop can run far longer than one ~15 min scoped token's lifetime.
 * @param lowBandwidthMode When true, skip RTSP and poll still frames instead.
 * @param onStall Called when the tile's RTSP watchdog detects a stall event —
 *   forwarded to [LiveViewModel.reportTileStall] for auto-fallback accounting.
 */
@OptIn(UnstableApi::class)
@Composable
fun LiveCameraTile(
    camera: CameraDto,
    streams: LiveStreamsResponse?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    mediaUrls: MediaUrls? = null,
    motion: Boolean = false,
    /** True when the camera is actually recording now (drives the red REC dot).
     *  Motion-mode cameras are live but only record while motion fires, so a quiet
     *  motion camera shows no dot. */
    recording: Boolean = false,
    /** Frigate object types currently detected on this camera (icon_keys, e.g.
     *  "person"/"vehicle"/"animal"). When non-empty, the color-coded object icons
     *  replace the generic red motion runner. */
    detections: List<String> = emptyList(),
    /** When true the tile renders via snapshot polling instead of RTSP. */
    lowBandwidthMode: Boolean = false,
    /** Called when the stall watchdog fires; forwarded to the VM for auto-fallback. */
    onStall: () -> Unit = {},
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(Color.Black)
            .clickable(onClick = onClick),
    ) {
        if (lowBandwidthMode) {
            // ── Snapshot-polling path ────────────────────────────────────────────
            // Independent JPEG GETs on an adaptive interval. No RTSP connection,
            // no ExoPlayer, no buffering — just a new still every tick. A single
            // failed frame just shows the last good one; the next tick retries.
            if (mediaUrls != null) {
                SnapshotPollingTile(
                    mediaUrls = mediaUrls,
                    cameraId = camera.id,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                // No frame URL available in low-bw mode → show a static error badge.
                TileErrorOverlay(
                    modifier = Modifier.align(Alignment.Center),
                    noUrl = true,
                )
            }
        } else {
            // ── Normal RTSP path ─────────────────────────────────────────────────
            LiveRtspContent(
                camera = camera,
                streams = streams,
                mediaUrls = mediaUrls,
                onStall = onStall,
            )
        }

        // ── Overlays common to both paths ─────────────────────────────────────

        // Low-bandwidth mode indicator (bottom-center, subtle) so the user
        // always knows which render path is active.
        if (lowBandwidthMode && mediaUrls != null) {
            Icon(
                imageVector = Icons.Default.SignalWifiStatusbarConnectedNoInternet4,
                contentDescription = "Low-bandwidth mode",
                tint = TealAccent.copy(alpha = 0.75f),
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 6.dp)
                    .size(14.dp),
            )
        }

        // REC indicator dot (top-right): red only when actually recording. A live
        // motion-mode camera with no current motion is NOT recording → no dot.
        if (recording) {
            LiveIndicator(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp),
            )
        }

        // Detection / motion badge (top-left). Frigate's classified object icons
        // (person/vehicle/animal/…, color-coded) take precedence over the generic
        // red motion runner — the runner shows only when there's motion but no
        // classified object.
        if (detections.isNotEmpty() || motion) {
            Row(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(6.dp)
                    .background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 4.dp, vertical = 3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                if (detections.isNotEmpty()) {
                    detections.forEach { key ->
                        Icon(
                            imageVector = detectionIconFor(key),
                            contentDescription = "Detected: $key",
                            tint = detectionColorFor(key),
                            modifier = Modifier.size(17.dp),
                        )
                    }
                } else {
                    // Generic, unclassified motion → a non-human "motion sensor"
                    // glyph (radiating waves), distinct from the person icon so the
                    // two never read as the same thing.
                    Icon(
                        imageVector = Icons.Default.Sensors,
                        contentDescription = "Motion (unclassified)",
                        tint = DangerRed,
                        modifier = Modifier.size(17.dp),
                    )
                }
            }
        }

        // Camera name label (bottom-left).
        Text(
            text = camera.name,
            style = MaterialTheme.typography.labelSmall,
            color = Color.White,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(start = 6.dp, bottom = 6.dp, end = 32.dp)
                .background(
                    color = Color.Black.copy(alpha = 0.55f),
                    shape = RoundedCornerShape(4.dp),
                )
                .padding(horizontal = 4.dp, vertical = 2.dp),
        )
        // (Per-tile playback shortcut removed — playback is reached via the
        // Playback tab. Tapping a tile opens fullscreen live.)
    }
}

// ─── RTSP live video path ─────────────────────────────────────────────────────

/**
 * The normal ExoPlayer/RTSP render path for a single live camera tile.
 *
 * Extracted into its own composable so that [LiveCameraTile] can completely
 * skip all ExoPlayer machinery when [LiveCameraTile.lowBandwidthMode] is true —
 * no player is built, no watchdog coroutines are launched.
 *
 * Contains the full reconnect + stall watchdog logic. Each stall event is
 * reported upward via [onStall] so the wall can auto-fallback.
 */
@OptIn(UnstableApi::class)
@Composable
private fun LiveRtspContent(
    camera: CameraDto,
    streams: LiveStreamsResponse?,
    mediaUrls: MediaUrls?,
    onStall: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    // #135: registry of every coroutine job that reads or re-prepares `player`
    // (reconnect, connectivity-regained re-prepare, resume re-prepare, stall
    // watchdog). ON_STOP cancels them ALL synchronously BEFORE player.release(),
    // closing the race where a pending re-prepare calls setMediaSource/prepare on
    // an already-released player — which throws IllegalStateException and can
    // leave the tile permanently black. Everything here runs on `scope` (the
    // composition's Main dispatcher), so the list is only ever touched on the main
    // thread and needs no synchronization. Completed jobs are pruned on insert so
    // it can't grow unbounded over a long-lived tile's many reconnects.
    val playerOpsJobs = remember { mutableListOf<Job>() }
    fun trackPlayerJob(job: Job) {
        playerOpsJobs.removeAll { it.isCompleted }
        playerOpsJobs.add(job)
    }

    // Tile-level state driven by Player.Listener callbacks.
    var isBuffering by remember { mutableStateOf(true) }
    // Hard error: only set after auto-reconnect exhausts its FAST attempts. Shows
    // the "Stream error" overlay. This is no longer a dead end (#2 below) — the
    // overlay is tappable to retry immediately, and a SLOW background cadence
    // keeps trying on its own even if the user never taps.
    var hasError by remember { mutableStateOf(false) }
    // Soft reconnect state: while an exponential-backoff re-prepare is pending,
    // we show a subtle "Reconnecting…" badge instead of the hard error.
    var isReconnecting by remember { mutableStateOf(false) }

    // Choose sub stream for grid; fall back to main.
    val rtspUrl: String? = remember(streams) {
        streams?.rtspSubUrl ?: streams?.rtspMainUrl
    }

    // Device connectivity (#3). While offline, reconnect attempts PAUSE instead of
    // burning the fast-attempt budget against a link that can't reach the server
    // at all — without this, a device that loses Wi-Fi for a few minutes exhausts
    // MAX_RECONNECT_ATTEMPTS on doomed re-prepares and lands in the hard-error
    // state the moment connectivity returns, instead of already reconnecting.
    val isOnline by rememberIsOnline()

    // True once the live surface has painted its FIRST frame (onRenderedFirstFrame).
    // Drives the snapshot-placeholder cross-fade. Latches for the lifetime of this
    // player (keyed on rtspUrl) — we don't re-show the snapshot on reconnect (the
    // frozen last frame is more current than a stale still).
    var firstFrameSeen by remember(rtspUrl) { mutableStateOf(false) }

    // Capture onStall in state so the watchdog closure always sees the latest.
    val onStallState = rememberUpdatedState(onStall)

    // Bumped to force a fresh `remember(rtspUrl, playerGeneration)` player instance
    // without changing rtspUrl itself. Used for tap-to-retry (#2): bumping it
    // rebuilds the player from scratch (fresh `attempt` counter) instead of
    // waiting out the rest of the slow retry cadence.
    var playerGeneration by remember(rtspUrl) { mutableStateOf(0) }

    // Release-on-background (#9): while true, `player` below is null and the
    // MediaCodec decoder is NOT allocated. Set on ON_STOP, cleared on ON_START —
    // see the lifecycle DisposableEffect further down. Gating the `remember` key
    // (rather than eagerly rebuilding the instant ON_STOP fires, which would just
    // reconnect immediately and defeat the point) means the tile genuinely holds
    // no decoder for the entire time it's backgrounded, only reallocating one when
    // the lifecycle is actually back at STARTED.
    var tileReleased by remember(rtspUrl) { mutableStateOf(false) }

    // Build player once per (rtspUrl, playerGeneration, tileReleased); release on
    // disposal (and explicitly on ON_STOP — see below).
    val player = remember(rtspUrl, playerGeneration, tileReleased) {
        if (rtspUrl == null || tileReleased) return@remember null
        // Low-latency live profile (thin buffers) — NOT newPlayer's default 50 s
        // buffer / ~2.5 s time-to-first-frame. Cuts wall TTFF to ~0.1 s and the
        // per-tile RTSP buffer ~100×. (Fullscreen already uses this profile.)
        MediaFactory.newLivePlayer(context).also { exo ->
            val source = MediaFactory.rtspSource(rtspUrl)
            exo.setMediaSource(source)
            exo.prepare()
            exo.playWhenReady = true
            // Grid tiles are always muted — audio plays only on the focused
            // (fullscreen) camera. Avoids a wall of overlapping audio tracks.
            exo.volume = 0f
        }
    }

    // Attach a listener that updates buffering/error state and drives automatic
    // reconnect with exponential backoff. RTSP live streams drop on the slightest
    // network hiccup (camera reboot, AP roam, brief Wi-Fi loss); for a 24/7 wall
    // we must recover silently instead of stranding the tile on a manual Retry.
    //
    // CRITICAL: on error we re-PREPARE (setMediaSource + prepare), never seek.
    // RTSP live is not seekable — a seek sticks the player in STATE_BUFFERING.
    DisposableEffect(player) {
        // Backoff bookkeeping. `attempt` is captured by the listener closure.
        var attempt = 0
        var reconnectJob: Job? = null

        fun scheduleReconnect() {
            if (player == null || rtspUrl == null) return
            if (reconnectJob?.isActive == true) return // one in flight already
            // Offline: don't burn the attempt budget on a doomed re-prepare. Park
            // in the reconnecting state (not hard error) — connectivity regained
            // triggers an immediate reset + retry via the DisposableEffect below.
            if (!isOnline) {
                isReconnecting = true
                hasError = false
                return
            }
            // Past the fast-backoff budget: DON'T stop forever (#2) — fall back to
            // a slow, indefinite retry cadence so the tile keeps quietly trying to
            // recover on its own even if nobody taps the error overlay.
            val delayMs = if (attempt >= MAX_RECONNECT_ATTEMPTS) {
                SLOW_RETRY_INTERVAL_MS
            } else {
                // 1s, 2s, 4s, 8s … capped at MAX_BACKOFF_MS (~15s).
                (BASE_BACKOFF_MS shl attempt).coerceAtMost(MAX_BACKOFF_MS)
            }
            attempt += 1
            isReconnecting = attempt < MAX_RECONNECT_ATTEMPTS
            // Surface the hard-error overlay once the fast budget is exhausted, but
            // keep retrying underneath at the slow cadence (attempt keeps climbing
            // past MAX_RECONNECT_ATTEMPTS so we stay on SLOW_RETRY_INTERVAL_MS).
            hasError = attempt >= MAX_RECONNECT_ATTEMPTS
            reconnectJob = scope.launch {
                delay(delayMs)
                // Re-prepare from scratch with a fresh media source. Do NOT seek.
                val source = MediaFactory.rtspSource(rtspUrl)
                player.setMediaSource(source)
                player.prepare()
                player.playWhenReady = true
            }.also { trackPlayerJob(it) } // #135: cancellable on ON_STOP
        }

        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        isBuffering = true
                        hasError = false
                    }
                    Player.STATE_READY -> {
                        // Recovered for now — clear error/reconnect UI. Do NOT reset
                        // the backoff here: a camera that renders one frame then drops
                        // every few seconds would reset to 1s forever and thrash
                        // without ever escalating to the hard-error/Retry fallback.
                        // The watchdog resets `attempt` only after READY holds a
                        // SUSTAINED period (review A3).
                        isBuffering = false
                        hasError = false
                        isReconnecting = false
                    }
                    Player.STATE_ENDED -> {
                        isBuffering = false
                    }
                    Player.STATE_IDLE -> {
                        // Idle after an error — handled by onPlayerError.
                    }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                isBuffering = false
                // Don't go straight to the hard error; try to reconnect first.
                scheduleReconnect()
            }

            override fun onRenderedFirstFrame() {
                // Live video has painted — cross-fade the snapshot placeholder out.
                firstFrameSeen = true
            }
        }
        player?.addListener(listener)

        // ── Stall watchdog ──────────────────────────────────────────────────────
        // RTSP-over-TCP can stall in ways that NEVER fire onPlayerError, so the
        // error-only reconnect above can't see them and the tile freezes forever:
        //   (a) frozen frame — STATE_READY but currentPosition stops advancing
        //       (camera encoder hang, AP roam, RTP flow stops, TCP still open);
        //   (b) stuck buffering — STATE_BUFFERING that never reaches READY. This is
        //       the root of bug #38 (a PTZ direct-cam sub that never produces a
        //       frame spins the spinner forever).
        // Sample progress on the main thread (ExoPlayer is single-threaded) and force
        // a reconnect on a stall. Each detected stall also reports upward so the
        // wall's auto-fallback accounting can trip low-bw mode for bad links.
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
                        // Detect a frozen feed off the PLAYBACK POSITION: a wedged
                        // stream (encoder hang, AP roam, RTP stops, TCP still open)
                        // stops the position advancing while STATE_READY. A HEALTHY
                        // stream advances position every tick, so this never fires —
                        // unlike the frame-callback approach, which proved unreliable
                        // on the grid tiles and falsely tripped low-bw mode. Gate on
                        // playWhenReady, not isPlaying (which flaps on internal pauses).
                        if (p.playWhenReady) {
                            val pos = p.currentPosition
                            if (pos == lastPos) {
                                stuckMs += WATCHDOG_TICK_MS
                                if (stuckMs >= FRAME_STALL_MS) {
                                    stuckMs = 0L; lastPos = -1L; readyHeldMs = 0L
                                    onStallState.value()   // report to VM for auto-fallback
                                    scheduleReconnect()
                                }
                            } else {
                                lastPos = pos
                                stuckMs = 0L
                                // Reset backoff only after READY holds a SUSTAINED
                                // stretch, so a flapping camera keeps escalating (A3).
                                readyHeldMs += WATCHDOG_TICK_MS
                                if (readyHeldMs >= READY_SUSTAINED_MS && attempt != 0) attempt = 0
                            }
                        } else {
                            lastPos = -1L; stuckMs = 0L; readyHeldMs = 0L
                        }
                    }
                    Player.STATE_BUFFERING -> {
                        lastPos = -1L; stuckMs = 0L; readyHeldMs = 0L
                        bufferingMs += WATCHDOG_TICK_MS
                        if (bufferingMs >= STALL_BUFFERING_MS) {
                            bufferingMs = 0L
                            onStallState.value()       // report to VM for auto-fallback
                            scheduleReconnect()
                        }
                    }
                    else -> {
                        bufferingMs = 0L; lastPos = -1L; stuckMs = 0L; readyHeldMs = 0L
                    }
                }
            }
        }

        // #135: also track the watchdog so ON_STOP cancels it before release —
        // otherwise it can read a released player or fire scheduleReconnect against
        // one in the window before recomposition disposes this effect.
        trackPlayerJob(watchdogJob)

        onDispose {
            watchdogJob.cancel()
            reconnectJob?.cancel()
            player?.removeListener(listener)
        }
    }

    // Connectivity regained (#3): scheduleReconnect() parks itself (isReconnecting,
    // no job) while offline instead of consuming the attempt budget. The moment
    // isOnline flips back to true, kick a FRESH reconnect attempt with a little
    // jitter (mirrors the resume-jitter below) so N tiles coming back online at
    // once don't all re-prepare in the same tick. This effect only fires on the
    // true→true transition being irrelevant — remember() re-runs on every isOnline
    // change, but we only act when we're actually parked in a reconnecting state.
    DisposableEffect(isOnline, player) {
        var job: Job? = null
        if (isOnline && isReconnecting && player != null && rtspUrl != null) {
            job = scope.launch {
                delay(kotlin.random.Random.nextLong(0L, 1_500L))
                val source = MediaFactory.rtspSource(rtspUrl)
                player.setMediaSource(source)
                player.prepare()
                player.playWhenReady = true
            }.also { trackPlayerJob(it) } // #135
        }
        onDispose { job?.cancel() }
    }

    // Lifecycle-aware pause/resume + release-on-stop (#9). Live RTSP can't *resume*
    // a connection that died while the app was backgrounded — player.play() would
    // just sit on the last decoded frame (e.g. open the app in the morning and
    // every tile shows last night's frozen frame under a live detection icon).
    //
    // ON_PAUSE/ON_RESUME (brief backgrounding, e.g. a quick app-switch or another
    // app's permission dialog): pause/resume the SAME player instance, re-preparing
    // only if the pause outlasted LIVE_RECONNECT_AFTER_BG_MS. ExoPlayer fires
    // ON_PAUSE before ON_STOP, so `player?.pause()` here is harmless even when
    // ON_STOP is about to release the same instance a moment later.
    //
    // ON_STOP (fully backgrounded — home button, screen off, switched apps for a
    // while): actually RELEASE the player so its MediaCodec decoder is freed. A
    // 4x4 wall held 16 decoder instances allocated for the entire time the app sat
    // in the background; releasing here is the fix. Setting `tileReleased = true`
    // changes the `remember` key above so `player` becomes null — no decoder is
    // held while backgrounded, full stop (not "released then eagerly rebuilt").
    //
    // ON_START (returning to foreground): clear `tileReleased`, which reruns the
    // `remember` above and builds a BRAND NEW player (fresh RTSP handshake,
    // `playWhenReady = true` in the builder) — there both is nothing to "resume"
    // (the old instance is gone) and no reason to: a released tile has been
    // backgrounded at least long enough to stop, well past LIVE_RECONNECT_AFTER_BG_MS,
    // so a fresh prepare is exactly what ON_RESUME's bgMs branch would have done
    // anyway. Only the TILE player is released this way — the fullscreen player
    // deliberately stays alive across ON_STOP for PiP (see LiveFullscreenScreen).
    DisposableEffect(lifecycleOwner, player) {
        var pausedAt = 0L
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> {
                    pausedAt = System.currentTimeMillis()
                    player?.pause()
                }
                Lifecycle.Event.ON_RESUME -> {
                    val p = player
                    val url = rtspUrl
                    val bgMs = if (pausedAt > 0L) System.currentTimeMillis() - pausedAt else 0L
                    if (p != null && url != null && bgMs > LIVE_RECONNECT_AFTER_BG_MS) {
                        // Stagger the wall-wide re-prepare with a little per-tile jitter
                        // so N tiles don't fire N RTSP handshakes + decoder reallocs in
                        // lockstep on resume (review C2).
                        scope.launch {
                            delay(kotlin.random.Random.nextLong(0L, 1_500L))
                            val source = MediaFactory.rtspSource(url)
                            p.setMediaSource(source)
                            p.prepare()
                            p.playWhenReady = true
                        }.also { trackPlayerJob(it) } // #135
                    } else {
                        p?.play()
                    }
                }
                Lifecycle.Event.ON_STOP -> {
                    // #135: cancel every pending player-touching job FIRST, so none
                    // of them can call setMediaSource/prepare (or read state) on the
                    // instance we're about to release — that race threw
                    // IllegalStateException / left a permanently black tile on a fast
                    // home-button. Only THEN release the decoder and mark released.
                    playerOpsJobs.forEach { it.cancel() }
                    playerOpsJobs.clear()
                    // Fully backgrounded: release the decoder now rather than holding
                    // it for an unbounded background stint.
                    player?.release()
                    tileReleased = true
                }
                Lifecycle.Event.ON_START -> {
                    // Only act when returning from a real ON_STOP release (guard so the
                    // initial LifecycleRegistry ON_START replay on first composition
                    // doesn't needlessly rebuild the just-built player). Clearing
                    // `tileReleased` flips the `remember` key above and builds a BRAND
                    // NEW player (playWhenReady = true is set inside that builder) —
                    // that, not anything in ON_RESUME, is what restarts playback. The
                    // generation bump guarantees a fresh player instance so that even
                    // if some stale job escaped the ON_STOP cancellation above, it can
                    // only ever touch the OLD (released) instance, never the new live
                    // one (#135). ON_RESUME fires right after this with `player` still
                    // closed-over as null (recomposition hasn't run yet), so its branch
                    // is a harmless no-op for this path.
                    if (tileReleased) {
                        playerGeneration += 1
                        tileReleased = false
                    }
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            // Not a double-release in the common tear-down case: this fires when
            // the tile itself is leaving composition (camera removed from the
            // wall, wall torn down), releasing whatever `player` currently is.
            // The ON_STOP branch above already nulled `player` out via
            // tileReleased before this key could still reference it, so the two
            // paths don't double-release the same instance in practice; if they
            // ever did, ExoPlayer.release() is a safe no-op on a second call.
            player?.release()
        }
    }

    // All rendering for the RTSP path lives inside a Box so overlays can use
    // Alignment.Center without requiring a BoxScope receiver from the caller.
    Box(modifier = Modifier.fillMaxSize()) {
        // Video surface (only when player is available and healthy).
        // FIT (letterbox), not ZOOM: the grid uses a SurfaceView for performance,
        // and SurfaceViews don't clip to their parent bounds — so ZOOM (fill+crop)
        // scales an ultrawide camera (e.g. Front Yard, 2.67:1) up until it spills
        // into the neighbouring tile. FIT keeps the whole frame inside the tile.
        // 16:9 cameras look identical either way (they already fill a 16:9 tile).
        if (player != null && !hasError) {
            PlayerSurface(
                player = player,
                modifier = Modifier.fillMaxSize(),
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT,
            )
        }

        // Snapshot placeholder — a recent still drawn OVER the (black-shuttered)
        // video surface the instant the tile appears, then cross-faded out the moment
        // the live feed paints its first frame. The grid uses a SurfaceView (black
        // shutter until first frame), so this MUST overlay in front; once it fades to
        // alpha 0 it stops compositing and the live surface shows through.
        if (mediaUrls != null && !hasError && rtspUrl != null) {
            TileSnapshotOverlay(
                mediaUrls = mediaUrls,
                fadeOut = firstFrameSeen,
                cameraId = camera.id,
                modifier = Modifier.fillMaxSize(),
            )
        }

        // Buffering spinner — shown until first frame, then hidden. Suppressed
        // while a reconnect is pending (the "Reconnecting…" badge covers that), and
        // while the snapshot placeholder is still covering the tile (the still already
        // signals the tile is alive — a spinner on top of it reads as a stall).
        if (isBuffering && !hasError && !isReconnecting && rtspUrl != null &&
            !(mediaUrls != null && !firstFrameSeen)
        ) {
            CircularProgressIndicator(
                modifier = Modifier.align(Alignment.Center),
                color = TealAccent,
                strokeWidth = 2.dp,
            )
        }

        // Subtle reconnecting state — distinct from the hard error overlay. The
        // last frame stays visible underneath; we just overlay a small badge.
        if (isReconnecting && !hasError && rtspUrl != null) {
            TileReconnectingOverlay(modifier = Modifier.align(Alignment.Center))
        }

        // Hard error state — no stream URL, or reconnect exhausted its FAST
        // attempts (a slow background retry keeps trying regardless — see
        // scheduleReconnect above). Tap-to-retry (#2): bumping playerGeneration
        // rebuilds the player from scratch, which resets the backoff `attempt`
        // counter to 0 (a fresh closure) and immediately re-prepares, rather than
        // waiting out the remainder of the slow cadence.
        if (hasError || rtspUrl == null) {
            TileErrorOverlay(
                modifier = Modifier.align(Alignment.Center),
                noUrl = rtspUrl == null,
                onRetry = if (rtspUrl != null) {
                    { playerGeneration += 1 }
                } else null,
            )
        }
    }
}

// ─── reconnect tuning ─────────────────────────────────────────────────────────

/** First backoff delay (ms). Doubles each attempt: 1s, 2s, 4s, 8s … */
private const val BASE_BACKOFF_MS = 1_000L
/** Backoff cap (ms). Steady-state retry cadence once the curve flattens. */
private const val MAX_BACKOFF_MS = 15_000L
/**
 * Max FAST-backoff attempts before surfacing the hard-error overlay + falling
 * back to [SLOW_RETRY_INTERVAL_MS]. With the curve above, 30 attempts ≈ ~7 min
 * of retrying (a few seconds of ramp, then ~15s steady) — well past any
 * transient blip. Past this point we no longer stop retrying (#2) — a
 * permanently-dead camera doesn't spin a TIGHT coroutine forever, but it does
 * keep trying, slowly, indefinitely, so it recovers on its own if the outage
 * ever ends without requiring the user to notice and tap Retry.
 */
private const val MAX_RECONNECT_ATTEMPTS = 30

/**
 * Steady-state retry cadence (ms) once [MAX_RECONNECT_ATTEMPTS] is exhausted
 * (#2). Slow enough not to hammer a camera/network that's genuinely down for
 * an extended outage (~7+ minutes already elapsed by this point), frequent
 * enough that the tile is back on its own within a minute of the outage
 * actually clearing.
 */
private const val SLOW_RETRY_INTERVAL_MS = 60_000L

/** Stall-watchdog tick (ms). 1s tick + the accumulator below gives ~3s detection. */
private const val WATCHDOG_TICK_MS = 1_000L
/** Playback position unchanged for this long while READY+playWhenReady ⇒ frozen. */
private const val FRAME_STALL_MS = 4_000L
/** READY must hold this long with frames flowing before the backoff resets (A3). */
private const val READY_SUSTAINED_MS = 30_000L
/** Stuck-BUFFERING limit (ms) before forcing a reconnect — the bug #38 spinner cap. */
private const val STALL_BUFFERING_MS = 15_000L

/**
 * If the app was backgrounded longer than this, re-prepare the RTSP source on
 * resume instead of resuming it — a live feed that's been idle this long has
 * almost certainly dropped, and resuming would show a frozen last frame. Short
 * enough to catch an overnight gap; long enough that a quick app-switch just
 * resumes without a reconnect flash.
 */
private const val LIVE_RECONNECT_AFTER_BG_MS = 20_000L

// ─── snapshot-polling tile ────────────────────────────────────────────────────

/**
 * Low-bandwidth tile: polls `GET /cameras/{id}/frame.jpg` on an adaptive
 * interval, displaying the latest JPEG still. Each request is independent —
 * NOT a persistent MJPEG connection — so a single stale/failed frame never
 * wedges the tile.
 *
 * Adaptive interval:
 * - Target: 1 fps ([POLL_INTERVAL_FAST_MS] = 1 000 ms).
 * - Backoff: each consecutive failure or slow response adds [POLL_BACKOFF_STEP_MS]
 *   up to [POLL_INTERVAL_SLOW_MS] = 5 000 ms. Success resets to the fast interval.
 *
 * Cache is disabled on every request (cache-busted via `&cb=<counter>`) so Coil
 * always fetches a fresh frame and the displayed still actually advances. The
 * URL itself is rebuilt from [mediaUrls] on EVERY tick (not once up front) —
 * this loop can run for hours, far longer than a scoped media token's ~15 min
 * lifetime, so each tick needs its own fresh (cached-until-near-expiry) token.
 *
 * @param mediaUrls Builder for the still-frame URL, backed by the per-camera
 *   scoped-token cache (see [video.crumb.app.data.MediaTokenCache]).
 * @param cameraId Stable key for [remember] — ensures the counter resets when
 *   the composable is reused for a different camera.
 */
@Composable
private fun SnapshotPollingTile(
    mediaUrls: MediaUrls,
    cameraId: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // Displayed frame — null until the first successful fetch (shows black/nothing).
    var frame by remember(cameraId) { mutableStateOf<ImageBitmap?>(null) }
    // Whether the most recent fetch attempt failed (show a subtle "no signal" tint).
    var lastFetchFailed by remember(cameraId) { mutableStateOf(false) }

    // (#8) Gate the poll loop on STARTED so a backgrounded wall stops fetching
    // ~1 JPEG/s/tile instead of burning bandwidth/battery for every low-bw tile
    // the whole time the app sits in the background. repeatOnLifecycle suspends
    // the block (cancelling the in-flight loop) below STARTED and restarts it
    // fresh from the top when the lifecycle re-enters STARTED — matching the
    // gating already used for the fullscreen motion-status poll.
    LaunchedEffect(cameraId) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val loader = context.imageLoader
            var counter = 0
            var consecutiveFailures = 0

            while (true) {
                // Adaptive interval: fast when recovering, slow when failing.
                val intervalMs = (POLL_INTERVAL_FAST_MS + consecutiveFailures * POLL_BACKOFF_STEP_MS)
                    .coerceAtMost(POLL_INTERVAL_SLOW_MS)
                delay(intervalMs)

                counter++
                // Fresh (cache-hit unless near-expiry) scoped-token URL every tick,
                // then cache-bust with `&cb=<counter>` so Coil always fetches from
                // the network rather than returning a cached (stale) bitmap.
                val frameUrl = runCatching { mediaUrls.cameraFrameUrl(cameraId) }.getOrNull()
                if (frameUrl == null) {
                    lastFetchFailed = true
                    consecutiveFailures = (consecutiveFailures + 1).coerceAtMost(POLL_MAX_BACKOFF_STEPS)
                    continue
                }
                val sep = if (frameUrl.contains('?')) '&' else '?'
                val url = "$frameUrl${sep}cb=$counter"

                val fetchStart = System.currentTimeMillis()
                val req = ImageRequest.Builder(context)
                    .data(url)
                    .memoryCachePolicy(CachePolicy.DISABLED)
                    .diskCachePolicy(CachePolicy.DISABLED)
                    .allowHardware(false)
                    .build()
                val result = loader.execute(req)
                val fetchMs = System.currentTimeMillis() - fetchStart

                if (result is SuccessResult) {
                    val bmp = (result.drawable as? BitmapDrawable)?.bitmap?.asImageBitmap()
                    if (bmp != null) {
                        frame = bmp
                        lastFetchFailed = false
                        consecutiveFailures = 0
                        // If the fetch was slow (slow link), backoff slightly even on
                        // success so we don't hammer a sluggish server.
                        if (fetchMs > POLL_SLOW_FETCH_MS) {
                            consecutiveFailures = (consecutiveFailures + 1)
                                .coerceAtMost(POLL_MAX_BACKOFF_STEPS)
                        }
                    } else {
                        lastFetchFailed = true
                        consecutiveFailures = (consecutiveFailures + 1).coerceAtMost(POLL_MAX_BACKOFF_STEPS)
                    }
                } else {
                    lastFetchFailed = true
                    consecutiveFailures = (consecutiveFailures + 1).coerceAtMost(POLL_MAX_BACKOFF_STEPS)
                }
            }
        }
    }

    val f = frame
    if (f != null) {
        Image(
            bitmap = f,
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = modifier.graphicsLayer {
                // Subtle dimming while last fetch failed — signals the image
                // is stale without blocking the view entirely.
                alpha = if (lastFetchFailed) 0.65f else 1f
            },
        )
    }
    // While frame == null (first fetch in flight) the tile shows the black
    // background from the outer Box — same as normal cold-start behaviour.
}

// Polling interval constants.

/** Target poll interval when frames are arriving quickly (ms). */
private const val POLL_INTERVAL_FAST_MS = 1_000L
/** Maximum poll interval when frames are slow/failing (ms). */
private const val POLL_INTERVAL_SLOW_MS = 5_000L
/** Per-consecutive-failure backoff step (ms). */
private const val POLL_BACKOFF_STEP_MS = 500L
/** Cap on consecutive-failure counter (limits how slow the interval can get). */
private const val POLL_MAX_BACKOFF_STEPS = 8
/** A fetch taking longer than this is treated as a "slow" fetch (ms). */
private const val POLL_SLOW_FETCH_MS = 800L

// ─── small private helpers ────────────────────────────────────────────────────

/**
 * A recent still-frame placeholder drawn over a live tile until the live feed
 * paints its first frame, then cross-faded out. Loaded once via Coil (caching
 * disabled so it's a fresh capture, with a few retries for a transient first-fetch
 * miss). If [fadeOut] is already true the placeholder is skipped/dropped — no point
 * fetching a still we're about to hide. Renders nothing if the frame never loads
 * (graceful: the tile just shows the normal black shutter → video).
 */
@Composable
private fun TileSnapshotOverlay(
    mediaUrls: MediaUrls,
    fadeOut: Boolean,
    cameraId: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var frame by remember(cameraId) { mutableStateOf<ImageBitmap?>(null) }
    // Latest fadeOut readable inside the (cameraId-keyed) load loop.
    val fadeOutState = rememberUpdatedState(fadeOut)

    LaunchedEffect(cameraId) {
        // Short bounded retry (≤4 attempts, ~1.2s apart) — well inside one scoped
        // token's lifetime, so resolving the URL once here (rather than per
        // attempt) is fine.
        val frameUrl = runCatching { mediaUrls.cameraFrameUrl(cameraId) }.getOrNull()
        if (frameUrl.isNullOrEmpty()) return@LaunchedEffect
        val loader = context.imageLoader
        var attempt = 0
        while (frame == null && attempt < 4 && !fadeOutState.value) {
            val req = ImageRequest.Builder(context)
                .data(if (attempt == 0) frameUrl else "$frameUrl&cb=$attempt")
                .memoryCachePolicy(CachePolicy.DISABLED)
                .diskCachePolicy(CachePolicy.DISABLED)
                .allowHardware(false)
                .build()
            val result = loader.execute(req)
            if (result is SuccessResult) {
                (result.drawable as? BitmapDrawable)?.bitmap?.let { frame = it.asImageBitmap() }
            }
            attempt++
            if (frame == null && !fadeOutState.value) delay(1200L)
        }
    }

    val alpha by animateFloatAsState(
        targetValue = if (fadeOut) 0f else 1f,
        animationSpec = tween(durationMillis = 280),
        label = "tileSnapshotFade",
    )
    // Once fully faded, stop compositing so the SurfaceView shows live video unobscured.
    if (fadeOut && alpha <= 0.02f) return
    val f = frame ?: return
    Image(
        bitmap = f,
        contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = modifier.graphicsLayer { this.alpha = alpha },
    )
}

@Composable
private fun TileReconnectingOverlay(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(
                color = Color.Black.copy(alpha = 0.55f),
                shape = RoundedCornerShape(6.dp),
            )
            .padding(horizontal = 8.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(12.dp),
                color = TealAccent,
                strokeWidth = 2.dp,
            )
            Text(
                text = "Reconnecting…",
                style = MaterialTheme.typography.labelSmall,
                color = Color.White,
            )
        }
    }
}

@Composable
private fun LiveIndicator(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(8.dp)
            .background(color = DangerRed, shape = CircleShape),
    )
}

/**
 * The tile's hard-error overlay. Tappable when [onRetry] is non-null (#2): tapping
 * resets the reconnect attempt counter and re-prepares immediately, instead of the
 * user having to wait out the remaining slow-cadence retry interval. [onRetry] is
 * left null for the "no stream URL at all" case (nothing to retry — resolution
 * itself failed, this isn't a runtime playback error).
 */
@Composable
private fun TileErrorOverlay(
    modifier: Modifier = Modifier,
    noUrl: Boolean = false,
    onRetry: (() -> Unit)? = null,
) {
    Box(
        modifier = modifier
            .background(
                color = Color.Black.copy(alpha = 0.6f),
                shape = RoundedCornerShape(6.dp),
            )
            .then(
                if (onRetry != null) Modifier.clickable(onClick = onRetry) else Modifier,
            )
            .padding(8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = if (noUrl) "No stream" else "Stream error",
                style = MaterialTheme.typography.labelSmall,
                color = DangerRed,
            )
            if (onRetry != null) {
                Text(
                    text = "Tap to retry",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.White.copy(alpha = 0.75f),
                )
            }
        }
    }
}

// ─── detection icon mapping (matches the playback-timeline contract) ──────────
// Per-label glyph + colour now live in the shared [DetectionIcons] object so the
// live wall and the playback timeline stay in lockstep. icon_key is the label
// slug (person, car, truck, bus, bicycle, cat, dog, license_plate, …) with a
// generic fallback for unknown labels.

/** Material glyph for a Frigate detection [iconKey]. */
private fun detectionIconFor(iconKey: String): ImageVector = DetectionIcons.icon(iconKey)

/** Per-type color for a Frigate detection [iconKey]. */
private fun detectionColorFor(iconKey: String): Color = DetectionIcons.color(iconKey)
