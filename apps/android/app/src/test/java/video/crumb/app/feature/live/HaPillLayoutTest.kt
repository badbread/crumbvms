// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import video.crumb.app.data.HaLinkDto

/**
 * Pill LAYOUT (`overlay_pill_width` / `overlay_text_align`, migration 0078,
 * issue #497) — the Android sibling of the desktop
 * `apps/desktop-flutter/test/ha_pill_layout_test.dart`.
 *
 * The contract only pays off if all four renderers agree, so these pin the
 * three things an Android change could break on its own:
 *
 *  1. an older server (fields absent) decodes to null, which is today's
 *     rendering byte-for-byte — the same guarantee `HaBadgeMetricsTest` makes
 *     for the auto path, restated against the DTO;
 *  2. a fixed mode is an EXACT multiple of the badge height, and is NOT widened
 *     to fit its content the way `auto` is (PR #499's fix stays scoped to
 *     `auto`) — that exactness is what lets several badges line up;
 *  3. an unrecognized value from a newer server degrades to `auto` rather than
 *     inventing a width.
 *
 * Pure, headless math plus one JSON decode; no Compose, no device.
 */
class HaPillLayoutTest {

    private val json = Json { ignoreUnknownKeys = true }

    private val heights: List<Float> = (8..40).map { it.toFloat() }

    private val labels = listOf("A", "Floodlight", "Back garden floodlight")

    @Test
    fun `an older server payload decodes both fields as null`() {
        val dto = json.decodeFromString<HaLinkDto>(
            """{"id":"l","entity_id":"binary_sensor.front","role":"sensor"}""",
        )
        assertNull(dto.overlayPillWidth)
        assertNull(dto.overlayTextAlign)
    }

    @Test
    fun `present values round-trip verbatim`() {
        val dto = json.decodeFromString<HaLinkDto>(
            """{"id":"l","entity_id":"binary_sensor.front","role":"sensor",
               "overlay_pill_width":"medium","overlay_text_align":"center"}""",
        )
        assertEquals("medium", dto.overlayPillWidth)
        assertEquals("center", dto.overlayTextAlign)
    }

    @Test
    fun `auto and null carry no factor - the pill measures its content`() {
        assertNull(HaBadgeMetrics.pillWidthFactor(null))
        assertNull(HaBadgeMetrics.pillWidthFactor("auto"))
    }

    @Test
    fun `the three fixed modes are exact height multiples`() {
        assertEquals(4f, HaBadgeMetrics.pillWidthFactor("narrow"))
        assertEquals(6f, HaBadgeMetrics.pillWidthFactor("medium"))
        assertEquals(8f, HaBadgeMetrics.pillWidthFactor("wide"))
    }

    @Test
    fun `an unknown mode from a newer server degrades to auto`() {
        // Never guess at a vocabulary this build has not shipped.
        for (bad in listOf("", "AUTO", "huge", "fixed", "8", "wide ")) {
            assertNull(bad, HaBadgeMetrics.pillWidthFactor(bad))
        }
    }

    @Test
    fun `the frozen vocabulary all resolves to a real factor`() {
        // services/api/src/ha.rs HA_PILL_WIDTH_MODES. Every non-auto member must
        // produce a width, or the console could author something Android drops.
        for (mode in listOf("narrow", "medium", "wide")) {
            assertNotNull(mode, HaBadgeMetrics.pillWidthFactor(mode))
        }
    }

    @Test
    fun `a fixed pill width is exactly its factor times the height`() {
        for (h in heights) {
            for (label in labels) {
                for ((mode, factor) in listOf(
                    "narrow" to 4f,
                    "medium" to 6f,
                    "wide" to 8f,
                )) {
                    assertEquals(
                        "h=$h mode=$mode label='$label'",
                        factor * h,
                        HaBadgeMetrics.pillWidth(h, label, mode),
                        1e-3f,
                    )
                }
            }
        }
    }

    @Test
    fun `a fixed pill width does not move with the label - badges line up`() {
        val h = 22f
        for (mode in listOf("narrow", "medium", "wide")) {
            val short = HaBadgeMetrics.pillWidth(h, "A", mode)
            val long = HaBadgeMetrics.pillWidth(h, "Back garden floodlight", mode)
            assertEquals(mode, short, long, 1e-4f)
        }
        // ...whereas auto very much does, which is what auto means (and is the
        // fit-the-content behavior PR #499 landed; nothing here weakens it).
        assertTrue(
            HaBadgeMetrics.pillWidth(h, "A") <
                HaBadgeMetrics.pillWidth(h, "Back garden floodlight"),
        )
    }

    @Test
    fun `auto width is untouched by the new parameter`() {
        for (h in heights) {
            for (label in labels) {
                val bare = HaBadgeMetrics.pillWidth(h, label)
                assertEquals(bare, HaBadgeMetrics.pillWidth(h, label, null), 1e-4f)
                assertEquals(bare, HaBadgeMetrics.pillWidth(h, label, "auto"), 1e-4f)
            }
        }
    }
}
