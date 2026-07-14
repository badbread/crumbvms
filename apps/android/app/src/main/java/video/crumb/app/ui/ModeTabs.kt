// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.draw.drawBehind
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextSecondary
import video.crumb.app.ui.theme.TimelineColors

/** The top-level modes that share the same tab row. */
enum class CrumbMode { LIVE, PLAYBACK, CLIPS, PLATES }

/**
 * The shared top "Live | Playback | Clips | Plates" tab row used across all
 * top-level screens. Rendering the identical row on every screen (with only the
 * selected underline moving) makes switching modes read as a TAB SWITCH rather
 * than "opening another page". Each mode has its own selected color:
 * - Live: teal (the app accent)
 * - Playback: amber (the timeline playhead hue, matching the desktop client)
 * - Clips: purple
 * - Plates: red (matches the `license_plate` detection-icon color elsewhere)
 *
 * Tabs can be hidden via [showPlayback] / [showClips] / [showPlates] for roles
 * that lack those capabilities — callers read from [SecureStore.capabilities]
 * (and, for Plates, [SecureStore.platesEnabled]) and pass the flags. The
 * already-selected tab is a no-op (callers pass `{}`).
 */
@Composable
fun CrumbModeTabs(
    selected: CrumbMode,
    onLive: () -> Unit,
    onPlayback: () -> Unit,
    onClips: () -> Unit = {},
    onPlates: () -> Unit = {},
    /** Hide the Playback tab (viewer lacks playback capability). */
    showPlayback: Boolean = true,
    /** Hide the Clips tab (viewer lacks clips capability). */
    showClips: Boolean = true,
    /** Hide the Plates tab (LPR disabled server-wide, or viewer lacks `view_plates`). */
    showPlates: Boolean = true,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(24.dp),
        verticalAlignment = Alignment.CenterVertically,
        // Small phones can't fit Live+Playback+Clips+Plates without squeezing a
        // label onto two lines (seen with "Plates"); scroll sideways instead of
        // wrapping. maxLines=1 on each label (below) is the actual wrap-prevention —
        // this just lets the (wider-than-the-screen) row overflow gracefully.
        modifier = modifier
            .padding(start = 4.dp)
            .horizontalScroll(rememberScrollState()),
    ) {
        ModeTab("Live", selected == CrumbMode.LIVE, TealAccent, onLive)
        if (showPlayback) {
            ModeTab("Playback", selected == CrumbMode.PLAYBACK, TimelineColors.playhead, onPlayback)
        }
        if (showClips) {
            ModeTab("Clips", selected == CrumbMode.CLIPS, Color(0xFFB07CD8), onClips)
        }
        if (showPlates) {
            ModeTab("LPR", selected == CrumbMode.PLATES, TimelineColors.eventPlate, onPlates)
        }
    }
}

@Composable
private fun ModeTab(
    label: String,
    isSelected: Boolean,
    selectedColor: Color,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val base = Modifier
        .padding(vertical = 4.dp)
        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
    if (isSelected) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = base.drawBehind {
                val sw = 2.dp.toPx()
                val y = size.height - sw / 2f
                drawLine(
                    color = selectedColor,
                    start = Offset(0f, y),
                    end = Offset(size.width, y),
                    strokeWidth = sw,
                )
            },
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.titleMedium,
                color = selectedColor,
                maxLines = 1,
            )
        }
    } else {
        Text(
            text = label,
            style = MaterialTheme.typography.titleMedium,
            color = TextSecondary,
            maxLines = 1,
            modifier = base,
        )
    }
}
