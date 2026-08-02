// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [haTypeLabel] — the "Type" row value in the HA more-info popup.
 * Mirrors the desktop client's `_deviceTypeLabel`/`_humanize`
 * (`apps/desktop-flutter/lib/ui/ha_overlay/ha_state_card.dart`): humanized
 * `device_class` when present, else humanized `domain`, so the row is never
 * blank.
 */
class HaTypeLabelTest {

    @Test
    fun `humanizes device_class when present`() {
        // cover.garage with device_class garage_door -> "Garage door".
        assertEquals("Garage door", haTypeLabel("cover", "garage_door"))
        assertEquals("Motion", haTypeLabel("binary_sensor", "motion"))
    }

    @Test
    fun `falls back to humanized domain when device_class absent`() {
        // light.front_island_light (no device_class) -> "Light".
        assertEquals("Light", haTypeLabel("light", null))
        // Domains with underscores humanize too.
        assertEquals("Input boolean", haTypeLabel("input_boolean", null))
    }

    @Test
    fun `blank device_class falls back to domain`() {
        assertEquals("Switch", haTypeLabel("switch", ""))
        assertEquals("Switch", haTypeLabel("switch", "   "))
    }

    @Test
    fun `capitalizes only the first letter`() {
        // Underscores become spaces; interior words are NOT title-cased, matching
        // the desktop _humanize (first letter only).
        assertEquals("Carbon monoxide", haTypeLabel("sensor", "carbon_monoxide"))
    }
}
