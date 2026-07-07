// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

// MARK: - Editor target

/// Whether the editor is creating a new view or editing an existing one.
enum ViewEditorTarget {
    case new
    case edit(CameraView)
}

// MARK: - ViewEditorView

/// Full-screen sheet for creating or editing a named `CameraView`.
///
/// - Top bar: Cancel (X) on the left, title in the centre, Save on the right.
/// - Name field at the top.
/// - "Add cameras" section: cameras not yet in the view — tap to add.
/// - "In this view" section: cameras already selected — tap X to remove,
///   drag the handle to reorder.
/// - Delete button at the bottom when editing an existing view.
///
/// Parameters:
/// - `target`: `.new` or `.edit(existingView)`
/// - `allCameras`: All available cameras as `CameraDto` in wall order.
/// - `onSave`: Called with the finished `CameraView` (new UUID minted for `.new`).
/// - `onDelete`: Called with the view id when the user taps Delete.
/// - `onDismiss`: Called on Cancel without saving.
struct ViewEditorView: View {
    let target: ViewEditorTarget
    let allCameras: [CameraDto]
    let onSave: (CameraView) -> Void
    let onDelete: (String) -> Void
    let onDismiss: () -> Void

    // Stable id for the view being created/edited.
    private let viewId: String
    @State private var name: String
    @State private var selectedIds: [String]

    init(
        target: ViewEditorTarget,
        allCameras: [CameraDto],
        onSave: @escaping (CameraView) -> Void,
        onDelete: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.target = target
        self.allCameras = allCameras
        self.onSave = onSave
        self.onDelete = onDelete
        self.onDismiss = onDismiss

        if case .edit(let existing) = target {
            viewId = existing.id
            _name = State(initialValue: existing.name)
            _selectedIds = State(initialValue: existing.cameraIds)
        } else {
            viewId = UUID().uuidString
            _name = State(initialValue: "")
            _selectedIds = State(initialValue: [])
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selectedIds.isEmpty
    }

    private var nameById: [String: String] {
        Dictionary(uniqueKeysWithValues: allCameras.map { ($0.id, $0.name) })
    }

    // Cameras not yet in the view, in wall order.
    private var availableCameras: [CameraDto] {
        allCameras.filter { !selectedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CrumbColors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Name field
                        nameField

                        // Add cameras section
                        sectionHeader("Add cameras")
                        addSection

                        divider

                        // Selected cameras section
                        sectionHeader(
                            "In this view\(selectedIds.isEmpty ? "" : " (\(selectedIds.count))")"
                        )
                        selectedSection

                        // Delete button (edit mode only)
                        if isEditing {
                            deleteButton
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(12)
                }
            }
            .navBarInline()
            .toolbar { toolbarContent }
        }
        .macModalSize(width: 540, height: 680)
    }

    // MARK: - Subviews

    private var nameField: some View {
        TextField("View name", text: $name)
            .padding(12)
            .background(CrumbColors.surface)
            .cornerRadius(8)
            .foregroundColor(CrumbColors.textPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(CrumbColors.divider, lineWidth: 1)
            )
            .padding(.bottom, 16)
    }

    private var addSection: some View {
        Group {
            if availableCameras.isEmpty {
                Text("All cameras are in this view.")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(availableCameras) { cam in
                        Button {
                            selectedIds.append(cam.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus")
                                    .foregroundColor(CrumbColors.tealAccent)
                                Text(cam.name)
                                    .foregroundColor(CrumbColors.textPrimary)
                                    .font(.body)
                                Spacer()
                            }
                            .frame(height: 56)
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
    }

    private var selectedSection: some View {
        Group {
            if selectedIds.isEmpty {
                Text("Tap cameras above to add them.")
                    .font(.caption)
                    .foregroundColor(CrumbColors.textSecondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(selectedIds, id: \.self) { camId in
                        HStack(spacing: 12) {
                            // Drag handle
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(CrumbColors.textSecondary)

                            Text(nameById[camId] ?? "(removed camera)")
                                .foregroundColor(CrumbColors.textPrimary)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // Remove button
                            Button {
                                selectedIds.removeAll { $0 == camId }
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundColor(CrumbColors.textSecondary)
                                    .frame(width: 44, height: 44)
                            }
                        }
                        .frame(height: 56)
                        .padding(.horizontal, 4)
                        .background(CrumbColors.background)
                        .cornerRadius(6)
                    }
                    .onMove { from, to in
                        selectedIds.move(fromOffsets: from, toOffset: to)
                    }
                }
                // onMove only fires when the List is in edit mode; wrap in an
                // always-editing List so the drag handles work without a toolbar
                // Edit button.
                .alwaysEditing()
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if case .edit(let existing) = target {
                onDelete(existing.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                Text("Delete view")
            }
            .foregroundColor(CrumbColors.error)
        }
        .padding(.top, 24)
    }

    private var divider: some View {
        Rectangle()
            .fill(CrumbColors.surface)
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(CrumbColors.textSecondary)
            .padding(.bottom, 4)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .barLeading) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(CrumbColors.textPrimary)
            }
            .accessibilityLabel("Cancel")
        }

        ToolbarItem(placement: .principal) {
            Text(isEditing ? "Edit view" : "New view")
                .font(.headline)
                .foregroundColor(CrumbColors.textPrimary)
        }

        ToolbarItem(placement: .barTrailing) {
            Button("Save") {
                onSave(CameraView(
                    id: viewId,
                    name: name.trimmingCharacters(in: .whitespaces),
                    cameraIds: selectedIds
                ))
            }
            .foregroundColor(canSave ? CrumbColors.tealAccent : CrumbColors.textSecondary)
            .disabled(!canSave)
        }
    }
}
