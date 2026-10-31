// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue

/**
 * Rules for hiding the Playback controls in landscape, where the transport bar
 * takes a large share of a short screen. A tap on the video shows or hides them;
 * while playing they hide by themselves after [AUTO_HIDE_MS] without a touch.
 * Kept free of Android types so it is unit-testable.
 */
object PlaybackChromePolicy {

    const val AUTO_HIDE_MS = 4_000L

    /**
     * Whether the controls are actually hidden. Only in landscape (portrait keeps
     * the video and the bar apart, so hiding gains nothing), and only while there
     * is video to look at: a loading, error or no-footage state keeps them up so
     * the way out is always visible.
     */
    fun hidden(landscape: Boolean, userHidden: Boolean, hasVideo: Boolean): Boolean =
        landscape && userHidden && hasVideo

    /**
     * Whether the auto-hide countdown should run. Never while paused (you are
     * looking for something), while scrubbing, or while a menu, sheet or dialog
     * from the controls is open.
     */
    fun autoHideArmed(
        landscape: Boolean,
        hasVideo: Boolean,
        playing: Boolean,
        scrubbing: Boolean,
        held: Boolean,
        alreadyHidden: Boolean,
    ): Boolean = landscape && hasVideo && playing && !scrubbing && !held && !alreadyHidden
}

/** Count of open menus, sheets and dialogs that must keep the controls up. */
@Stable
class ChromeHold {
    var count by mutableIntStateOf(0)
        private set

    val held: Boolean get() = count > 0

    internal fun acquire() { count++ }
    internal fun release() { if (count > 0) count-- }
}

val LocalChromeHold = compositionLocalOf<ChromeHold?> { null }

/** Keeps the Playback controls from auto-hiding while [open] is true. */
@Composable
fun HoldChrome(open: Boolean) {
    val hold = LocalChromeHold.current ?: return
    if (!open) return
    DisposableEffect(hold) {
        hold.acquire()
        onDispose { hold.release() }
    }
}
