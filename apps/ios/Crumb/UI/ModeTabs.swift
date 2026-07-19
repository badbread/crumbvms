// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

// MARK: - Mode

/// The top-level camera viewing modes shared across screens. iOS uses the first
/// three as pill tabs (Settings is a gear button, Export a per-clip action);
/// macOS surfaces all five as a desktop top-nav, matching the Tauri client.
enum Mode: String, CaseIterable {
    case live
    case playback
    case plates
    case exports
    case clips
    case settings
}

// MARK: - ModeTabs

/// Pill-shaped tab row used at the top of camera screens.
struct ModeTabs: View {
    @Binding var mode: Mode
    var tabs: [Mode] = [.live, .playback, .clips]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                ModeTab(label: t.label, tag: t, mode: $mode)
            }
        }
        .background(
            Capsule()
                .strokeBorder(CrumbColors.teal, lineWidth: 1.5)
                .background(Capsule().fill(CrumbColors.surfaceVariant))
        )
    }
}

extension Mode {
    var label: String {
        switch self {
        case .live: return "Live"
        case .playback: return "Playback"
        case .plates: return "LPR"
        case .exports: return "Exports"
        case .clips: return "Clips"
        case .settings: return "Settings"
        }
    }

    /// SF Symbol used by the macOS desktop top-nav.
    var icon: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .playback: return "clock.arrow.circlepath"
        case .plates: return "car.fill"
        case .exports: return "square.and.arrow.up"
        case .clips: return "film.stack"
        case .settings: return "gearshape"
        }
    }

    /// Per-tab accent color, matching the Android client (each mode owns a color so
    /// switching tabs reads as a context change, not "another page").
    var tabColor: Color {
        switch self {
        case .live: return Color(hex: 0x5E9BD6)      // blue (Android TealAccent)
        case .playback: return Color(hex: 0xE8A33D)  // amber (timeline playhead)
        case .plates: return Color(hex: 0x46B3B0)    // teal-cyan (LPR)
        case .exports: return Color(hex: 0x4FB477)   // green
        case .clips: return Color(hex: 0xB07CD8)     // purple (Android Clips)
        case .settings: return Color(hex: 0x9AA7B5)  // slate
        }
    }
}

// MARK: - Private tab button

private struct ModeTab: View {
    let label: String
    let tag: Mode
    @Binding var mode: Mode

    private var isActive: Bool { mode == tag }

    var body: some View {
        Button {
            guard mode != tag else { return }
            withAnimation(.easeInOut(duration: 0.18)) { mode = tag }
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(isActive ? .black : CrumbColors.teal)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isActive ? CrumbColors.teal : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}

#if DEBUG
#Preview {
    struct Preview: View {
        @State private var mode: Mode = .live
        var body: some View {
            ZStack {
                CrumbColors.background.ignoresSafeArea()
                ModeTabs(mode: $mode)
            }
        }
    }
    return Preview()
}
#endif
