// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// "Jump to date & time" sheet.
///
/// Wraps the iOS native `DatePicker` in `.graphical` style with quick-jump
/// chips ("Now", "1h ago", "6h ago", "24h ago") above it, and Cancel / Jump
/// buttons in the navigation bar.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showingJump) {
///     JumpToDateTimeDialog(initial: currentDate) { date in
///         seek(to: date)
///     }
/// }
/// ```
struct JumpToDateTimeDialog: View {

    /// Pre-selected instant shown when the sheet opens.
    let initial: Date
    /// Called once when the user taps Jump. Not called on Cancel.
    let onJump: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selected: Date

    init(initial: Date, onJump: @escaping (Date) -> Void) {
        self.initial = initial
        self.onJump = onJump
        _selected = State(initialValue: initial)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                CrumbColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        // Quick-jump chips
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quick jump")
                                .font(.caption)
                                .foregroundColor(CrumbColors.textSecondary)
                                .padding(.horizontal, 2)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    QuickChip(label: "Now") {
                                        selected = Date()
                                    }
                                    QuickChip(label: "1h ago") {
                                        selected = Date().addingTimeInterval(-3600)
                                    }
                                    QuickChip(label: "6h ago") {
                                        selected = Date().addingTimeInterval(-6 * 3600)
                                    }
                                    QuickChip(label: "24h ago") {
                                        selected = Date().addingTimeInterval(-24 * 3600)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }

                        // Native graphical date+time picker (iOS 14+, no iOS 17 API used)
                        DatePicker(
                            "",
                            selection: $selected,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.graphical)
                        .tint(CrumbColors.teal)
                        .colorScheme(.dark)
                        // Remove the default label space that DatePicker adds even for
                        // an empty label.
                        .labelsHidden()
                        .padding(4)
                        .background(CrumbColors.surface)
                        .cornerRadius(12)

                        // Selected value readout
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(CrumbColors.tealAccent)
                            Text(formattedSelected)
                                .foregroundColor(CrumbColors.textPrimary)
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Jump to time")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(CrumbColors.tealAccent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Jump") {
                        onJump(selected)
                        dismiss()
                    }
                    .foregroundColor(CrumbColors.tealAccent)
                    .fontWeight(.semibold)
                }
            }
        }
        .macModalSize(width: 440, height: 480)
    }

    // MARK: - Helpers

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var formattedSelected: String {
        Self.formatter.string(from: selected)
    }
}

// MARK: - QuickChip

private struct QuickChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(CrumbColors.surfaceVariant)
                .foregroundColor(CrumbColors.tealAccent)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}
