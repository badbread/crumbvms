// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Cross-camera bookmark list — every saved playback moment, newest first.
///
/// Tapping a row calls `onOpen(cameraId, date)` so the parent can open
/// single-camera playback at that instant. Swipe-to-delete presents a
/// confirmation alert before committing the server delete.
struct BookmarksView: View {

    @StateObject private var vm: BookmarksViewModel

    /// Called when the user taps a row. The parent owns the navigation.
    let onOpen: (String, Date) -> Void

    init(container: AppContainer, onOpen: @escaping (String, Date) -> Void) {
        _vm = StateObject(wrappedValue: BookmarksViewModel(container: container))
        self.onOpen = onOpen
    }

    // Confirmation state for swipe-to-delete.
    @State private var pendingDelete: BookmarkDto? = nil

    var body: some View {
        ZStack {
            CrumbColors.background.ignoresSafeArea()

            if vm.isLoading && vm.bookmarks.isEmpty {
                ProgressView()
                    .tint(CrumbColors.tealAccent)
            } else if let err = vm.error, vm.bookmarks.isEmpty {
                errorBanner(err)
            } else if vm.bookmarks.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Bookmarks")
        .navBarInline()
        .task {
            await vm.load()
        }
        .alert("Delete bookmark?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let bm = pendingDelete else { return }
                pendingDelete = nil
                Task { await vm.delete(bm) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let bm = pendingDelete {
                let label = bm.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                let display = (label?.isEmpty ?? true) ? "No description" : label!
                Text(display)
            }
        }
    }

    // MARK: - Subviews

    private var list: some View {
        List {
            if let err = vm.error {
                Text(err)
                    .foregroundColor(CrumbColors.error)
                    .font(.caption)
                    .listRowBackground(CrumbColors.surface)
            }

            ForEach(vm.bookmarks) { bm in
                BookmarkRow(bookmark: bm)
                    .listRowBackground(CrumbColors.surface)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Parse with the fractional-seconds-tolerant helper; fall
                        // back to "now" so a tap is never silently swallowed.
                        let date = parseISO8601(bm.ts) ?? Date()
                        onOpen(bm.cameraId, date)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = bm
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .background(CrumbColors.background)
        .scrollContentBackground(.hidden)
        .refreshable {
            await vm.refresh()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 44))
                .foregroundColor(CrumbColors.textTertiary)
            Text("No bookmarks yet")
                .foregroundColor(CrumbColors.textSecondary)
                .font(.headline)
            Text("Add one from a camera's playback.")
                .foregroundColor(CrumbColors.textTertiary)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundColor(CrumbColors.error)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await vm.load() }
            }
            .foregroundColor(CrumbColors.tealAccent)
        }
        .padding(32)
    }
}

// MARK: - BookmarkRow

private struct BookmarkRow: View {

    let bookmark: BookmarkDto

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var formattedDate: String {
        guard let date = parseISO8601(bookmark.ts) else {
            return bookmark.ts
        }
        return Self.dateFormatter.string(from: date)
    }

    private var isProtected: Bool {
        guard let until = bookmark.protectUntil,
              let date = parseISO8601(until) else {
            return false
        }
        return date > Date()
    }

    private var protectUntilFormatted: String? {
        guard let until = bookmark.protectUntil,
              let date = parseISO8601(until),
              date > Date() else {
            return nil
        }
        return Self.dateFormatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(bookmark.cameraName ?? "Camera")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(CrumbColors.tealAccent)

                    Text(formattedDate)
                        .font(.caption)
                        .foregroundColor(CrumbColors.textSecondary)

                    if isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(CrumbColors.textTertiary)
                    }
                }

                let desc = bookmark.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Text(desc.isEmpty ? "No description" : desc)
                    .font(.subheadline)
                    .foregroundColor(desc.isEmpty ? CrumbColors.textTertiary : CrumbColors.textPrimary)
                    .lineLimit(2)

                if let until = protectUntilFormatted {
                    Text("Protected until \(until)")
                        .font(.caption2)
                        .foregroundColor(CrumbColors.bookmarkGold)
                }
            }
            .padding(.vertical, 12)

            Spacer(minLength: 8)
        }
    }
}
