// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure slider-math for the HA value slider (#442, Slice 1). Extracted from the
 * composable so the two decisions that drive the anti-bounce behaviour are
 * testable without a UI harness:
 *  - [haSnapToStep]: the CONTINUOUS thumb is rounded onto the descriptor's grid
 *    only ONCE, on release, so the committed/POSTed value is step-aligned while
 *    the drag itself stays smooth (no discrete-slider snapping "bar bounce").
 *  - [haHoldConverged]: whether a just-committed value has been reflected by the
 *    `/ha/states` poll yet, so the thumb holds the committed value instead of
 *    snapping back to the device's transitioning old value (#465).
 * Both are kind-agnostic: bounds/step come from the descriptor, never a
 * hardcoded 0..100.
 */
class HaValueSliderLogicTest {

    // ── haSnapToStep ────────────────────────────────────────────────────────

    @Test
    fun `step 1 rounds to the nearest whole percent`() {
        assertEquals(62.0, haSnapToStep(61.7, 0.0, 100.0, 1.0), 0.0)
        assertEquals(0.0, haSnapToStep(0.4, 0.0, 100.0, 1.0), 0.0)
        assertEquals(100.0, haSnapToStep(99.6, 0.0, 100.0, 1.0), 0.0)
    }

    @Test
    fun `a coarse step snaps to the nearest multiple`() {
        // A fan with step 25: mid-drag values land on 0/25/50/75/100.
        assertEquals(50.0, haSnapToStep(51.0, 0.0, 100.0, 25.0), 0.0)
        assertEquals(75.0, haSnapToStep(64.0, 0.0, 100.0, 25.0), 0.0)
        assertEquals(0.0, haSnapToStep(10.0, 0.0, 100.0, 25.0), 0.0)
    }

    @Test
    fun `snapping clamps into bounds and honours a non-zero minimum`() {
        assertEquals(100.0, haSnapToStep(140.0, 0.0, 100.0, 1.0), 0.0)
        assertEquals(0.0, haSnapToStep(-20.0, 0.0, 100.0, 1.0), 0.0)
        // Grid measured FROM min (not from 0): min 10, step 5 -> 10,15,20,...
        assertEquals(20.0, haSnapToStep(21.0, 10.0, 30.0, 5.0), 0.0)
        assertEquals(10.0, haSnapToStep(9.0, 10.0, 30.0, 5.0), 0.0)
    }

    @Test
    fun `a non-positive step is treated as 1 rather than dividing by zero`() {
        assertEquals(43.0, haSnapToStep(42.6, 0.0, 100.0, 0.0), 0.0)
        assertEquals(43.0, haSnapToStep(42.6, 0.0, 100.0, -5.0), 0.0)
    }

    // ── haHoldConverged ─────────────────────────────────────────────────────

    @Test
    fun `the hold releases once the poll reaches the committed value`() {
        assertTrue(haHoldConverged(60.0, 60.0, 1.0))
    }

    @Test
    fun `the hold releases within a step plus rounding margin`() {
        // percent<->brightness (0..255) rounding can land the poll a hair off.
        assertTrue(haHoldConverged(59.0, 60.0, 1.0))
        assertTrue(haHoldConverged(61.4, 60.0, 1.0))
        // A coarse step widens the acceptance window accordingly.
        assertTrue(haHoldConverged(74.0, 75.0, 25.0))
    }

    @Test
    fun `the hold persists while the poll still reports the old value`() {
        // Committed 100, device still transitioning through its old 20 -> keep holding.
        assertFalse(haHoldConverged(20.0, 100.0, 1.0))
        assertFalse(haHoldConverged(0.0, 50.0, 1.0))
    }
}
