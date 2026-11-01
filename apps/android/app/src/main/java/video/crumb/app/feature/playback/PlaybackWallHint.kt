// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

/**
 * The Playback wall's "Tap a camera for full controls" hint (polish pass W3). It is
 * for first runs only: once the operator has opened a camera from the wall it is
 * retired for good, so the control row stays quiet afterwards.
 */
object PlaybackWallHint {
    const val TEXT = "Tap a camera for full controls"

    /** Show the hint until the operator has opened a camera from the wall once. */
    fun shouldShow(hintSeen: Boolean): Boolean = !hintSeen
}
