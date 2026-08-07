// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import kotlin.math.max
import kotlin.math.min

/**
 * Pure sizing math for the on-video Home Assistant badges.
 *
 * The desktop client is the source of truth for how a badge's `overlay_size`
 * maps to glyph / container / text proportions
 * (`apps/desktop-flutter/lib/ui/ha_overlay/ha_overlay_layer.dart`, `HaBadgeChip`
 * plus its caption builder). Everything here is a straight port of that math so
 * a badge authored on desktop reads the same on the phone.
 *
 * The rule the pill layout has to honor: **every part of the badge derives from
 * the same height**, and the container derives from the icon + label, never the
 * other way round. Android used to break that in three places, which is what
 * made a small pill's label spill past its rounded background (v0.2.0 live
 * testing):
 *
 *  1. the pill's box width came from a char-count heuristic evaluated against
 *     the *nominal* font size, while the label actually rendered at the
 *     *clamped* font size — below ~14dp of badge height the icon + padding +
 *     label no longer fit the box at all;
 *  2. the horizontal padding (6dp) and the icon/label gap (4dp) were fixed
 *     constants instead of fractions of the height, and the icon had no minimum
 *     while the label did — so at small sizes a floored label sat next to a
 *     vanishing icon;
 *  3. the label/caption `Text`s overrode only `fontSize`, inheriting the app
 *     theme's `bodyLarge` **lineHeight of 22sp**, so the text's line box did not
 *     shrink with the badge at all.
 *
 * All lengths are dp (the desktop's logical px); font sizes are dp too and the
 * composable converts them with the current density, so the badge keeps the
 * operator-authored geometry regardless of the phone's font-scale setting (the
 * badge is a scale drawing of a scene, not body copy).
 */
internal object HaBadgeMetrics {
    /** Reference badge height (dp) at scale 1.0 and pane-scale 1.0. */
    const val BASE_REF_DP = 22f

    /** Pane short side (dp) that maps to pane-scale 1.0. */
    const val REF_SHORT_SIDE = 320f

    /** Never render a badge smaller than this, at any scale. */
    const val MIN_BADGE_DP = 8f

    /** Labels longer than this ellipsize (matches the desktop width estimate). */
    private const val MAX_LABEL_CHARS = 16

    /**
     * Mean glyph advance as a fraction of the font size, used only to size the
     * pill so the label fits. Deliberately generous for a semibold sans; the
     * label still ellipsizes if a particular string measures wider.
     */
    private const val GLYPH_ADVANCE_EM = 0.62f

    /** Pane-scale for a `paneW` x `paneH` pane (dp) — desktop `overlay_geometry`. */
    fun paneScale(paneW: Float, paneH: Float): Float =
        (min(paneW, paneH) / REF_SHORT_SIDE).coerceIn(0.5f, 3.0f)

    /**
     * Badge height (dp) for a link's `overlay_size` at [paneScale]. The scale is
     * clamped to the same 0.1..8.0 band the desktop controller clamps to, so a
     * bogus value from the API cannot produce a badge the size of the pane.
     */
    fun badgeHeight(overlaySize: Float?, paneScale: Float): Float =
        (BASE_REF_DP * (overlaySize ?: 1f).coerceIn(0.1f, 8.0f) * paneScale)
            .coerceAtLeast(MIN_BADGE_DP)

    // ── Pill parts — desktop `_pill(height)`. ────────────────────────────────

    /**
     * Icon side (dp). Desktop clamps to 10..40; the extra `coerceAtMost(height)`
     * only bites when the badge itself is under 10dp, where the desktop floor
     * would be taller than the chip it sits in.
     */
    fun pillIconSize(height: Float): Float =
        (height * 0.56f).coerceIn(10f, 40f).coerceAtMost(height)

    /** Label size (dp). */
    fun pillFontSize(height: Float): Float = (height * 0.40f).coerceIn(8f, 26f)

    /** Horizontal padding inside the pill (dp), each side. */
    fun pillPadH(height: Float): Float = (height * 0.28f).coerceIn(5f, 16f)

