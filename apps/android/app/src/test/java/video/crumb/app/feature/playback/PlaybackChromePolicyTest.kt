// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackChromePolicyTest {

    @Test
    fun hiddenOnlyInLandscapeWithVideo() {
        assertTrue(PlaybackChromePolicy.hidden(landscape = true, userHidden = true, hasVideo = true))
        assertFalse(PlaybackChromePolicy.hidden(landscape = false, userHidden = true, hasVideo = true))
        assertFalse(PlaybackChromePolicy.hidden(landscape = true, userHidden = true, hasVideo = false))
        assertFalse(PlaybackChromePolicy.hidden(landscape = true, userHidden = false, hasVideo = true))
    }

    private fun armed(
        landscape: Boolean = true,
        hasVideo: Boolean = true,
        playing: Boolean = true,
        scrubbing: Boolean = false,
        held: Boolean = false,
        alreadyHidden: Boolean = false,
    ) = PlaybackChromePolicy.autoHideArmed(landscape, hasVideo, playing, scrubbing, held, alreadyHidden)

    @Test
    fun autoHideRunsOnlyWhilePlayingUntouched() {
        assertTrue(armed())
        assertFalse(armed(playing = false))
        assertFalse(armed(scrubbing = true))
        assertFalse(armed(held = true))
        assertFalse(armed(landscape = false))
        assertFalse(armed(hasVideo = false))
        assertFalse(armed(alreadyHidden = true))
    }
}
