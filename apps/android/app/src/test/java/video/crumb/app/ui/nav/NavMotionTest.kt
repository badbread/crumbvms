// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Test

class NavMotionTest {
    @Test
    fun `wall tile to camera grows out of the tile`() {
        assertEquals(NavMotionKind.TILE_GROW, navMotionKind(Routes.LIVE, Routes.LIVE_FULL))
        assertEquals(NavMotionKind.TILE_GROW, navMotionKind(Routes.PLAYBACK_STANDALONE, Routes.PLAYBACK))
    }

    @Test
    fun `tab to tab scales in except into the live wall`() {
        assertEquals(NavMotionKind.FADE_THROUGH_SCALE, navMotionKind(Routes.LIVE, Routes.CLIPS))
        assertEquals(NavMotionKind.FADE_THROUGH_SCALE, navMotionKind(Routes.CLIPS, Routes.PLATES))
        assertEquals(NavMotionKind.FADE_THROUGH, navMotionKind(Routes.CLIPS, Routes.LIVE))
    }

    @Test
    fun `other steps plain fade through`() {
        assertEquals(NavMotionKind.FADE_THROUGH, navMotionKind(Routes.LIVE_FULL, Routes.PLAYBACK))
        assertEquals(NavMotionKind.FADE_THROUGH, navMotionKind(Routes.CLIPS, Routes.PLAYBACK))
        assertEquals(NavMotionKind.FADE_THROUGH, navMotionKind(Routes.LOGIN, Routes.LIVE))
    }

    @Test
    fun `only camera screens shrink back to their tile`() {
        assertEquals(NavMotionKind.TILE_GROW, navPopMotionKind(Routes.LIVE_FULL, Routes.LIVE))
        assertEquals(NavMotionKind.TILE_GROW, navPopMotionKind(Routes.PLAYBACK, Routes.PLAYBACK_STANDALONE))
        assertEquals(NavMotionKind.FADE_THROUGH, navPopMotionKind(Routes.PLAYBACK, Routes.CLIPS))
    }
}
