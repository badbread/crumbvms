// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.playback

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackWallHintTest {
    @Test
    fun `first run shows the hint`() {
        assertTrue(PlaybackWallHint.shouldShow(hintSeen = false))
    }

    @Test
    fun `hint retires once a camera has been opened`() {
        assertFalse(PlaybackWallHint.shouldShow(hintSeen = true))
    }
}
