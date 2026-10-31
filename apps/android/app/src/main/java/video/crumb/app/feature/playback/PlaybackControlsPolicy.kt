// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

/** One control on the single-camera Playback screen. */
enum class PlaybackControl {
    FIRST,
    STEP_BACK,
    PREV_MOTION,
    PLAY,
    NEXT_MOTION,
    STEP_FORWARD,
    LATEST,
    SPEED,
    JUMP,
    CLIP,
    SNAPSHOT,
    BOOKMARK,
    MUTE,
    QUALITY,
    MORE,
}

/**
 * Pure rules for the Simple / Advanced playback controls setting: the one-time
 * default for existing installs, and which controls are on the bar versus one tap
 * away per mode and orientation. Kept free of Android types so it is unit-testable.
 */
object PlaybackControlsPolicy {

    /**
     * Value of the "advanced" preference after the one-time migration step.
     * Before the migration has run, an install that already has a session or saved
     * prefs becomes Advanced (nobody loses stepping, speed or export on update);
     * a brand new install stays Simple. Once applied it never changes the value.
     */
    fun advancedAfterMigration(
        alreadyApplied: Boolean,
        hasPriorState: Boolean,
        current: Boolean,
    ): Boolean = if (alreadyApplied) current else (hasPriorState || current)

    private val NAV = listOf(
        PlaybackControl.FIRST,
        PlaybackControl.STEP_BACK,
        PlaybackControl.PREV_MOTION,
        PlaybackControl.PLAY,
        PlaybackControl.NEXT_MOTION,
        PlaybackControl.STEP_FORWARD,
        PlaybackControl.LATEST,
    )

    /** Controls drawn on the transport bar itself (the app bar is separate). */
    fun barControls(advanced: Boolean, landscape: Boolean, stepPinned: Boolean): List<PlaybackControl> =
        if (!advanced) {
            buildList {
                add(PlaybackControl.SPEED)
                if (stepPinned) add(PlaybackControl.STEP_BACK)
                add(PlaybackControl.PREV_MOTION)
                add(PlaybackControl.PLAY)
                add(PlaybackControl.NEXT_MOTION)
                if (stepPinned) add(PlaybackControl.STEP_FORWARD)
                add(PlaybackControl.LATEST)
                add(PlaybackControl.MORE)
            }
        } else if (landscape) {
            NAV + listOf(
                PlaybackControl.SPEED,
                PlaybackControl.JUMP,
                PlaybackControl.CLIP,
                PlaybackControl.SNAPSHOT,
                PlaybackControl.BOOKMARK,
                PlaybackControl.MUTE,
                PlaybackControl.QUALITY,
            )
        } else {
            // Portrait keeps mute and quality in the app bar.
            NAV + listOf(
                PlaybackControl.SPEED,
                PlaybackControl.JUMP,
                PlaybackControl.CLIP,
                PlaybackControl.SNAPSHOT,
                PlaybackControl.BOOKMARK,
            )
        }

    /** Controls in the Simple More sheet (everything not on the Simple bar). */
    fun sheetControls(landscape: Boolean): List<PlaybackControl> = buildList {
        add(PlaybackControl.JUMP)
        add(PlaybackControl.SNAPSHOT)
        add(PlaybackControl.BOOKMARK)
        add(PlaybackControl.CLIP)
        add(PlaybackControl.QUALITY)
        add(PlaybackControl.FIRST)
        add(PlaybackControl.STEP_BACK) // the "Frame step" tile (pins both step buttons)
        // Portrait has mute in the app bar; landscape has no app bar.
        if (landscape) add(PlaybackControl.MUTE)
    }

    /** Whether the portrait app bar shows the quality chip (Simple moves it to the sheet). */
    fun appBarHasQuality(advanced: Boolean): Boolean = advanced
}
