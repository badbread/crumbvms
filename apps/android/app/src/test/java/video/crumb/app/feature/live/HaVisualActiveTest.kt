// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import video.crumb.app.data.HaLinkDto

/**
 * The tri-state [BadgeVisual.active] the canonical [badgeVisual] mapping derives
 * once (on / off / unknown), and which the more-info dialog uses to fill the icon
 * disc boldly for an ON actuator (the "popup icon didn't read as lit" polish).
 * Locks that on-vs-off is honestly signalled and that an ON light really carries
 * the warm-yellow accent — no forked color logic, no reliance on the color to
 * infer state.
 */
class HaVisualActiveTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun link(entityId: String, deviceClass: String? = null): HaLinkDto {
        val dc = if (deviceClass != null) ",\"device_class\":\"$deviceClass\"" else ""
        return json.decodeFromString(
            HaLinkDto.serializer(),
            "{\"id\":\"l\",\"entity_id\":\"$entityId\",\"role\":\"actuator\",\"sort_order\":0$dc}",
        )
    }

    @Test
    fun `a light that is on is active with the warm-yellow accent`() {
        val v = badgeVisual(link("light.kitchen"), "on", stale = false)
        assertEquals(true, v.active)
        assertEquals(BadgeWarmYellow, v.color)
        assertEquals("On", v.label)
    }

    @Test
    fun `a light that is off is inactive and grey`() {
        val v = badgeVisual(link("light.kitchen"), "off", stale = false)
        assertEquals(false, v.active)
        assertEquals(BadgeGrey, v.color)
        assertEquals("Off", v.label)
    }

    @Test
    fun `a switch that is on is active`() {
        assertTrue(badgeVisual(link("switch.porch"), "on", stale = false).active == true)
        assertFalse(badgeVisual(link("switch.porch"), "off", stale = false).active == true)
    }

    @Test
    fun `an unknown or stale reading is indeterminate, never a confident off`() {
        // Unknown state -> null (not false), so the dialog does not render a bold
        // "on" disc nor a confident "off".
        assertNull(badgeVisual(link("light.kitchen"), "unavailable", stale = false).active)
        assertNull(badgeVisual(link("light.kitchen"), null, stale = false).active)
        // A fresh "on" reading but a stale feed must not read as lit.
        assertNull(badgeVisual(link("light.kitchen"), "on", stale = true).active)
    }

    @Test
    fun `an open contact sensor is active`() {
        val v = badgeVisual(link("binary_sensor.front_door", deviceClass = "door"), "on", stale = false)
        assertEquals(true, v.active)
        assertEquals("Open", v.label)
    }
}
