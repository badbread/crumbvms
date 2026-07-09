// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Shared macOS + iOS update-available checker (`docs/UPDATE-SYSTEM-PLAN.md`
/// task C4). ONE implementation for both targets: compares the server's
/// reported `latest_version` (`GET /updates/latest`) against this build's own
/// `CFBundleShortVersionString`, and drives the dismissible Settings-area
/// notice plus the "Check now" affordance (§2.5). Never touches footage or
/// the recorder; the only network call is the existing authed
/// `CrumbAPI.updatesLatest`, which itself talks only to this app's own
/// server (the server, not the client, contacts GitHub — §1/D2).
///
/// iOS ships this only because it's the same shared Swift code as macOS
/// (issue #7, decision D5) — iOS is explicitly the LOWEST-priority client
/// here: once the app is TestFlight/App-Store distributed, the platform's
/// own update flow supersedes this notice, and this checker could be
/// feature-flagged off for iOS at that point without touching macOS.
@MainActor
final class UpdateChecker: ObservableObject {

    /// Re-check at most this often while the app keeps running (§3: "at most
    /// every 24h"). A fresh login/launch still calls `checkIfNeeded()`, which
    /// itself no-ops if the last attempt was inside this window.
    private static let recheckInterval: TimeInterval = 24 * 60 * 60

    /// Swapped in place by `AppContainer.rebuildApi()` on a server-URL
    /// change. This object's own identity stays stable across that (unlike
    /// `AppContainer.api`/`mediaTokens`, which are replaced wholesale) so a
    /// view's `@ObservedObject` binding to it never goes stale.
    var api: CrumbAPI

    private let defaults: UserDefaults

    /// Last response from the server, or `nil` if never checked, the check
    /// is disabled, or the server 404s (no endpoint at all — an older
    /// server). Every read of "should we show something" goes through the
    /// derived properties below, never this raw value directly.
    @Published private(set) var status: UpdateStatus?
    @Published private(set) var lastCheckedAt: Date?

    init(api: CrumbAPI, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
    }

    private var ownVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The version the user last dismissed the banner for. Persisted so the
    /// dismissal survives relaunch; stays quiet until a NEWER version shows
    /// up (§3), at which point `bannerVersion` no longer matches it.
    private var dismissedVersion: String? {
        get { defaults.string(forKey: Keys.dismissedVersion) }
        set { defaults.set(newValue, forKey: Keys.dismissedVersion) }
    }

    private var lastAttemptAt: Date? {
        get { defaults.object(forKey: Keys.lastAttemptAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastAttemptAt) }
    }

    /// The version to show a banner for, or `nil` if nothing should be
    /// shown: the check is disabled, there's no newer version, this build's
    /// own version doesn't parse (unparsable ⇒ never show, §2.2), or the
    /// user already dismissed this exact version.
    var bannerVersion: String? {
        guard let status, status.enabled,
              let latest = status.latestVersion,
              SemVer.isNewer(latest, than: ownVersion),
              latest != dismissedVersion
        else { return nil }
        return latest
    }

    /// Release-notes link for the current banner version, opened in the
    /// platform browser (never in-app — this is a notify-only notice).
    var notesURL: URL? {
        status?.notesUrl.flatMap { URL(string: $0) }
    }

    /// "Check now" (§2.5) is offered only while the last known response says
    /// the operator has the check enabled — never while disabled or before
    /// the first successful check.
    var canCheckNow: Bool { status?.enabled ?? false }

    /// Plain-language status line for the Settings card when there's no
    /// banner to show, e.g. "Checked just now, you're up to date." (§2.5).
    var statusText: String {
        guard let lastCheckedAt else { return "Not checked yet." }
        if Date().timeIntervalSince(lastCheckedAt) < 60 {
            return "Checked just now, you're up to date."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: lastCheckedAt, relativeTo: Date())
        return "Checked \(relative), you're up to date."
    }

    /// Check once after login/launch, throttled to at most every 24h. Call
    /// from `AppContainer.applyUser(_:)`, which itself runs exactly once per
    /// successful login and once per launch (session validation) — so this
    /// naturally satisfies "check once after login/launch" without its own
    /// launch-detection logic.
    func checkIfNeeded() async {
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < Self.recheckInterval {
            return
        }
        await runCheck(refresh: false)
    }

    /// "Check now" (§2.5): forces the server to bypass its TTL cache and
    /// re-check GitHub immediately. Safe to call any time the button is
    /// shown — the server itself enforces a minimum interval between real
    /// forced fetches, so there is no client-side throttle here.
    func checkNow() async {
        await runCheck(refresh: true)
    }

    /// Dismiss the banner for exactly this version — it stays quiet until a
    /// newer version is reported (§3).
    func dismiss(version: String) {
        dismissedVersion = version
    }

    private func runCheck(refresh: Bool) async {
        lastAttemptAt = Date()
        do {
            status = try await api.updatesLatest(refresh: refresh)
            lastCheckedAt = Date()
        } catch {
            // A 404 means an older server with no endpoint at all — there is
            // nothing to ever show, so drop any stale status. Any other
            // failure (offline, timeout, transient 5xx, etc.) is treated as
            // stale-while-error on the client too: keep the last-good status
            // rather than flashing an existing banner away on a network blip.
            if error.isNotFound {
                status = nil
            }
        }
    }

    private enum Keys {
        static let dismissedVersion = "update_dismissed_version"
        static let lastAttemptAt = "update_last_attempt_at"
    }
}
