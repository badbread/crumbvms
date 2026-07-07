// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Bridge between Compose screens and the Activity's Picture-in-Picture support.
 *
 * A full-screen video screen marks itself active via [setVideoActive] so the
 * Activity auto-enters PiP when the user leaves the app (Home / gesture), keeping
 * the camera playing in a floating window — like YouTube. Screens read [isInPip]
 * (Compose-observable) to hide their chrome so only the video shows in the PiP
 * window.
 */
interface PipController {
    /** True while the Activity is currently in a PiP window. Compose-observable. */
    val isInPip: Boolean

    /** Mark whether a full-screen video is showing (enables auto-PiP on leave). */
    fun setVideoActive(active: Boolean)
}

/** Provided by [MainActivity]; consumed by full-screen video screens. */
val LocalPipController = staticCompositionLocalOf<PipController> {
    error("LocalPipController not provided")
}
