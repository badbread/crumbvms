// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui

import androidx.compose.material3.SwitchColors
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.Composable
import video.crumb.app.ui.theme.NavySurfaceVariant
import video.crumb.app.ui.theme.TealAccent
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary

/**
 * Shared [SwitchColors] so every toggle in the app reads the same: a teal (the
 * app accent) track with a light thumb when ON. The Material 3 default checked
 * track is the theme `primary` (amber here), which clashed with a teal thumb —
 * the "orange outside / blue circle" look. Use this everywhere a [androidx.compose.material3.Switch]
 * is shown so toggles stay consistent with the chips/radios/tabs.
 */
@Composable
fun crumbSwitchColors(): SwitchColors = SwitchDefaults.colors(
    checkedThumbColor = TextPrimary,
    checkedTrackColor = TealAccent,
    checkedBorderColor = TealAccent,
    uncheckedThumbColor = TextSecondary,
    uncheckedTrackColor = NavySurfaceVariant,
    uncheckedBorderColor = NavySurfaceVariant,
)
