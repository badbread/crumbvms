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
 * once (on / off / unknown), plus the state color the more-info dialog tints its
 * icon glyph with — the same near-black-chip + full-strength-color-glyph look as
 * the on-video badge (the "popup didn't match the badge" polish, #437). Locks that
 * on-vs-off is honestly signalled and that an ON light really carries the
 * warm-yellow accent the popup glyph shows — no forked color logic, no reliance on
 * the color to infer state.
 */
class HaVisualActiveTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun link(
        entityId: String,
        deviceClass: String? = null,
        bgColor: String? = null,
        bgColorOn: String? = null,
    ): HaLinkDto {
        val dc = if (deviceClass != null) ",\"device_class\":\"$deviceClass\"" else ""
        val bg = if (bgColor != null) ",\"overlay_bg_color\":\"$bgColor\"" else ""
        val bgOn = if (bgColorOn != null) ",\"overlay_bg_color_on\":\"$bgColorOn\"" else ""
        return json.decodeFromString(
            HaLinkDto.serializer(),
            "{\"id\":\"l\",\"entity_id\":\"$entityId\",\"role\":\"actuator\",\"sort_order\":0$dc$bg$bgOn}",
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

    // ── Badge chip background resolution: overlay_bg_color_on / overlay_bg_color
    // / default, keyed on the SAME `active` tri-state above. ─────────────────────

    @Test
    fun `no overlay_bg_color_on decodes to null, unchanged byte-for-byte`() {
        val l = link("light.kitchen", bgColor = "#112233")
        assertNull(l.overlayBgColorOn)
        // Existing bg-color-only behavior is untouched, on or off.
        assertEquals(parseHexColor("#112233"), resolveBadgeBg(l, active = true))
        assertEquals(parseHexColor("#112233"), resolveBadgeBg(l, active = false))
    }

    @Test
    fun `an on entity with both colors set uses the ON background`() {
        val l = link("light.kitchen", bgColor = "#112233", bgColorOn = "#ffcc00")
        assertEquals(parseHexColor("#ffcc00"), resolveBadgeBg(l, active = true))
    }

    @Test
    fun `an off entity with both colors set falls back to the base background`() {
        val l = link("light.kitchen", bgColor = "#112233", bgColorOn = "#ffcc00")
        assertEquals(parseHexColor("#112233"), resolveBadgeBg(l, active = false))
    }

    @Test
    fun `stale or unknown active never uses the ON background`() {
        val l = link("light.kitchen", bgColor = "#112233", bgColorOn = "#ffcc00")
        assertEquals(parseHexColor("#112233"), resolveBadgeBg(l, active = null))
    }

    @Test
    fun `neither color set falls back to BadgeDefaultBg`() {
        val l = link("light.kitchen")
        assertEquals(BadgeDefaultBg, resolveBadgeBg(l, active = true))
        assertEquals(BadgeDefaultBg, resolveBadgeBg(l, active = false))
        assertEquals(BadgeDefaultBg, resolveBadgeBg(l, active = null))
    }

    @Test
    fun `only bg_color_on set, entity off, falls back to BadgeDefaultBg`() {
        val l = link("light.kitchen", bgColorOn = "#ffcc00")
        assertEquals(BadgeDefaultBg, resolveBadgeBg(l, active = false))
    }
}
