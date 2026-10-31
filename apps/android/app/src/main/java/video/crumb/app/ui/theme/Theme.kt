// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp

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

/**
 * One shape scale (G8): tiles and chips 8, cards 12, dialogs and sheets 28.
 * Badges are full pills (CircleShape) and buttons stay M3's full pill.
 */
val CrumbShapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp),
    extraLarge = RoundedCornerShape(28.dp),
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
        shapes = CrumbShapes,
        content = content,
    )
}
