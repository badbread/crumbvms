// SPDX-License-Identifier: AGPL-3.0-or-later

#if os(macOS)
import SwiftUI

/// Desktop-style top navigation bar for macOS — a horizontal row of tabs with an
/// accent underline on the active item, mirroring the Tauri desktop client's
/// top bar. iOS uses the pill-shaped `ModeTabs` instead.
struct MacTopNav: View {
    @Binding var mode: Mode
    let tabs: [Mode]

    var body: some View {
        HStack(spacing: 0) {
            // Brand lockup — icon + "Crumb" wordmark stacked over a dimmer "VMS"
            // edition tag, matching the web/desktop/Android clients.
            HStack(spacing: 9) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 26)
                VStack(alignment: .leading, spacing: -1) {
                    Text("Crumb")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(CrumbColors.textPrimary)
                        .tracking(0.4)
                    Text("VMS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(CrumbColors.textTertiary)
                        .tracking(1.5)
                }
            }
            .padding(.trailing, 16)

            // Vertical rule separating the brand from the tabs.
            Rectangle()
                .fill(CrumbColors.divider)
                .frame(width: 1, height: 26)
                .padding(.trailing, 8)

            ForEach(tabs, id: \.self) { tab in
                MacNavTab(mode: $mode, tag: tab)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(CrumbColors.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CrumbColors.divider).frame(height: 1)
        }
    }
}

private struct MacNavTab: View {
    @Binding var mode: Mode
    let tag: Mode

    private var isActive: Bool { mode == tag }

    var body: some View {
        Button {
            if mode != tag { withAnimation(.easeInOut(duration: 0.15)) { mode = tag } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tag.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(tag.label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(isActive ? tag.tabColor : CrumbColors.textSecondary)
            .padding(.horizontal, 15)
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? tag.tabColor : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
