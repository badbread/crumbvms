// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable

/**
 * Wraps any button (icon button, etc.) in a Material3 [TooltipBox] so a
 * **tap-and-hold (long-press)** pops a small plain-text hint describing what the
 * button does. On touch devices `PlainTooltip` is triggered by a long-press by
 * default (and by mouse-hover on devices that have a pointer), which is exactly the
 * "press and hold to learn what this does" affordance we want app-wide.
 *
 * Usage:
 * ```
 * HintTooltip("Fullscreen") {
 *     IconButton(onClick = { ... }) { Icon(...) }
 * }
 * ```
 *
 * Keeping this as one tiny wrapper means every icon button in the app gets a
 * discoverable hint by wrapping it, without each call site re-deriving the
 * tooltip plumbing. The wrapped content keeps its own click handling; the tooltip
 * is purely additive.
 *
 * @param text The short hint shown on long-press (e.g. "Export footage").
 * @param content The button (or other anchor) the hint is attached to.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HintTooltip(
    text: String,
    content: @Composable () -> Unit,
) {
    val tooltipState = rememberTooltipState()
    TooltipBox(
        positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = { PlainTooltip { Text(text) } },
        state = tooltipState,
    ) {
        content()
    }
}
