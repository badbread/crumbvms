// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import video.crumb.app.R

// CrumbVMS "The Trail" brand fonts.
//   Space Grotesk — display + UI.
//   JetBrains Mono — data, timestamps, camera IDs, durations (the "forensic" set).
val SpaceGrotesk = FontFamily(Font(R.font.space_grotesk))
val JetBrainsMono = FontFamily(Font(R.font.jetbrains_mono))

// Weights tuned for a dense operator UI; family set to Space Grotesk.
val CrumbTypography = Typography(
    headlineMedium = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.SemiBold, fontSize = 24.sp, lineHeight = 30.sp),
    titleLarge = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, lineHeight = 26.sp),
    titleMedium = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Medium, fontSize = 16.sp, lineHeight = 22.sp),
    bodyLarge = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp),
    labelLarge = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 18.sp),
    // G9: chips / buttons (13/16 medium) and captions (12/16) now have their own roles
    // instead of borrowing sizes from the M3 defaults.
    labelMedium = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 16.sp),
    bodySmall = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp),
    labelSmall = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Medium, fontSize = 11.sp, lineHeight = 14.sp),
)

/**
 * Mono "data" roles (G9): timestamps, durations, plates, addresses. Same bundled
 * JetBrains Mono the LPR screens already use; no new font.
 */
val Typography.mono: TextStyle
    get() = TextStyle(fontFamily = JetBrainsMono, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 16.sp)

/** Smaller mono for captions (clip durations, counts, the clip player caption). */
val Typography.monoCaption: TextStyle
    get() = TextStyle(fontFamily = JetBrainsMono, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp)

/** Mono at an explicit size, for the few badges that are smaller than a caption. */
fun monoStyle(size: TextUnit, lineHeight: TextUnit = size * 1.3f): TextStyle =
    TextStyle(fontFamily = JetBrainsMono, fontWeight = FontWeight.Normal, fontSize = size, lineHeight = lineHeight)
