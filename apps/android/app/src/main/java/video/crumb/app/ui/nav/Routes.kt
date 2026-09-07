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

    // Export takes THREE optional query args so an entry point can seed the screen
    // with what the operator was already looking at: a camera to pre-select, and a
    // start/end (epoch-millis) to pre-fill the clip window. All absent / ≤ 0 means
    // "open blank", which is the plain `export` route the old entry point used.
    const val EXPORT = "export?cameraId={cameraId}&startMs={startMs}&endMs={endMs}"

    /**
     * Build a seeded Export route. A blank [cameraId] pre-selects nothing; a
     * [startMs]/[endMs] pair of 0 leaves the screen's own default window.
     */
    fun export(cameraId: String = "", startMs: Long = 0L, endMs: Long = 0L): String =
        "export?cameraId=${encodeArg(cameraId)}&startMs=$startMs&endMs=$endMs"

    /**
     * Percent-encode a value for use in a route query string. [java.net.URLEncoder]
     * is `application/x-www-form-urlencoded`, which encodes a space as `+`;
     * Navigation-Compose decodes routes as URIs, where `+` is a literal plus, so
     * spaces are re-written to `%20`.
     */
    internal fun encodeArg(raw: String): String =
        java.net.URLEncoder.encode(raw, "UTF-8").replace("+", "%20")

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

    // License-plate reads (LPR) tab — a cross-camera list of recognized plates;
    // tapping a row jumps to that camera+time on Playback (same hand-off as
    // Bookmarks/Clips). Gated on `SecureStore.platesEnabled`.
    const val PLATES = "plates"
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
    const val ARG_START_MS = "startMs"
    const val ARG_END_MS = "endMs"
}
