// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression tests for the HA badge scaling math — the Android sibling of the
 * desktop `apps/desktop-flutter/test/ha_badge_scale_test.dart`.
 *
 * The bug these pin down (found on a Galaxy S24 during v0.2.0 live testing): a
 * pill badge's label rendered LARGER than the pill it sat in, spilling past the
 * rounded background, while the same badge at the same `overlay_size` was fine
 * on desktop. The badge box came from a char-count estimate evaluated against
 * the un-clamped font size, but the label rendered at the CLAMPED font size, so
 * once the badge got small (a phone pane is small in dp, so its pane-scale and
 * therefore its badges are small) the icon + padding + label no longer fit.
 *
 * Everything below is pure, headless, deterministic math — no Compose, no
 * device. The sweep covers badge heights 8..40dp, the range a phone actually
 * produces for the console's 0.5x..3x size slider.
 */
class HaBadgeMetricsTest {

    private val heights: List<Float> = (8..40).map { it.toFloat() }

    private val labels = listOf(
        "A",
        "Floodlight",
        "patio door",
        "Front Door Sensor",
        "WWWWWWWWWWWWWWWWWWWW",
    )

    // ── The bug: the container must be derived from its contents. ────────────

    @Test
    fun `pill is always wide enough for its icon, gap, padding and label`() {
        for (h in heights) {
            for (label in labels) {
                val w = HaBadgeMetrics.pillWidth(h, label)
                val need = HaBadgeMetrics.pillContentWidth(h, label)
                assertTrue(
                    "pill h=$h label='$label' width=$w < content=$need",
                    w >= need - 1e-4f,
                )
            }
        }
    }

    @Test
    fun `the old nominal-only width was too narrow for a small pill`() {
        // Documents WHY pillWidth takes the max: at a phone-sized badge the
        // desktop-authored footprint alone is narrower than the chip's own
        // contents. If this ever stops being true the max() is harmless, but
        // the assertion is what makes the fix legible.
        val h = 12f
        assertTrue(
            HaBadgeMetrics.nominalPillWidth(h, "Floodlight") <
                HaBadgeMetrics.pillContentWidth(h, "Floodlight"),
        )
        // ...and at a comfortable size the authored footprint still wins, so a
        // badge that already looked right keeps its exact geometry.
        val big = 30f
        assertEquals(
            HaBadgeMetrics.nominalPillWidth(big, "Floodlight"),
            HaBadgeMetrics.pillWidth(big, "Floodlight"),
            1e-4f,
        )
    }

    @Test
    fun `label never needs more room than the pill grants it`() {
        for (h in heights) {
            for (label in labels) {
                val room = HaBadgeMetrics.pillWidth(h, label) -
                    2f * HaBadgeMetrics.pillPadH(h) -
                    HaBadgeMetrics.pillIconSize(h) -
                    HaBadgeMetrics.pillGap(h)
                assertTrue(
                    "no label room at h=$h label='$label' (room=$room)",
                    room >= HaBadgeMetrics.labelWidth(h, label) - 1e-4f,
                )
            }
        }
    }

    // ── Nothing may overflow vertically either. ──────────────────────────────

    @Test
    fun `icons never exceed the badge box`() {
        for (h in heights) {
            assertTrue("pill icon > h at $h", HaBadgeMetrics.pillIconSize(h) <= h + 1e-4f)
            assertTrue("dot icon > side at $h", HaBadgeMetrics.dotIconSize(h) <= h + 1e-4f)
        }
    }

    @Test
    fun `label line box fits the pill height`() {
        // The label's line height is set to its font size (desktop `height: 1.0`),
        // so this is the whole vertical story: font <= badge height at any size.
        for (h in heights) {
            assertTrue(
                "font ${HaBadgeMetrics.pillFontSize(h)} > h=$h",
                HaBadgeMetrics.pillFontSize(h) <= h + 1e-4f,
            )
        }
    }

    // ── Desktop parity: the exact fractions and clamps of `_pill(height)`. ───

    @Test
    fun `pill parts match the desktop fractions and clamps`() {
        // desktop: icon .56 clamp 10..40, font .40 clamp 8..26,
        //          padH .28 clamp 5..16, gap .14 clamp 3..8
        assertEquals(11.2f, HaBadgeMetrics.pillIconSize(20f), 1e-4f)
        assertEquals(8f, HaBadgeMetrics.pillFontSize(20f), 1e-4f) // at the floor
        assertEquals(5.6f, HaBadgeMetrics.pillPadH(20f), 1e-4f)
        assertEquals(3f, HaBadgeMetrics.pillGap(20f), 1e-4f) // clamped up

        assertEquals(22.4f, HaBadgeMetrics.pillIconSize(40f), 1e-4f)
        assertEquals(16f, HaBadgeMetrics.pillFontSize(40f), 1e-4f)
        assertEquals(11.2f, HaBadgeMetrics.pillPadH(40f), 1e-4f)
        assertEquals(5.6f, HaBadgeMetrics.pillGap(40f), 1e-4f)

        // Upper clamps bite on a very large badge, exactly as on desktop.
        assertEquals(40f, HaBadgeMetrics.pillIconSize(200f), 1e-4f)
        assertEquals(26f, HaBadgeMetrics.pillFontSize(200f), 1e-4f)
        assertEquals(16f, HaBadgeMetrics.pillPadH(200f), 1e-4f)
        assertEquals(8f, HaBadgeMetrics.pillGap(200f), 1e-4f)
    }

