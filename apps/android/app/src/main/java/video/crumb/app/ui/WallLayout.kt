// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.filled.ViewModule
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Camera-wall grid density: how many tiles across. Shared by BOTH the Live wall and
 * the Playback wall so the control — its options, its per-option icon, and the
 * selected value — is identical across modes. The selection persists in
 * `SecureStore.liveGridLayout` (one shared density for both walls).
 *
 * Single big tile uses a stacked-cards icon (NOT a plain square — that reads as the
 * fullscreen control); 2/3/4 climb in visible density.
 */
enum class WallGridLayout(val label: String, val cols: Int, val icon: ImageVector) {
    ONE("1 across", 1, Icons.Default.ViewAgenda),
    TWO("2 across", 2, Icons.Default.GridView),
    THREE("3 across", 3, Icons.Default.ViewModule),
    FOUR("4 across", 4, Icons.Default.Apps),
}

/**
 * The grid-density app-bar action: shows the CURRENT density's icon and cycles to the
 * next on tap. Drop this in as the first action on both walls so the picker looks and
 * sits the same in Live and Playback.
 *
 * [maxCols] caps the densest option for the current orientation — portrait passes 3
 * (4-across tiles are uselessly tiny on a phone in portrait), landscape passes 4. If
 * the saved density exceeds the cap (a 4-across set in landscape, then rotated to
 * portrait), it's shown clamped to the densest allowed and cycling stays within the
 * allowed set — the saved value isn't overwritten until the user actually taps.
 */
@Composable
fun GridLayoutToggle(layout: WallGridLayout, maxCols: Int, onChange: (WallGridLayout) -> Unit) {
    val allowed = WallGridLayout.entries.filter { it.cols <= maxCols }
    val effective = if (layout in allowed) layout else allowed.last()
    HintTooltip("Grid density: ${effective.label} (tap to change)") {
        IconButton(
            onClick = {
                onChange(allowed[(allowed.indexOf(effective) + 1) % allowed.size])
            },
        ) {
            Icon(
                imageVector = effective.icon,
                contentDescription = "Grid density: ${effective.label}",
            )
        }
    }
}
