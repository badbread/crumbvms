// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Shared macOS + iOS update-available checker (`docs/UPDATE-SYSTEM-PLAN.md`
/// task C4). ONE implementation for both targets: compares the server's
/// reported `latest_version` (`GET /updates/latest`) against this build's own
/// `CFBundleShortVersionString`, and drives the proactive dismissible banner
/// plus the Settings "Software Update" card and its "Check now" affordance
/// (§2.5). Never touches footage or the recorder; the only network call is the
/// existing authed `CrumbAPI.updatesLatest`, which itself talks only to this
/// app's own server (the server, not the client, contacts GitHub — §1/D2).
///
/// iOS ships this only because it's the same shared Swift code as macOS
/// (issue #7, decision D5) — iOS is explicitly the LOWEST-priority client
/// here: once the app is TestFlight/App-Store distributed, the platform's
/// own update flow supersedes this notice, and this checker could be
/// feature-flagged off for iOS at that point without touching macOS.
@MainActor
final class UpdateChecker: ObservableObject {

    /// Re-check at most this often for *periodic* re-checks while the app keeps
    /// running (§3: "at most every 24h"). The launch/login check and the
    /// Settings-appear check both bypass this throttle on purpose — a client
    /// that last checked while the server had the feature OFF must be able to
    /// discover it was turned back ON without waiting out a full day.
    private static let recheckInterval: TimeInterval = 24 * 60 * 60

    /// Swapped in place by `AppContainer.rebuildApi()` on a server-URL
    /// change. This object's own identity stays stable across that (unlike
    /// `AppContainer.api`/`mediaTokens`, which are replaced wholesale) so a
    /// view's `@ObservedObject` binding to it never goes stale.
    var api: CrumbAPI

    private let defaults: UserDefaults

    /// Last response from the server, or `nil` if never checked, or if the
    /// server 404s (an older server with no endpoint at all). `status.enabled`
    /// is the single gate for showing any UI — a disabled or absent check
    /// renders nothing.
    @Published private(set) var status: UpdateStatus?
    @Published private(set) var lastCheckedAt: Date?
    /// True while a check is in flight, so the Settings card can show a
    /// "Checking…" state and disable its "Check now" button.
    @Published private(set) var isChecking = false
    /// The version the user last dismissed the banner for, held in a published
    /// property (mirrored to `UserDefaults`) so dismissing immediately
    /// re-renders `bannerVersion` observers — a plain defaults write would
    /// not publish.
    @Published private var dismissedVersion: String?

    /// One-shot per-process guard so the every-launch check (fired from
    /// `AppContainer.applyUser`, which runs on both login and launch-time
    /// session validation) doesn't double-run within a single launch.
    private var didRunLaunchCheck = false

    init(api: CrumbAPI, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        self.dismissedVersion = defaults.string(forKey: Keys.dismissedVersion)
    }

    private var ownVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var lastAttemptAt: Date? {
        get { defaults.object(forKey: Keys.lastAttemptAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastAttemptAt) }
    }

    /// Whether the operator has the check enabled server-side. The single gate
    /// for the Settings card and the proactive banner; false (or unknown, i.e.
    /// no successful response / a 404) hides everything.
    var isEnabled: Bool { status?.enabled ?? false }

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

    /// "You're up to date" line for the Settings card when there's no newer
    /// version, naming the latest known release version when one is known.
    var upToDateText: String {
        if let latest = status?.latestVersion {
            return "You're up to date (v\(latest))."
        }
        return "You're up to date."
    }

    /// Small "last checked" hint under the "Check now" button, or `nil` before
    /// the first successful check.
    var lastCheckedHint: String? {
        guard let lastCheckedAt else { return nil }
        if Date().timeIntervalSince(lastCheckedAt) < 60 { return "Checked just now." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: lastCheckedAt, relativeTo: Date()))."
    }

    /// Fire the launch/login-time check exactly once per process launch,
    /// bypassing the 24h throttle. Called from `AppContainer.applyUser(_:)`
    /// (runs once on login and once on launch-time session validation). This
    /// drives the proactive banner without the user ever opening Settings.
    func checkOnLaunch() async {
        guard !didRunLaunchCheck else { return }
        didRunLaunchCheck = true
        await runCheck(refresh: false)
    }

    /// A fresh (non-forced, non-throttled) check — used by the Settings card's
    /// `.onAppear` so its state is never stale. `refresh: false` means the
    /// server may serve its own TTL cache, but the client always re-asks, so a
    /// server that flipped the feature on/off is picked up promptly.
    func check() async {
        await runCheck(refresh: false)
    }

    /// "Check now" (§2.5): forces the server to bypass its TTL cache and
    /// re-check GitHub immediately. Safe to call any time the button is
    /// shown — the server itself enforces a minimum interval between real
    /// forced fetches, so there is no client-side throttle here.
    func checkNow() async {
        await runCheck(refresh: true)
    }

    /// 24h-throttled variant, reserved for any *periodic* re-check wired up
    /// while the app runs (the launch and Settings-appear paths deliberately
    /// use the un-throttled `checkOnLaunch()` / `check()` instead, so a
    /// server-side enable/disable flip is never masked by the throttle).
    func checkIfNeeded() async {
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < Self.recheckInterval {
            return
        }
        await runCheck(refresh: false)
    }

    /// Dismiss the banner for exactly this version — it stays quiet until a
    /// newer version is reported (§3).
    func dismiss(version: String) {
        dismissedVersion = version
        defaults.set(version, forKey: Keys.dismissedVersion)
    }

    private func runCheck(refresh: Bool) async {
        // Coalesce overlapping checks (e.g. a launch check still in flight when
        // Settings appears, or rapid Settings re-appearance) into one.
        guard !isChecking else { return }
        isChecking = true
        lastAttemptAt = Date()
        defer { isChecking = false }
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
