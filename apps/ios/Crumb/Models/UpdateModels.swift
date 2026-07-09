// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// `GET /updates/latest` response (any authenticated user). Mirrors the
/// server-mediated GitHub-release version check described in
/// `docs/UPDATE-SYSTEM-PLAN.md` §2.1 — every field except `enabled` is
/// optional even when `enabled == true` (the server may not have completed a
/// successful GitHub fetch yet). `enabled == false` means the operator turned
/// the check off server-side: every other field is null and nothing should
/// be shown. A 404 (older server, no endpoint at all) is handled by the
/// caller, not this type — see `UpdateChecker`.
struct UpdateStatus: Decodable {
    let enabled: Bool
    let latestVersion: String?
    let notesUrl: String?
    let publishedAt: String?
    /// Server's own build version — used by the web console's banner, not by
    /// this client (macOS/iOS compares `latestVersion` against its own
    /// `CFBundleShortVersionString` instead). Kept for DTO parity.
    let serverVersion: String?
    /// Whether the SERVER has an update available (web-console concern only).
    let serverUpdateAvailable: Bool?
    let checkedAt: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case latestVersion = "latest_version"
        case notesUrl = "notes_url"
        case publishedAt = "published_at"
        case serverVersion = "server_version"
        case serverUpdateAvailable = "server_update_available"
        case checkedAt = "checked_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        notesUrl = try c.decodeIfPresent(String.self, forKey: .notesUrl)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion)
        serverUpdateAvailable = try c.decodeIfPresent(Bool.self, forKey: .serverUpdateAvailable)
        checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt)
    }
}
