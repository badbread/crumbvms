// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

extension URLSession {
    /// Shared session for tokenized media (camera frames, clip thumbnails, scrub
    /// stills). These URLs carry the auth token as a `?token=` query param, so they
    /// must never land in the on-disk URL cache. An ephemeral configuration keeps
    /// an in-memory cache (so per-request cache policies still help performance)
    /// but persists nothing — including the token — to disk.
    static let crumbMedia: URLSession = URLSession(configuration: .ephemeral)
}

/// [both] H2 fix: a drop-in `AsyncImage` replacement for tokened (`?token=`)
/// media URLs. SwiftUI's `AsyncImage` has no way to plug in a custom
/// `URLSession` — it always uses `URLSession.shared`, whose default disk URL
/// cache would persist the tokened URL (and thus the auth token) to disk. This
/// fetches via the ephemeral `.crumbMedia` session instead, mirroring the
/// existing manual-fetch pattern used by `ClipThumbnail` (Features/Clips/ClipsView.swift).
///
/// `failure` defaults to `placeholder` when omitted, so simple call sites can
/// use the 2-parameter form (`content` + `placeholder`, like the old
/// `AsyncImage(url:content:placeholder:)`), while call sites that want a
/// distinct empty-state (e.g. "Preview unavailable" vs. a spinner) can pass all
/// three.
struct TokenedAsyncImage<Content: View, Placeholder: View, Failure: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var image: PlatformImage?
    @State private var failed = false

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        Group {
            if let image {
                content(Image(platformImage: image))
            } else if failed {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            await fetch()
        }
    }

    private func fetch() async {
        guard let url else { failed = true; return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.crumbMedia.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let img = PlatformImage(data: data)
        else {
            failed = true
            return
        }
        image = img
    }
}

extension TokenedAsyncImage where Failure == Placeholder {
    /// 2-parameter convenience: failure state renders the same as the placeholder.
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(url: url, content: content, placeholder: placeholder, failure: placeholder)
    }
}
