// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.plates

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import video.crumb.app.data.PlateRead

/**
 * Unit tests for the Plates copy affordance: what lands on the clipboard
 * ([plateCopyText]) and whether the copy needs an in-app confirmation
 * ([systemConfirmsClipboardWrite]).
 */
class PlateCopyTest {

    private fun read(plate: String, displayName: String? = null) = PlateRead(
        id = "read-1",
        cameraId = "cam-1",
        ts = "2026-08-06T12:00:00Z",
        plate = plate,
        displayName = displayName,
    )

    @Test
    fun `copies the raw plate when the read has no name`() {
        assertEquals("7ABC123", plateCopyText(read("7ABC123")))
    }

    @Test
    fun `copies the raw plate even when a display name is shown in its place`() {
        // The row shows "Mom's car" as the prominent line, but an operator copying
        // a plate wants the string that matches the read everywhere else.
        assertEquals("7ABC123", plateCopyText(read("7ABC123", displayName = "Mom's car")))
    }

    @Test
    fun `trims surrounding whitespace`() {
        assertEquals("7ABC123", plateCopyText(read("  7ABC123 ")))
    }

    @Test
    fun `nothing to copy when the read has no plate text`() {
        assertNull(plateCopyText(read("")))
        assertNull(plateCopyText(read("   ", displayName = "Named but plateless")))
    }

    @Test
    fun `in-app confirmation only below Android 13`() {
        // API 33+ shows the system clipboard panel, so a snackbar would duplicate it.
        assertFalse(systemConfirmsClipboardWrite(26))
        assertFalse(systemConfirmsClipboardWrite(32))
        assertTrue(systemConfirmsClipboardWrite(33))
        assertTrue(systemConfirmsClipboardWrite(34))
    }
}
