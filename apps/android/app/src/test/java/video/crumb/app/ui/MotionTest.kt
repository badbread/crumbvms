// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MotionTest {
    @Test
    fun `stagger is 30 ms per item`() {
        assertEquals(0L, staggerDelayMs(0))
        assertEquals(30L, staggerDelayMs(1))
        assertEquals(210L, staggerDelayMs(7))
    }

    @Test
    fun `items past the cap do not animate`() {
        assertNull(staggerDelayMs(STAGGER_MAX_ITEMS))
        assertNull(staggerDelayMs(100))
        assertNull(staggerDelayMs(-1))
    }
}
