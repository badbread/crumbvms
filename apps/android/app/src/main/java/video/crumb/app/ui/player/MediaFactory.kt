// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.player

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource

/**
 * Builds ExoPlayer instances + media sources for the two playback modes:
 *
 * - **Live**: RTSP from go2rtc, forced over TCP (NAT/firewall-friendly,
 *   reliable on LAN/Tailscale). Hardware decode via MediaCodec.
 * - **Playback**: progressive fMP4 segments served by the API over HTTP; the
 *   `?token=` query param is already baked into the URL by `MediaUrls`.
 */
@OptIn(UnstableApi::class)
object MediaFactory {

    /** A fresh ExoPlayer. Caller MUST call `release()` when done. */
    fun newPlayer(context: Context): ExoPlayer =
        ExoPlayer.Builder(context).build()

    /** `USAGE_MEDIA` / movie audio attributes for recorded playback. Exposed so
     *  the screen can (re-)apply them with audio-focus handling tied to the
     *  mute/unmute toggle — see [newPlaybackPlayer]. */
    val playbackAudioAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
        .build()

    /**
     * ExoPlayer for RECORDED PLAYBACK (the timeline scrubber). Differs from the
     * bare [newPlayer] in two ways that matter for footage review over a WAN:
     *
     * 1. **Media audio attributes (#106).** Unlike the deliberately-muted live-wall
     *    tiles, recorded playback is watched WITH sound on purpose, so it declares
     *    `USAGE_MEDIA` / `CONTENT_TYPE_MOVIE` attributes to route to the media
     *    output path. Audio-**focus** handling is deliberately OFF at build time and
     *    (re)enabled by the screen only while the audio toggle is ON (see the volume
     *    effect in `PlaybackScreen`) — otherwise a silent scrub-through (the default,
     *    `playbackAudioOn = false`) would grab focus and pause the user's music.
     * 2. **WAN-tuned buffering.** A larger `DefaultLoadControl` window than the
     *    ExoPlayer default plus a retained back-buffer, so small backward scrubs
     *    replay from RAM instead of re-fetching, and a jittery cellular link has
     *    more slack before it rebuffers. (This reduces thrash; it does not change
     *    the source bitrate — that is what the `low.mp4` quality lever is for.)
     *
     *    The START threshold is deliberately much lower than the window. Every
     *    scrub release, motion jump and gap crossing is a hard `setMediaSource`
     *    into a fresh ~4 s segment, and with ExoPlayer's default
     *    `bufferForPlaybackMs` of 2 500 ms the first frame was held back until
     *    more than half of that file had downloaded, which is what made a seek
     *    feel like a stall even on a LAN. Starting at 750 ms shows the frame as
     *    soon as a GOP is in; the generous min/max window above still fills
     *    behind it, so steady-state WAN resilience is unchanged. The post-
     *    rebuffer threshold stays higher (a link that just underran gets more
     *    slack before resuming) but is also lower than before: a 4 s segment
     *    cannot buffer 5 s.
     *
     * Caller MUST call `release()` when done.
     */
    fun newPlaybackPlayer(context: Context): ExoPlayer {
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                /* minBufferMs */ 15_000,
                /* maxBufferMs */ 60_000,
                /* bufferForPlaybackMs */ PLAYBACK_START_BUFFER_MS,
                /* bufferForPlaybackAfterRebufferMs */ PLAYBACK_REBUFFER_START_MS,
            )
            // Retain up to 30 s of already-played media so a small backward scrub
            // replays from memory rather than re-downloading over the slow link.
            .setBackBuffer(/* backBufferDurationMs */ 30_000, /* retainBackBufferFromKeyframe */ true)
            .build()
        return ExoPlayer.Builder(context)
            .setLoadControl(loadControl)
            // Focus handling starts OFF (default playback is muted review); the
            // screen re-applies these attributes with focus = audioOn when the
            // user toggles sound on.
            .setAudioAttributes(playbackAudioAttributes, /* handleAudioFocus = */ false)
            .build()
    }

    /**
     * Low-latency ExoPlayer for LIVE RTSP. Thin buffers (start after ~100 ms,
     * keep ~0.5–1.5 s) + async MediaCodec queueing cut the live delay from the
     * default multi-second prebuffer to roughly 0.5–1 s on a LAN. (RTSP can't go
     * sub-200 ms here — that needs WebRTC from go2rtc.) Do NOT seek an RTSP live
     * stream to "drain" the buffer — it isn't seekable and sticks in buffering.
     * Caller MUST call `release()` when done.
     */
    fun newLivePlayer(context: Context): ExoPlayer {
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                /* minBufferMs */ 500,
                /* maxBufferMs */ 1500,
                /* bufferForPlaybackMs */ 100,
                /* bufferForPlaybackAfterRebufferMs */ 300,
            )
            .setPrioritizeTimeOverSizeThresholds(true)
            .setTargetBufferBytes(-1)
            .build()
        val renderers = DefaultRenderersFactory(context)
            .forceEnableMediaCodecAsynchronousQueueing()
        return ExoPlayer.Builder(context, renderers)
            .setLoadControl(loadControl)
            .build()
    }

    /** RTSP live source (go2rtc). TCP transport for reliability. */
    fun rtspSource(url: String): MediaSource =
        RtspMediaSource.Factory()
            .setForceUseRtpTcp(true)
            .createMediaSource(MediaItem.fromUri(url))

    /** See [newPlaybackPlayer]: buffered media required before the first frame
     *  of a freshly loaded segment is shown. */
    const val PLAYBACK_START_BUFFER_MS = 750
    /** See [newPlaybackPlayer]: buffered media required to resume after an
     *  underrun mid-segment. */
    const val PLAYBACK_REBUFFER_START_MS = 2_000

    /**
     * One HTTP data-source factory for every recorded-segment source. Each
     * `httpSource` call used to build its own factory; the factory itself is
     * cheap, but sharing one keeps a single `TransferListener`/defaults set and
     * makes the connection reuse story explicit: the underlying
     * `HttpURLConnection` keep-alive pool is process-wide, so back-to-back
     * segment opens (a scrub release right after a prefetch, or the gapless
     * playlist append) reuse the warm socket to the API instead of paying a
     * TCP (and on HTTPS, TLS) handshake per 4 s file.
     */
    private val segmentDataSourceFactory: DefaultHttpDataSource.Factory by lazy {
        DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(10_000)
            .setReadTimeoutMs(30_000)
            .setAllowCrossProtocolRedirects(true)
    }

    /** Progressive HTTP source for a recorded segment (URL already authed). */
    fun httpSource(url: String): MediaSource =
        ProgressiveMediaSource.Factory(segmentDataSourceFactory)
            .createMediaSource(MediaItem.fromUri(url))
}
