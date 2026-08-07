// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.live

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import video.crumb.app.data.HaLinkDto
import video.crumb.app.ui.player.ZoomableVideoSurface

/**
 * The badge TOUCH contract, exercised through real Compose hit-testing.
 *
 * [HaBadgeMetricsTest] proves the numbers; this proves the composable actually
 * hands those numbers to a hit box. The two halves have to be checked together:
 * the chip sizes ITSELF from [HaBadgeMetrics] and the tap/long-press
 * `combinedClickable` sits on a wrap-content parent, so a chip that measured to
 * nothing (or a gesture modifier that ended up on the wrong node) would still
 * DRAW a plausible badge while silently swallowing every touch. That failure
 * mode is invisible to a pure-geometry test and to a screenshot; it needs an
 * injected touch, which is why this runs as a Compose UI test under Robolectric
 * rather than as another plain unit test.
 *
 * What is asserted:
 *  1. a placed badge contributes EXACTLY ONE clickable node (the drawn chip IS
 *     the tappable node, not a sibling of it);
 *  2. that node measures the footprint [HaBadgeMetrics.pillWidth] promises, and
 *     is at least [HaBadgeMetrics.badgeHeight] tall, so the edge clamp and the
 *     touch target agree with what is drawn;
 *  3. tap and long-press both fire, including over the live video surface and
 *     including a jittery press (a real finger drifts a few px between down and
 *     up) - which is what would expose the zoom/pan detector underneath
 *     stealing the gesture;
 *  4. every geometry in the authored range stays tappable, at any placement.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], qualifiers = "w800dp-h480dp-land")
class HaBadgeTouchTargetTest {
    @get:Rule
    val rule = createComposeRule()

    private val base = HaLinkDto(
        id = "l1",
        entityId = "light.porch",
        role = "actuator",
        label = "Porch light",
        overlayX = 0.4,
        overlayY = 0.4,
        overlaySize = 1.0,
        overlayShape = "pill",
        overlayShowState = true,
        overlayShowAge = true,
    )

    private val link = mutableStateOf(base)
    private val taps = mutableListOf<String>()
    private val longPresses = mutableListOf<String>()

    // Pane size in dp, read back from the composition: what `paneScale` sees.
    private var paneW = 0f
    private var paneH = 0f

    /** The layer over a live video surface - the real fullscreen stacking order. */
    private fun setContent(overVideo: Boolean = true) {
        rule.setContent {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                if (overVideo) {
                    ZoomableVideoSurface(modifier = Modifier.fillMaxSize(), onSwipeCamera = {}) {
                        Box(Modifier.fillMaxSize().background(Color.DarkGray))
                    }
                }
                HaBadgeOverlayLayer(
                    links = listOf(link.value),
                    states = null,
                    videoWidth = 1920,
                    videoHeight = 1080,
                    onBadgeTap = { taps += it.id },
                    onBadgeLongPress = { longPresses += it.id },
                )
            }
        }
        val root = rule.onRoot().fetchSemanticsNode().size
        paneW = root.width / rule.density.density
        paneH = root.height / rule.density.density
    }

    private fun badgeNode() = rule.onAllNodes(hasClickAction())[0]

    private fun badgeNodes() = rule.onAllNodes(hasClickAction()).fetchSemanticsNodes()

    @Test
    fun aPlacedBadgeIsExactlyOneClickableNode() {
        setContent()
        assertEquals("a placed badge must be one clickable node", 1, badgeNodes().size)
    }

    /**
     * The hit box is the drawn footprint. `badgeSize()` widens a pill to whatever
     * its icon + label actually need, and the edge clamp and the touch target both
     * have to use that widened width, not the narrower authored one.
     */
    @Test
    fun theHitBoxIsTheDrawnFootprint() {
        setContent()
        val ps = HaBadgeMetrics.paneScale(paneW, paneH)
        val h = HaBadgeMetrics.badgeHeight(base.overlaySize!!.toFloat(), ps)
        val w = HaBadgeMetrics.pillWidth(h, base.displayName)
        val b = badgeNodes()[0].boundsInRoot
        val widthDp = b.width / rule.density.density
        val heightDp = b.height / rule.density.density
        assertEquals("hit-box width must be HaBadgeMetrics.pillWidth", w, widthDp, 1f)
        assertTrue(
            "hit box ($heightDp dp) must be at least the badge height ($h dp)",
            heightDp >= h - 1f,
        )
    }

    @Test
    fun tapFires() {
        setContent()
        badgeNode().performClick()
        rule.waitForIdle()
        assertEquals(listOf("l1"), taps)
    }

    @Test
    fun longPressFires() {
        setContent()
        badgeNode().performTouchInput { longClick() }
        rule.waitForIdle()
        assertEquals(listOf("l1"), longPresses)
    }

    @Test
    fun dotBadgeTapFires() {
        link.value = base.copy(overlayShape = "dot")
        setContent()
        badgeNode().performClick()
        rule.waitForIdle()
        assertEquals(listOf("l1"), taps)
    }

    /**
     * A real finger drifts between down and up. The pan/zoom detector on the
     * video surface underneath consumes position changes, so a badge that had
     * lost its own hit box would hand the gesture to the surface and look inert.
     */
    @Test
    fun aJitteryTapOverTheVideoSurfaceStillFires() {
        setContent()
        badgeNode().performTouchInput {
            down(center)
            moveBy(Offset(2f, 1f))
            moveBy(Offset(1f, 2f))
            up()
        }
        rule.waitForIdle()
        assertEquals(listOf("l1"), taps)
    }

    @Test
    fun aJitteryLongPressOverTheVideoSurfaceStillFires() {
        setContent()
        badgeNode().performTouchInput {
            down(center)
            moveBy(Offset(2f, 2f), delayMillis = 60)
            advanceEventTime(700)
            moveBy(Offset(1f, 0f))
            up()
        }
        rule.waitForIdle()
        assertEquals(listOf("l1"), longPresses)
    }

    /**
     * Every authored geometry stays tappable: both shapes, the whole clamped
     * `overlay_size` band and past both ends of it, label lengths either side of
     * the ellipsize cap, and placements in the corners where the edge clamp bites.
     */
    @Test
    fun everyGeometryInTheAuthoredRangeStaysTappable() {
        setContent(overVideo = false)
        val failures = mutableListOf<String>()
        val sizes = listOf(0.05, 0.1, 0.4, 1.0, 2.5, 8.0, 20.0)
        val labels = listOf("A", "Porch light", "Back yard flood lights XL")
        val shapes = listOf("dot", "pill")
        val spots = listOf(0.0 to 0.0, 0.5 to 0.5, 0.99 to 0.99)
        for (s in sizes) for (lbl in labels) for (shape in shapes) for ((x, y) in spots) {
            val what = "size=$s shape=$shape labelLen=${lbl.length} at ($x,$y)"
            taps.clear()
            link.value = base.copy(
                overlaySize = s, overlayShape = shape, label = lbl, overlayX = x, overlayY = y,
            )
            rule.waitForIdle()
            val nodes = badgeNodes()
            if (nodes.size != 1) {
                failures += "$what -> ${nodes.size} clickable nodes"
                continue
            }
            val b = nodes[0].boundsInRoot
            if (b.width <= 0f || b.height <= 0f) {
                failures += "$what -> empty hit box $b"
                continue
            }
            badgeNode().performClick()
            rule.waitForIdle()
            if (taps != listOf("l1")) failures += "$what -> not tappable (hit box $b)"
        }
        assertTrue(
            "badges that swallowed their tap:\n" + failures.joinToString("\n"),
            failures.isEmpty(),
        )
    }
}
