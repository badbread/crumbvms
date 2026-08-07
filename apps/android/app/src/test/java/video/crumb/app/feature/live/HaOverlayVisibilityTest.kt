// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [HaOverlayVisibility], the app-wide on/off state behind the two
 * "hide Home Assistant overlays" eye buttons (Live wall action row + fullscreen
 * controls). The persist hook is captured here instead of hitting
 * `SecureStore`, so these run as plain JVM tests.
 */
class HaOverlayVisibilityTest {

    /** Records every write the holder pushes at the store. */
    private class Recorder {
        val writes = mutableListOf<Boolean>()
        fun persist(value: Boolean) { writes += value }
    }

    @Test
    fun `starts from the seeded value without writing it back`() {
        val rec = Recorder()
        val shown = HaOverlayVisibility(initial = true, persist = rec::persist)
        assertTrue(shown.visible.value)
        // Seeding is a READ of the store, never a write.
        assertTrue(rec.writes.isEmpty())

        // The persisted "hidden" case restores as hidden on the next launch.
        assertFalse(HaOverlayVisibility(initial = false, persist = rec::persist).visible.value)
    }

    @Test
    fun `toggle flips the flow and persists each change`() {
        val rec = Recorder()
        val vis = HaOverlayVisibility(initial = true, persist = rec::persist)

        vis.toggle()
        assertFalse(vis.visible.value)

        vis.toggle()
        assertTrue(vis.visible.value)

        assertEquals(listOf(false, true), rec.writes)
    }

    @Test
    fun `setting the value it already has is a no-op`() {
        // Both eye buttons recompose freely; a redundant set must not spend an
        // encrypted-prefs write (or churn collectors of the flow).
        val rec = Recorder()
        val vis = HaOverlayVisibility(initial = true, persist = rec::persist)

        vis.set(true)
        assertTrue(vis.visible.value)
        assertTrue(rec.writes.isEmpty())

        vis.set(false)
        vis.set(false)
        assertFalse(vis.visible.value)
        assertEquals(listOf(false), rec.writes)
    }
}
