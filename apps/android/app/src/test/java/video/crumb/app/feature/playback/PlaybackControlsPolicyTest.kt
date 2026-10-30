// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import video.crumb.app.feature.playback.PlaybackControl.*

/** Default / migration rule and per-mode control visibility for Playback. */
class PlaybackControlsPolicyTest {

    @Test
    fun freshInstallStaysSimple() {
        assertFalse(
            PlaybackControlsPolicy.advancedAfterMigration(
                alreadyApplied = false, hasPriorState = false, current = false,
            ),
        )
    }

    @Test
    fun existingInstallBecomesAdvancedOnce() {
        assertTrue(
            PlaybackControlsPolicy.advancedAfterMigration(
                alreadyApplied = false, hasPriorState = true, current = false,
            ),
        )
    }

    @Test
    fun migrationNeverOverridesAChoiceOnceApplied() {
        // User later switched to Simple on an old install: must stay Simple.
        assertFalse(
            PlaybackControlsPolicy.advancedAfterMigration(
                alreadyApplied = true, hasPriorState = true, current = false,
            ),
        )
        assertTrue(
            PlaybackControlsPolicy.advancedAfterMigration(
                alreadyApplied = true, hasPriorState = false, current = true,
            ),
        )
    }

    @Test
    fun simpleBarIsCalm() {
        assertEquals(
            listOf(SPEED, PREV_MOTION, PLAY, NEXT_MOTION, LATEST, MORE),
            PlaybackControlsPolicy.barControls(advanced = false, landscape = false, stepPinned = false),
        )
    }

    @Test
    fun pinnedFrameStepAddsBothStepButtonsAroundPlay() {
        assertEquals(
            listOf(SPEED, STEP_BACK, PREV_MOTION, PLAY, NEXT_MOTION, STEP_FORWARD, LATEST, MORE),
            PlaybackControlsPolicy.barControls(advanced = false, landscape = true, stepPinned = true),
        )
    }

    @Test
    fun advancedLandscapeShowsAllFourteenControls() {
        val bar = PlaybackControlsPolicy.barControls(advanced = true, landscape = true, stepPinned = false)
        assertEquals(14, bar.size)
        assertEquals(14, bar.toSet().size)
        assertFalse(MORE in bar)
    }

    @Test
    fun advancedPortraitKeepsMuteAndQualityInTheAppBar() {
        val bar = PlaybackControlsPolicy.barControls(advanced = true, landscape = false, stepPinned = false)
        assertFalse(MUTE in bar)
        assertFalse(QUALITY in bar)
        assertEquals(12, bar.size)
        assertTrue(PlaybackControlsPolicy.appBarHasQuality(advanced = true))
        assertFalse(PlaybackControlsPolicy.appBarHasQuality(advanced = false))
    }

    @Test
    fun nothingIsLostInSimpleMode() {
        // Every Advanced landscape control is on the Simple bar or in the More sheet.
        val all = PlaybackControlsPolicy.barControls(advanced = true, landscape = true, stepPinned = false).toSet()
        val simple = PlaybackControlsPolicy.barControls(advanced = false, landscape = true, stepPinned = false).toSet() +
            PlaybackControlsPolicy.sheetControls(landscape = true).toSet() + STEP_FORWARD
        assertTrue("missing: ${all - simple}", simple.containsAll(all))
    }

    @Test
    fun sheetHasMuteOnlyInLandscape() {
        assertTrue(MUTE in PlaybackControlsPolicy.sheetControls(landscape = true))
        assertFalse(MUTE in PlaybackControlsPolicy.sheetControls(landscape = false))
    }
}
