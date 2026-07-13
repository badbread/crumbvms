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

    /**
     * ExoPlayer for RECORDED PLAYBACK (the timeline scrubber). Differs from the
     * bare [newPlayer] in two ways that matter for footage review over a WAN:
     *
     * 1. **Audio focus + media attributes (#106).** Unlike the deliberately-muted
     *    live-wall tiles, recorded playback is watched WITH sound on purpose. We
     *    declare `USAGE_MEDIA` / `CONTENT_TYPE_MOVIE` audio attributes and let
     *    ExoPlayer manage audio focus (`handleAudioFocus = true`), so the player
     *    properly acquires the media output path instead of a silent AudioTrack,
     *    and pauses on headphones-unplug (`handleAudioBecomingNoisy`). The
     *    per-segment volume the UI sets (mute/unmute toggle) rides on top of this.
     * 2. **WAN-tuned buffering.** A larger `DefaultLoadControl` window than the
     *    ExoPlayer default plus a retained back-buffer, so small backward scrubs
     *    replay from RAM instead of re-fetching, and a jittery cellular link has
     *    more slack before it rebuffers. (This reduces thrash; it does not change
     *    the source bitrate — that is what the `low.mp4` quality lever is for.)
     *
     * Caller MUST call `release()` when done.
     */
    fun newPlaybackPlayer(context: Context): ExoPlayer {
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                /* minBufferMs */ 15_000,
                /* maxBufferMs */ 60_000,
                /* bufferForPlaybackMs */ 2_500,
                /* bufferForPlaybackAfterRebufferMs */ 5_000,
            )
            // Retain up to 30 s of already-played media so a small backward scrub
            // replays from memory rather than re-downloading over the slow link.
            .setBackBuffer(/* backBufferDurationMs */ 30_000, /* retainBackBufferFromKeyframe */ true)
            .build()
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .build()
        return ExoPlayer.Builder(context)
            .setLoadControl(loadControl)
            .setAudioAttributes(audioAttributes, /* handleAudioFocus = */ true)
            .setHandleAudioBecomingNoisy(true)
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

    /** Progressive HTTP source for a recorded segment (URL already authed). */
    fun httpSource(url: String): MediaSource {
        val dataSourceFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(10_000)
            .setReadTimeoutMs(30_000)
            .setAllowCrossProtocolRedirects(true)
        return ProgressiveMediaSource.Factory(dataSourceFactory)
            .createMediaSource(MediaItem.fromUri(url))
    }
}
