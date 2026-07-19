// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Deterministic per-camera color for the playback timeline's motion ribbons +
/// legend, ported verbatim from the desktop client
/// (`apps/desktop-flutter/lib/ui/motion_timeline/camera_colors.dart`). Cameras
/// have no color field, so the color is derived from the (stable) camera UUID via
/// FNV-1a — the SAME camera maps to the SAME color on every client, independent
/// of list/fetch order, so the two clients' timelines never drift apart.
enum CameraColors {

    /// Hand-picked, maximally-separated 12-color palette (deliberately red-free —
    /// red reads as alarm/record on the timeline, not routine motion). Must stay
    /// byte-identical to `kCameraColorPalette` on desktop so the modulo agrees.
    static let palette: [Color] = [
        Color(hex: 0x4C9AFF), // blue
        Color(hex: 0xFF8A3D), // orange
        Color(hex: 0x2FCF6F), // green
        Color(hex: 0xFFD23F), // yellow
        Color(hex: 0xB57BEF), // purple
        Color(hex: 0x17D5E6), // cyan
        Color(hex: 0xFF7FB2), // pink
        Color(hex: 0x9CD323), // lime
        Color(hex: 0x7C6CFF), // indigo
        Color(hex: 0x12B58A), // teal
        Color(hex: 0xE08A5A), // coral
        Color(hex: 0xD65DB1), // magenta
    ]

    /// FNV-1a 32-bit hash — matches the desktop `fnv1a32` exactly (a camera UUID
    /// is ASCII, so unicode scalars == the Dart code units it hashes).
    static func fnv1a32(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811c_9dc5
        for scalar in s.unicodeScalars {
            h ^= (scalar.value & 0xFF) // UUID chars are single-byte; mask for safety
            h = h &* 0x0100_0193
        }
        return h
    }

    /// Stable motion color for a camera id (deterministic palette index). Manual
    /// per-camera overrides (desktop's right-click legend recolor) are a follow-up.
    static func motionColor(_ cameraId: String?) -> Color {
        guard let id = cameraId, !id.isEmpty else { return Color(hex: 0x4C9AFF).opacity(0.5) }
        return palette[Int(fnv1a32(id) % UInt32(palette.count))]
    }
}
