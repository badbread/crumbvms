// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Drives `BookmarksView`. Loads the full cross-camera bookmark list from the
/// server (newest first) and exposes delete. Pull-to-refresh is wired via the
/// `refresh()` entry-point that SwiftUI's `refreshable` modifier calls.
@MainActor
final class BookmarksViewModel: ObservableObject {

    @Published var bookmarks: [BookmarkDto] = []
    @Published var isLoading = false
    @Published var error: String?

    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        error = nil
        do {
            let raw = try await container.api.bookmarks()
            // Sort newest-first using the ISO8601 ts string (lexicographic order
            // works for RFC-3339 strings with consistent UTC offset).
            bookmarks = raw.sorted { $0.ts > $1.ts }
        } catch {
            self.error = error.userMessage
        }
        isLoading = false
    }

    /// Entry-point for SwiftUI's `refreshable` pull-to-refresh.
    func refresh() async {
        await load()
    }

    // MARK: - Delete

    func delete(_ bookmark: BookmarkDto) async {
        do {
            try await container.api.deleteBookmark(id: bookmark.id)
            bookmarks.removeAll { $0.id == bookmark.id }
        } catch {
            self.error = error.userMessage
        }
    }

    /// Convenience called from swipe-to-delete `IndexSet`.
    func delete(at offsets: IndexSet) async {
        // Collect the bookmarks to remove before mutating the array.
        let targets = offsets.map { bookmarks[$0] }
        for bm in targets {
            await delete(bm)
        }
    }
}
