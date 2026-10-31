// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import video.crumb.app.ui.theme.NavySurfaceVariant
import video.crumb.app.ui.theme.TextPrimary

/**
 * The one chip used for view selectors, the Latest pill, Clips type filters and the
 * LPR active-filter strip (polish pass G3 / L2 / C1 / R3).
 *
 * Filled (no outline), 8 dp radius, [accent] at 20% behind accent text when selected.
 * Selection animates: colours tween over 200 ms and the leading check expands from
 * 0 to 18 dp instead of popping in. [compact] is the 28 dp variant for filter strips.
 */
@Composable
fun CrumbFilterChip(
    selected: Boolean,
    onClick: () -> Unit,
    label: String,
    accent: Color,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val container by animateColorAsState(
        targetValue = if (selected) accent.copy(alpha = 0.20f) else NavySurfaceVariant,
        animationSpec = tween(200),
        label = "chipContainer",
    )
    val content by animateColorAsState(
        targetValue = if (selected) accent else TextPrimary.copy(alpha = 0.85f),
        animationSpec = tween(200),
        label = "chipContent",
    )
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AnimatedVisibility(
                    visible = selected,
                    enter = expandHorizontally(tween(200)) + fadeIn(tween(200)),
                    exit = shrinkHorizontally(tween(200)) + fadeOut(tween(120)),
                ) {
                    Icon(
                        imageVector = Icons.Default.Check,
                        contentDescription = null,
                        modifier = Modifier.size(if (compact) 16.dp else 18.dp),
                        tint = content,
                    )
                }
                Text(
                    text = label,
                    style = MaterialTheme.typography.labelMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        },
        modifier = modifier.height(if (compact) 28.dp else 32.dp),
        shape = MaterialTheme.shapes.small,
        border = null,
        colors = FilterChipDefaults.filterChipColors(
            containerColor = container,
            selectedContainerColor = container,
            labelColor = content,
            selectedLabelColor = content,
        ),
    )
}
