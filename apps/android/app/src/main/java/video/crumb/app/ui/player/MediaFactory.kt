// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.player

import android.content.Context
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
