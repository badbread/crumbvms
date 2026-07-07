// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val CrumbColorScheme = darkColorScheme(
    primary = BlueAccent,
    onPrimary = TextPrimary,
    secondary = TealAccent,
    onSecondary = NavyDeep,
    background = NavyDeep,
    onBackground = TextPrimary,
    surface = NavySurface,
    onSurface = TextPrimary,
    surfaceVariant = NavySurfaceVariant,
    onSurfaceVariant = TextSecondary,
    error = DangerRed,
    onError = TextPrimary,
)

/** App theme — always dark (an NVR operator UI is dark by design). */
@Composable
fun CrumbTheme(
    @Suppress("UNUSED_PARAMETER") darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = CrumbColorScheme,
        typography = CrumbTypography,
        content = content,
    )
}
