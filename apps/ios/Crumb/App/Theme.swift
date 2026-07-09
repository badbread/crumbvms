// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

enum CrumbColors {
    static let background = Color(hex: 0x121212)
    static let surface = Color(hex: 0x1E1E1E)
    static let surfaceVariant = Color(hex: 0x2C2C2C)
    static let teal = Color(hex: 0x009688)
    static let tealAccent = Color(hex: 0x4DB6AC)
    /// "On / enabled" switch tint. A bright, unmistakably-positive green — the
    /// dark `teal` reads too close in luminance to the gray off-track to signal
    /// "on" at switch scale.
    static let positive = Color(hex: 0x4CAF50)
    static let recDot = Color(hex: 0xFF1744)
    static let motionDot = Color(hex: 0xFFAB00)
    static let timelineGreen = Color(hex: 0x4CAF50)
    static let timelineMotion = Color(hex: 0xFF5252)
    static let bookmarkGold = Color(hex: 0xFFD700)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.7)
    static let textTertiary = Color.white.opacity(0.5)
    static let divider = Color.white.opacity(0.12)
    static let error = Color(hex: 0xCF6679)
}

enum DetectionColors {
    static let person = Color(hex: 0x34AADC)
    static let face = Color(hex: 0xAF52DE)
    static let vehicleRoad = Color(hex: 0xFF9500)
    static let vehicleOther = Color(hex: 0xFF6B22)
    static let twoWheeler = Color(hex: 0xFFCC00)
    static let animalPet = Color(hex: 0x34C759)
    static let animalWild = Color(hex: 0x30B0C7)
    static let animalFarm = Color(hex: 0xA8C84A)
    static let delivery = Color(hex: 0xA5825A)
    static let sports = Color(hex: 0x5856D6)
    static let food = Color(hex: 0xFF2D55)
    static let household = Color(hex: 0x64748B)
    static let personalItem = Color(hex: 0xC0A062)
    static let misc = Color(hex: 0x8E8E93)
    static let generic = Color(hex: 0x8E8E93)
}

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}
