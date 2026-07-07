// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// "Add bookmark" sheet.
///
/// Shows description input, an opt-in "protect this clip" section with a days
/// picker (1 / 3 / 7 / 30) and pre/post second steppers (default 30 s / 60 s).
/// The caller receives the final values in `onSave` and owns the actual API
/// call + feedback.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showingAddBookmark) {
///     AddBookmarkDialog(atDate: currentDate) { desc, days, pre, post in
///         Task { await vm.createBookmark(...) }
///     }
/// }
/// ```
struct AddBookmarkDialog: View {

    /// The moment being bookmarked — displayed at the top for context.
    let atDate: Date
    /// Called on Save. `protectDays`, `preSeconds`, `postSeconds` are nil when
    /// protection is disabled.
    let onSave: (String, Int?, Int?, Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var protect = false
    @State private var selectedDays = 7
    @State private var preSeconds = 30
    @State private var postSeconds = 60

    private static let availableDays = [1, 3, 7, 30]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                CrumbColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        // Timestamp context
                        Text(Self.dateFormatter.string(from: atDate))
                            .font(.subheadline)
                            .foregroundColor(CrumbColors.textSecondary)

                        // Description
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description")
                                .font(.caption)
                                .foregroundColor(CrumbColors.textSecondary)

                            TextEditor(text: $description)
                                .frame(minHeight: 80)
                                .padding(8)
                                .background(CrumbColors.surfaceVariant)
                                .cornerRadius(8)
                                .foregroundColor(CrumbColors.textPrimary)
                                .font(.body)
                                // TextEditor has its own background; clip so the
                                // corner radius is visible.
                                .scrollContentBackground(.hidden)
                        }

                        // Protection toggle
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $protect) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Protect this clip")
                                        .foregroundColor(CrumbColors.textPrimary)
                                        .font(.subheadline.weight(.medium))
                                    Text("Prevents auto-delete for a set period.")
                                        .font(.caption)
                                        .foregroundColor(CrumbColors.textSecondary)
                                }
                            }
                            .tint(CrumbColors.teal)

                            if protect {
                                protectSection
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: protect)
                        .padding(12)
                        .background(CrumbColors.surface)
                        .cornerRadius(10)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Add Bookmark")
            .navBarInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(CrumbColors.tealAccent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
                        if protect {
                            onSave(trimmed, selectedDays, preSeconds, postSeconds)
                        } else {
                            onSave(trimmed, nil, nil, nil)
                        }
                        dismiss()
                    }
                    .foregroundColor(CrumbColors.tealAccent)
                    .fontWeight(.semibold)
                }
            }
        }
        .macModalSize(width: 460, height: 560)
    }

    // MARK: - Protection section

    private var protectSection: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Days picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Protect for")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)

                HStack(spacing: 8) {
                    ForEach(Self.availableDays, id: \.self) { days in
                        DayChip(
                            label: days == 1 ? "1 day" : "\(days) days",
                            selected: selectedDays == days
                        ) {
                            selectedDays = days
                        }
                    }
                }
            }

            Divider().background(CrumbColors.divider)

            // Pre seconds stepper
            LabeledStepper(
                label: "Clip before",
                value: $preSeconds,
                unit: "s",
                range: 5...300,
                step: 5
            )

            // Post seconds stepper
            LabeledStepper(
                label: "Clip after",
                value: $postSeconds,
                unit: "s",
                range: 5...300,
                step: 5
            )

            Text("Keeps \(preSeconds)s before + \(postSeconds)s after this moment protected from auto-delete.")
                .font(.caption)
                .foregroundColor(CrumbColors.textTertiary)
        }
    }
}

// MARK: - DayChip

private struct DayChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? CrumbColors.teal : CrumbColors.surfaceVariant)
                .foregroundColor(selected ? .white : CrumbColors.textSecondary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LabeledStepper

private struct LabeledStepper: View {
    let label: String
    @Binding var value: Int
    let unit: String
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(CrumbColors.textPrimary)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    let next = value - step
                    if next >= range.lowerBound { value = next }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(value > range.lowerBound ? CrumbColors.tealAccent : CrumbColors.textTertiary)
                        .font(.title3)
                }
                .disabled(value <= range.lowerBound)
                .buttonStyle(.plain)

                Text("\(value)\(unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(CrumbColors.textPrimary)
                    .frame(minWidth: 44, alignment: .center)

                Button {
                    let next = value + step
                    if next <= range.upperBound { value = next }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(value < range.upperBound ? CrumbColors.tealAccent : CrumbColors.textTertiary)
                        .font(.title3)
                }
                .disabled(value >= range.upperBound)
                .buttonStyle(.plain)
            }
        }
    }
}
