// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [RecentsPrivacy], the per-API-level choice of how camera
 * content is kept off the recents / app-switcher card. Pure logic, so these run
 * as plain JVM tests.
 */
class RecentsPrivacyTest {

    @Test
    fun `api 33 and above uses the dedicated recents switch`() {
        assertTrue(RecentsPrivacy.usesRecentsSwitch(33))
        assertTrue(RecentsPrivacy.usesRecentsSwitch(34))
        assertTrue(RecentsPrivacy.usesRecentsSwitch(35))
        assertFalse(RecentsPrivacy.usesSecureWindowFallback(33))
    }

    @Test
    fun `below api 33 falls back to the secure window`() {
        assertFalse(RecentsPrivacy.usesRecentsSwitch(26))
        assertFalse(RecentsPrivacy.usesRecentsSwitch(32))
        assertTrue(RecentsPrivacy.usesSecureWindowFallback(26))
        assertTrue(RecentsPrivacy.usesSecureWindowFallback(32))
    }

    @Test
    fun `the fallback secures the window only when leaving the foreground`() {
        // Pre-33, a normal pause is the moment the recents snapshot is taken.
        assertTrue(RecentsPrivacy.secureOnPause(26, inPictureInPicture = false))
        assertTrue(RecentsPrivacy.secureOnPause(32, inPictureInPicture = false))
    }

    @Test
    fun `picture-in-picture is never secured, it would blank the floating window`() {
        assertFalse(RecentsPrivacy.secureOnPause(26, inPictureInPicture = true))
        assertFalse(RecentsPrivacy.secureOnPause(32, inPictureInPicture = true))
        assertFalse(RecentsPrivacy.secureOnPause(34, inPictureInPicture = true))
    }

    @Test
    fun `api 33 and above never touches the secure flag, foreground capture stays available`() {
        assertFalse(RecentsPrivacy.secureOnPause(33, inPictureInPicture = false))
        assertFalse(RecentsPrivacy.secureOnPause(34, inPictureInPicture = false))
    }
}
