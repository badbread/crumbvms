// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.nav

/**
 * Navigation destinations. Kept as plain string routes for use with
 * Navigation-Compose. Playback/export take a camera id argument.
 */
object Routes {
    const val LOGIN = "login"
    const val LIVE = "live"
    const val CLIPS = "clips"
    const val EXPORT = "export"

    // Playback is a STANDALONE top-level mode (like Live). PLAYBACK_STANDALONE
    // enters the multi-camera PLAYBACK WALL (a grid of latest-image snapshots with
    // shared playback controls); tapping a tile opens that camera in single-camera
    // playback. The single-camera route takes the camera id plus an OPTIONAL start
    // time `t` (epoch-millis) so the wall can dive in at the moment the operator
    // scrubbed to; `t` absent / ≤ 0 means "jump to the latest footage".
    const val PLAYBACK_STANDALONE = "playback"
    const val PLAYBACK = "playback/{cameraId}?t={t}"

    /** Cross-camera bookmarks list; tapping a row jumps to that camera+time. */
    const val BOOKMARKS = "bookmarks"
    fun playback(cameraId: String): String = "playback/$cameraId"
    fun playbackAt(cameraId: String, timeMs: Long): String = "playback/$cameraId?t=$timeMs"

    // Full-screen single-camera live view.
    const val LIVE_FULL_BASE = "livefull"
    const val LIVE_FULL = "livefull/{cameraId}"
    fun liveFull(cameraId: String): String = "livefull/$cameraId"

    // Motion Tuner for a single camera (admin-only). Reached from the fullscreen
    // live view's top-right controls.
    const val MOTION_TUNER = "motiontuner/{cameraId}"
    fun motionTuner(cameraId: String): String = "motiontuner/$cameraId"

    const val ARG_CAMERA_ID = "cameraId"
    const val ARG_TIME = "t"
}
