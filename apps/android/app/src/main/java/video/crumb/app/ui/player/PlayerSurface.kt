// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.player

import android.view.LayoutInflater
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import video.crumb.app.R

/**
 * Shared video surface. Wraps a Media3 [PlayerView] (hardware decode via
 * MediaCodec) and binds the supplied [Player]. The caller owns the player's
 * lifecycle (build + release); this only attaches it to a surface.
 *
 * Controls are disabled — the app draws its own scrubber/overlays so the look
 * matches the desktop/web clients.
 *
 * @param textureView when true, use a TextureView-backed PlayerView so Compose
 *   graphicsLayer transforms (pinch-zoom / pan) apply to the video pixels. The
 *   default SurfaceView ignores those transforms (separate hardware layer). Use
 *   TextureView for fullscreen + playback (zoomable); keep SurfaceView for the
 *   multi-tile grid (cheaper, no zoom needed).
 * @param onViewReady invoked with the created [PlayerView] so the caller can grab
 *   the current video frame (`videoSurfaceView as TextureView`.bitmap) for the
 *   snapshot feature. Only meaningful with `textureView = true`.
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerSurface(
    player: Player,
    modifier: Modifier = Modifier,
    resizeMode: Int = AspectRatioFrameLayout.RESIZE_MODE_FIT,
    keepContentOnReset: Boolean = true,
    textureView: Boolean = false,
    useController: Boolean = false,
    onViewReady: ((PlayerView) -> Unit)? = null,
) {
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val view = if (textureView) {
                LayoutInflater.from(ctx)
                    .inflate(R.layout.player_view_texture, null, false) as PlayerView
            } else {
                PlayerView(ctx)
            }
            view.apply {
                this.useController = useController
                // Don't auto-pop the transport controls over the video when
                // playback starts (they briefly cover the clip before timing
                // out); the user taps to reveal them. Only relevant when the
                // controller is enabled (the clip player).
                if (useController) controllerAutoShow = false
                this.resizeMode = resizeMode
                setKeepContentOnPlayerReset(keepContentOnReset)
                setShutterBackgroundColor(android.graphics.Color.BLACK)
            }
            onViewReady?.invoke(view)
            view
        },
        update = { view ->
            if (view.player !== player) view.player = player
            view.resizeMode = resizeMode
        },
        onRelease = { view -> view.player = null },
    )
}