    @Test
    fun `dot icon matches the desktop fraction`() {
        assertEquals(17.4f, HaBadgeMetrics.dotIconSize(30f), 1e-4f) // .58
        assertEquals(40f, HaBadgeMetrics.dotIconSize(100f), 1e-4f) // clamped
        assertEquals(10f, HaBadgeMetrics.dotIconSize(12f), 1e-4f) // floor
    }

    @Test
    fun `caption text and chrome scale with the badge`() {
        // desktop: state .42 clamp 8..13, padH .16 clamp 4..8, padV .08 clamp 2..4
        assertEquals(12.6f, HaBadgeMetrics.captionFontSize(30f), 1e-4f)
        assertEquals(13f, HaBadgeMetrics.captionFontSize(40f), 1e-4f)
        assertEquals(8f, HaBadgeMetrics.captionFontSize(10f), 1e-4f)
        assertEquals(4.8f, HaBadgeMetrics.captionPadH(30f), 1e-4f)
        assertEquals(4f, HaBadgeMetrics.captionPadH(10f), 1e-4f)
        assertEquals(2.4f, HaBadgeMetrics.captionPadV(30f), 1e-4f)
        assertEquals(4f, HaBadgeMetrics.captionPadV(60f), 1e-4f)
    }

    @Test
    fun `caption is not wildly out of proportion with a small dot`() {
        // The reported "tiny icon under a huge caption": a caption fixed at 9sp
        // with fixed padding beside an unclamped icon. Now both are bounded
        // fractions of the same height, so the caption's text can never be more
        // than ~1.6x the icon it labels.
        for (h in heights) {
            val ratio = HaBadgeMetrics.captionFontSize(h) / HaBadgeMetrics.dotIconSize(h)
            assertTrue("caption/icon ratio $ratio at h=$h", ratio <= 1.6f)
        }
    }

    // ── Scale -> height, and the shape-invariant. ────────────────────────────

    @Test
    fun `badge height is the scale times the reference, floored and clamped`() {
        assertEquals(22f, HaBadgeMetrics.badgeHeight(1.0f, 1.0f), 1e-4f)
        assertEquals(33f, HaBadgeMetrics.badgeHeight(1.5f, 1.0f), 1e-4f)
        assertEquals(24.75f, HaBadgeMetrics.badgeHeight(1.5f, 0.75f), 1e-4f)
        // A missing overlay_size is 1.0.
        assertEquals(22f, HaBadgeMetrics.badgeHeight(null, 1.0f), 1e-4f)
        // Floor: never smaller than MIN_BADGE_DP, whatever the scale.
        assertEquals(
            HaBadgeMetrics.MIN_BADGE_DP,
            HaBadgeMetrics.badgeHeight(0.01f, 0.5f),
            1e-4f,
        )
        // The desktop controller clamps overlay_size to 0.1..8.0; Android used
        // to take it raw, so a bogus value made a pane-sized badge on the phone
        // and a clamped one on the desktop.
        assertEquals(
            HaBadgeMetrics.badgeHeight(8f, 1f),
            HaBadgeMetrics.badgeHeight(99f, 1f),
            1e-4f,
        )
    }

    @Test
    fun `everything grows monotonically with the badge height`() {
        for (h in heights) {
            val next = h + 1f
            assertTrue(HaBadgeMetrics.pillIconSize(next) >= HaBadgeMetrics.pillIconSize(h))
            assertTrue(HaBadgeMetrics.pillFontSize(next) >= HaBadgeMetrics.pillFontSize(h))
            assertTrue(HaBadgeMetrics.pillPadH(next) >= HaBadgeMetrics.pillPadH(h))
            assertTrue(HaBadgeMetrics.pillGap(next) >= HaBadgeMetrics.pillGap(h))
            assertTrue(HaBadgeMetrics.dotIconSize(next) >= HaBadgeMetrics.dotIconSize(h))
            assertTrue(HaBadgeMetrics.captionFontSize(next) >= HaBadgeMetrics.captionFontSize(h))
            assertTrue(
                HaBadgeMetrics.pillWidth(next, "Floodlight") >=
                    HaBadgeMetrics.pillWidth(h, "Floodlight"),
            )
        }
    }

    @Test
    fun `a pill is wider than it is tall`() {
        // Mirrors the desktop test's shape-invariant assertion.
        val h = 22f
        assertTrue(HaBadgeMetrics.pillWidth(h, "Front Door") > h)
    }

    @Test
    fun `pane scale is the short side over the reference, clamped`() {
        assertEquals(1f, HaBadgeMetrics.paneScale(640f, 320f), 1e-4f)
        assertEquals(0.5f, HaBadgeMetrics.paneScale(100f, 100f), 1e-4f)
        assertEquals(3f, HaBadgeMetrics.paneScale(4000f, 2000f), 1e-4f)
    }

    @Test
    fun `spinner stays proportional on a wide pill`() {
        // Keyed on the SHORT side (desktop `_withPendingOverlay`) so a long pill
        // does not get a spinner the width of the badge.
        assertEquals(10.4f, HaBadgeMetrics.spinnerSize(200f, 20f), 1e-4f)
        assertEquals(22f, HaBadgeMetrics.spinnerSize(80f, 80f), 1e-4f)
    }
}
