// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Horizontally-scrollable row of view-selector chips.
///
/// Layout: "All" pill (always first) · one pill per saved view · "+ New" pill (always last).
/// The active chip is tinted with `CrumbColors.tealAccent`; inactive chips use the
/// surface colour with secondary-text labels.
///
/// - `views`: Saved views in display order.
/// - `activeId`: Binding to the currently-active view id (`nil` = "All cameras").
/// - `onCreate`: Called when the user taps the "+ New" chip.
/// - `onEdit`: Called when the user long-presses an existing view chip.
struct ViewChipsView: View {
    let views: [CameraView]
    @Binding var activeId: String?
    /// Whether to show the built-in "All cameras" chip (a per-device setting —
    /// operators who work from saved Views can hide the aggregate).
    var showAll: Bool = true
    let onCreate: () -> Void
    let onEdit: (CameraView) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // "All" chip
                if showAll {
                    chip(
                        label: "All",
                        isActive: activeId == nil
                    ) {
                        activeId = nil
                    }
                }

                // One chip per saved view; long-press opens editor.
                ForEach(views) { view in
                    chip(
                        label: view.name,
                        icon: view.layout?.icon,
                        isActive: activeId == view.id
                    ) {
                        activeId = view.id
                    }
                    .contextMenu {
                        Button {
                            onEdit(view)
                        } label: {
                            Label("Edit \"\(view.name)\"", systemImage: "pencil")
                        }
                    }
                    .simultaneousGesture(
                        LongPressGesture().onEnded { _ in onEdit(view) }
                    )
                }

                // "+ New" chip
                Button(action: onCreate) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                        Text("New")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(CrumbColors.tealAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(CrumbColors.surface)
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(CrumbColors.tealAccent.opacity(0.5), lineWidth: 1)
                    )
                }
                .accessibilityLabel("New view")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Chip builder

    private func chip(label: String, icon: String? = nil, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.caption2)
                }
                Text(label)
                    .font(.caption)
                    .fontWeight(isActive ? .semibold : .regular)
            }
                .foregroundColor(isActive ? CrumbColors.tealAccent : CrumbColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? CrumbColors.tealAccent.opacity(0.15) : CrumbColors.surface)
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            isActive ? CrumbColors.tealAccent : CrumbColors.divider,
                            lineWidth: 1
                        )
                )
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let views: [CameraView] = [
        CameraView(id: "1", name: "Inside", cameraIds: ["a"]),
        CameraView(id: "2", name: "Outside", cameraIds: ["b", "c"]),
    ]
    return ZStack {
        CrumbColors.background.ignoresSafeArea()
        ViewChipsView(
            views: views,
            activeId: .constant("1"),
            onCreate: {},
            onEdit: { _ in }
        )
    }
}
#endif
