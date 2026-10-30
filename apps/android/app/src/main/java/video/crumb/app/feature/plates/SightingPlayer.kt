// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntSize
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import video.crumb.app.data.CrumbRepository
import video.crumb.app.data.MediaUrls
import video.crumb.app.data.ResolvedSegment
import video.crumb.app.data.isNotFound
import video.crumb.app.data.runCatchingCancellable
import video.crumb.app.ui.Time
import video.crumb.app.ui.player.MediaFactory
import java.time.Instant

/** What the profile video is doing, for the overlay message. */
enum class SightingStatus { LOADING, READY, NO_FOOTAGE, ERROR }

/**
 * Plays recorded footage of one sighting in the plate profile, over the
 * absolute time range [windowStartMs, windowEndMs]. Segments are resolved with
 * the same scoped-token path Playback uses (`/play/{camera}` then
 * [MediaUrls.scopedUrl]), never the bearer JWT, and chained into one gapless
 * ExoPlayer playlist one segment ahead.
 *
 * "Position" is always an absolute epoch-millis instant, so the scrubber, the
 * +/- skips, the bookmark time and the detection box all share one clock.
 */
class SightingPlayback(
    context: Context,
    private val repo: CrumbRepository,
    private val mediaUrls: MediaUrls,
    private val scope: CoroutineScope,
) {
    val player: ExoPlayer = MediaFactory.newPlaybackPlayer(context)

    var status by mutableStateOf(SightingStatus.LOADING)
        private set
    var playing by mutableStateOf(false)
        private set
    var muted by mutableStateOf(true)
        private set
    var ended by mutableStateOf(false)
        private set

    /** Absolute instant being shown. */
    var positionMs by mutableLongStateOf(0L)
        private set
    var windowStartMs by mutableLongStateOf(0L)
        private set
    var windowEndMs by mutableLongStateOf(0L)
        private set

    /** Decoded video size, to place the detection box over the fitted frame. */
    var videoSize by mutableStateOf(IntSize.Zero)
        private set

    private var cameraId: String = ""

    /** Absolute start of each playlist item, index-aligned with the player's playlist. */
    private val segStarts = ArrayList<Long>()
    private var lastSegEndMs = 0L
    private var loadJob: Job? = null
    private var appendJob: Job? = null
    private var released = false

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            playing = isPlaying
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) {
                ended = true
                playing = false
            } else if (playbackState == Player.STATE_READY) {
                ended = false
            }
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            // Started the last queued segment: line up the next one.
            if (player.currentMediaItemIndex >= segStarts.lastIndex) appendNext()
        }

        override fun onVideoSizeChanged(size: VideoSize) {
            videoSize = IntSize(size.width, size.height)
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            status = SightingStatus.ERROR
            repo.invalidateResolveCache(cameraId)
        }
    }

    /** Begin a new sighting: cover [startMs, endMs] on [cameraId] and start at [startAtMs]. */
    fun start(cameraId: String, startMs: Long, endMs: Long, startAtMs: Long, fallbackAtMs: Long = startAtMs) {
        this.cameraId = cameraId
        windowStartMs = startMs
        windowEndMs = endMs
        positionMs = startAtMs.coerceIn(startMs, endMs)
        ended = false
        load(positionMs, fallbackAtMs, autoplay = true)
    }

    /** Re-fit the scrub range (e.g. once the whole visit is known) without restarting the video. */
    fun setWindow(startMs: Long, endMs: Long) {
        windowStartMs = startMs
        windowEndMs = endMs
        if (status == SightingStatus.READY) appendNext()
    }

    /** Seek to the absolute instant [absMs] (clamped to the window), keeping play/pause. */
    fun seekTo(absMs: Long) {
        val target = absMs.coerceIn(windowStartMs, windowEndMs)
        positionMs = target
        ended = false
        // Fast path: the instant is inside the segment that is already playing.
        val idx = player.currentMediaItemIndex
        val base = segStarts.getOrNull(idx)
        val dur = player.duration
        if (base != null && dur > 0 && target >= base && target < base + dur && status == SightingStatus.READY) {
            player.seekTo(target - base)
            return
        }
        load(target, target, autoplay = player.playWhenReady || ended)
    }

    fun skip(deltaMs: Long) = seekTo(currentAbs() + deltaMs)

    fun togglePlay() {
        if (status != SightingStatus.READY) return
        if (player.isPlaying) {
            player.pause()
        } else {
            if (ended || currentAbs() >= windowEndMs) seekTo(windowStartMs)
            player.play()
        }
    }

    fun applyMuted(value: Boolean) {
        muted = value
        player.volume = if (value) 0f else 1f
        // Audio focus only while sound is on, so a silent review does not pause the user's music.
        player.setAudioAttributes(MediaFactory.playbackAudioAttributes, !value)
    }

    fun pause() {
        player.pause()
    }

    /** The absolute instant currently on screen. */
    fun currentAbs(): Long {
        val base = segStarts.getOrNull(player.currentMediaItemIndex) ?: return positionMs
        return base + player.currentPosition
    }

    /** Poll the clock (called a few times a second) and stop at the end of the window. */
    fun tick() {
        if (released || status != SightingStatus.READY) return
        val abs = currentAbs()
        if (abs >= windowEndMs && player.isPlaying) {
            player.pause()
            positionMs = windowEndMs
            return
        }
        positionMs = abs.coerceIn(windowStartMs, windowEndMs)
    }

    fun release() {
        released = true
        loadJob?.cancel()
        appendJob?.cancel()
        player.removeListener(listener)
        player.release()
    }

    private fun load(absMs: Long, fallbackMs: Long, autoplay: Boolean) {
        loadJob?.cancel()
        appendJob?.cancel()
        status = SightingStatus.LOADING
        loadJob = scope.launch {
            var seg = resolve(absMs)
            var at = absMs
            if (seg == null && fallbackMs != absMs) {
                seg = resolve(fallbackMs)
                at = fallbackMs
            }
            if (released) return@launch
            val resolved = seg
            if (resolved == null) {
                status = if (lastResolveMissing) SightingStatus.NO_FOOTAGE else SightingStatus.ERROR
                return@launch
            }
            val url = runCatchingCancellable { mediaUrls.scopedUrl(cameraId, resolved.url) }.getOrNull()
            if (url == null) {
                status = SightingStatus.ERROR
                return@launch
            }
            val segStart = Time.parseToMillis(resolved.start)
            segStarts.clear()
            segStarts += segStart
            lastSegEndMs = Time.parseToMillis(resolved.end)
            runCatching {
                player.setMediaSource(MediaFactory.httpSource(url))
                player.prepare()
                player.seekTo((at - segStart).coerceAtLeast(0L))
                player.playWhenReady = autoplay
            }
            positionMs = at.coerceIn(windowStartMs, windowEndMs)
            status = SightingStatus.READY
            appendNext()
        }
    }

    private var lastResolveMissing = false

    private suspend fun resolve(absMs: Long): ResolvedSegment? {
        var out: ResolvedSegment? = null
        lastResolveMissing = false
        repo.resolveSegment(cameraId, Time.iso(Instant.ofEpochMilli(absMs)))
            .onSuccess { out = it }
            .onFailure { lastResolveMissing = it.isNotFound() }
        return out
    }

    private fun appendNext() {
        if (released || lastSegEndMs >= windowEndMs) return
        appendJob?.cancel()
        val want = lastSegEndMs + 1
        appendJob = scope.launch {
            val seg = resolve(want) ?: return@launch
            val start = Time.parseToMillis(seg.start)
            if (segStarts.isEmpty() || start <= segStarts.last()) return@launch
            val url = runCatchingCancellable { mediaUrls.scopedUrl(cameraId, seg.url) }.getOrNull() ?: return@launch
            if (released) return@launch
            segStarts += start
            lastSegEndMs = Time.parseToMillis(seg.end)
            runCatching { player.addMediaSource(MediaFactory.httpSource(url)) }
        }
    }

    // Kept LAST: it touches [player] and [listener], which must already exist.
    init {
        player.volume = 0f
        player.addListener(listener)
    }
}

/**
 * Remember a [SightingPlayback] tied to the composition: it pauses when the app
 * is backgrounded, polls its clock for the scrubber, and releases the player
 * when the profile closes.
 */
@Composable
fun rememberSightingPlayback(repo: CrumbRepository, mediaUrls: MediaUrls): SightingPlayback {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val playback = remember { SightingPlayback(context, repo, mediaUrls, scope) }
    DisposableEffect(playback) { onDispose { playback.release() } }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, playback) {
        var wasPlaying = false
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> {
                    wasPlaying = playback.player.playWhenReady
                    playback.pause()
                }
                Lifecycle.Event.ON_RESUME -> if (wasPlaying) playback.player.play()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(playback) {
        while (true) {
            playback.tick()
            delay(200)
        }
    }
    return playback
}