    /** Gap between the icon and the label (dp). */
    fun pillGap(height: Float): Float = (height * 0.14f).coerceIn(3f, 8f)

    /**
     * The pill box the desktop authoring UI persists (`HaOverlayBadgeItem
     * .baseSize()`): `(baseRef * 1.5 + chars * baseRef * 0.42) * scale`,
     * rewritten in terms of the height (`height = baseRef * scale`).
     */
    fun nominalPillWidth(height: Float, label: String): Float =
        height * (1.5f + 0.42f * labelChars(label))

    /** Width (dp) the icon + gap + label + padding actually need. */
    fun pillContentWidth(height: Float, label: String): Float =
        2f * pillPadH(height) +
            pillIconSize(height) +
            pillGap(height) +
            labelWidth(height, label)

    /**
     * A FIXED pill width as a multiple of the pill's HEIGHT (migration 0078,
     * issue #497), or null for `auto` — and for any value this build does not
     * know, which degrades to today's content-derived width rather than
     * guessing at a newer server's vocabulary.
     *
     * Height is the unit deliberately: it is the one length desktop, Android
     * and iOS already derive identically from `overlay_size` and the pane
     * scale, so `medium` is the same pill everywhere. A pixel width would be
     * three different pills on three different panes.
     *
     * The vocabulary is frozen and shared: `services/api/src/ha.rs`'s
     * `HA_PILL_WIDTH_MODES`, the desktop `haPillWidthFactor`, the iOS
     * `HA.pillWidthFactor`, and the console's width `<select>`.
     */
    fun pillWidthFactor(mode: String?): Float? = when (mode) {
        "narrow" -> 4f
        "medium" -> 6f
        "wide" -> 8f
        else -> null // "auto", null, or anything unrecognized
    }

    /**
     * The rendered pill width (dp): the desktop-authored footprint, widened when
     * the (clamped) icon + label would not fit inside it. This is the fix for
     * the overflow — the container is derived from the content, never assumed to
     * be big enough for it.
     *
     * A FIXED [widthMode] short-circuits all of that: the pill is EXACTLY that
     * multiple of its height, deliberately NOT widened to fit, because an
     * operator who asked for four pills the same width gets four pills the same
     * width and an over-long label ellipsizes (which the chip already does).
     * That exactness is the whole point of the mode, and it is also what keeps
     * the four renderers agreeing on a number.
     */
    fun pillWidth(height: Float, label: String, widthMode: String? = null): Float {
        val factor = pillWidthFactor(widthMode)
        if (factor != null) return factor * height
        return max(nominalPillWidth(height, label), pillContentWidth(height, label))
    }

    /** Estimated rendered label width (dp) at this badge height. */
    fun labelWidth(height: Float, label: String): Float =
        labelChars(label) * pillFontSize(height) * GLYPH_ADVANCE_EM

    // ── Dot — desktop `_dot(side)`. ──────────────────────────────────────────

    /** Icon side (dp) inside a dot badge of side [side]. */
    fun dotIconSize(side: Float): Float =
        (side * 0.58f).coerceIn(10f, 40f).coerceAtMost(side)

    // ── Pinned caption below the badge — desktop `_captionFor`. ──────────────

    fun captionFontSize(height: Float): Float = (height * 0.42f).coerceIn(8f, 13f)

    fun captionPadH(height: Float): Float = (height * 0.16f).coerceIn(4f, 8f)

    fun captionPadV(height: Float): Float = (height * 0.08f).coerceIn(2f, 4f)

    /** Gap (dp) between the badge and its caption. */
    fun captionGap(height: Float): Float = (height * 0.14f).coerceIn(2f, 6f)

    // ── In-flight spinner — desktop `_withPendingOverlay`. ───────────────────

    fun spinnerSize(width: Float, height: Float): Float =
        (min(width, height) * 0.52f).coerceIn(10f, 22f)

    private fun labelChars(label: String): Int =
        label.length.coerceIn(1, MAX_LABEL_CHARS)
}
