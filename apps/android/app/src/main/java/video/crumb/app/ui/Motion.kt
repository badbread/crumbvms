// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import kotlinx.coroutines.delay

/** Items beyond this index appear instantly (stagger is for the first screenful). */
internal const val STAGGER_MAX_ITEMS = 8
internal const val STAGGER_STEP_MS = 30L

/**
 * Delay before list item [index] starts to appear (G6): 30 ms per item, capped at
 * [STAGGER_MAX_ITEMS]. Returns null for items past the cap, which should not animate.
 */
internal fun staggerDelayMs(index: Int): Long? =
    if (index < 0 || index >= STAGGER_MAX_ITEMS) null else index * STAGGER_STEP_MS

/**
 * First-load stagger for list and grid items (G6): fade in and rise 8 dp over 200 ms
 * after [staggerDelayMs]. Items past the cap are left alone. Pair with
 * `Modifier.animateItem()` for reorders and removals.
 */
fun Modifier.staggerIn(index: Int): Modifier {
    val delayMs = staggerDelayMs(index) ?: return this
    return composed {
        val p = remember { Animatable(0f) }
        LaunchedEffect(Unit) {
            delay(delayMs)
            p.animateTo(1f, tween(200, easing = EaseOutCubic))
        }
        graphicsLayer {
            alpha = p.value
            translationY = (1f - p.value) * 8.dp.toPx()
        }
    }
}

/**
 * Dialog entry (G5): scale 0.9 to 1 with a fade over 180 ms, ease-out. Apply to the
 * dialog's surface, e.g. `AlertDialog(modifier = Modifier.dialogEntrance(), ...)`.
 */
fun Modifier.dialogEntrance(): Modifier = composed {
    val p = remember { Animatable(0f) }
    LaunchedEffect(Unit) { p.animateTo(1f, tween(180, easing = EaseOutCubic)) }
    graphicsLayer {
        val v = p.value
        alpha = v
        val s = 0.9f + 0.1f * v
        scaleX = s
        scaleY = s
    }
}

/** Sets the platform dim behind the enclosing Dialog window (V1 wants 60%). */
@Composable
fun DialogScrim(dimAmount: Float) {
    val view = LocalView.current
    LaunchedEffect(view, dimAmount) {
        (view.parent as? DialogWindowProvider)?.window?.setDimAmount(dimAmount)
    }
}
