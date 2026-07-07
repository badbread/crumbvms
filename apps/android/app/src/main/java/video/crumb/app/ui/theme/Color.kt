// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.ui.theme

import androidx.compose.ui.graphics.Color

// CrumbVMS "The Trail" palette (mirrors the web/desktop clients). Names kept;
// values are charcoal/panel + a single warm amber accent + slate.
val Navy = Color(0xFF25272E)               // raised/nested panel (was navy)
val NavyDeep = Color(0xFF15161A)           // app background (charcoal)
val NavySurface = Color(0xFF1E2026)        // panel/card background
val NavySurfaceVariant = Color(0xFF2E313A) // input wells / track
val BlueAccent = Color(0xFFE8A33D)         // amber accent — the playhead / pin
val TealAccent = Color(0xFF5E9BD6)         // secondary/info accent
val TextPrimary = Color(0xFFE8E9ED)        // off-white
val TextSecondary = Color(0xFF8B93A1)      // slate-lite
val DangerRed = Color(0xFFE5484D)          // crumb-rec red

/**
 * Semantic colors for the playback timeline — CrumbVMS "The Trail".
 *
 * Mirrors the desktop client's TL palette exactly (app.js `const TL`): a slate
 * baseline where recording exists, a BLUE two-tone for motion (dim ribbon for
 * "something moved", bright azure cap for a strong/sustained event — we moved
 * motion AWAY from red), and the signature amber playhead (the "final pin").
 */
object TimelineColors {
    val recorded = Color(0xFF5B6472)       // (legacy) recording present — slate (desktop REC_BASE)
    val recording = Color(0xFF5B6472)      // baseline = recording present — slate (continuous)
    val motion = Color(0xFF4C9AFF)         // strong/sustained motion — bright azure cap (desktop MOTION)
    val motionLow = Color(0xFF2E5A9C)      // any-motion floor — medium blue ribbon (desktop MOTION_LOW)
    val motionBand = Color(0x332E5A9C)     // faint blue base band over recorded regions
    val track = Color(0xFF0E0F12)          // near-black canvas (desktop TRACK_BG) — makes blue motion pop
    val playhead = Color(0xFFE8A33D)       // amber playhead — the signature pin
    val grid = Color(0xFF33363F)           // hour/tick gridlines
    val bookmark = Color(0xFFF5C518)       // saved-bookmark markers (gold)

    // Detection-event icon colors (per icon_key, mirroring desktop + web clients).
    val eventPerson = Color(0xFF34AADC)    // blue circle
    val eventVehicle = Color(0xFFFF9500)   // amber square
    val eventCycle = Color(0xFFFF9500)     // amber diamond
    val eventAnimal = Color(0xFF34C759)    // green (distinct from person's blue)
    val eventPlate = Color(0xFFFF3B30)     // red square
    val eventFace = Color(0xFFAF52DE)      // purple circle
    val eventGeneric = Color(0xFF8E8E93)   // gray circle
}
