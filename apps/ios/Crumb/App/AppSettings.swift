// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Observable user preferences, backed by UserDefaults.
///
/// Replaces the previous pattern of plain (non-`@Published`) computed properties
/// on `KeychainStore` that views mirrored into `@State` — which silently dropped
/// changes made elsewhere (e.g. a grid-layout change in Settings never reached
/// the live wall). Every property publishes on change and writes through to
/// UserDefaults, so any observing view updates immediately and the value survives
/// relaunch. The UserDefaults keys are unchanged, so existing prefs carry over.
@MainActor
final class AppSettings: ObservableObject {

    private let defaults: UserDefaults

    @Published var liveGridLayout: Int { didSet { defaults.set(liveGridLayout, forKey: Keys.liveGridLayout) } }
    @Published var ptzStyle: String { didSet { defaults.set(ptzStyle, forKey: Keys.ptzStyle) } }
    @Published var lowBandwidthMode: Bool { didSet { defaults.set(lowBandwidthMode, forKey: Keys.lowBandwidthMode) } }
    @Published var motionTunerEnabled: Bool { didSet { defaults.set(motionTunerEnabled, forKey: Keys.motionTunerEnabled) } }
    @Published var bookmarksButtonEnabled: Bool { didSet { defaults.set(bookmarksButtonEnabled, forKey: Keys.bookmarksButtonEnabled) } }
    /// The id of the currently-active named view, or `nil` for "All cameras".
    /// (The views themselves are server-backed as of M1 — see
    /// `LiveViewModel.views`/`loadViews()` — but which one is "active" stays a
    /// per-device UI preference, same as the other settings here.)
    @Published var activeViewId: String? { didSet { defaults.set(activeViewId, forKey: Keys.activeViewId) } }
    /// M6 parity: opt-in biometric/passcode app-lock on cold start + foreground
    /// resume, matching Android's face/fingerprint gate. Off by default —
    /// this is a lock on the LOCAL app session, not a server-side control, so
    /// defaulting it off avoids surprising an existing user with a new gate
    /// they never asked for.
    @Published var biometricLockEnabled: Bool { didSet { defaults.set(biometricLockEnabled, forKey: Keys.biometricLockEnabled) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        liveGridLayout = defaults.object(forKey: Keys.liveGridLayout) as? Int ?? 1
        ptzStyle = defaults.string(forKey: Keys.ptzStyle) ?? "wheel"
        lowBandwidthMode = defaults.object(forKey: Keys.lowBandwidthMode) as? Bool ?? false
        motionTunerEnabled = defaults.object(forKey: Keys.motionTunerEnabled) as? Bool ?? true
        bookmarksButtonEnabled = defaults.object(forKey: Keys.bookmarksButtonEnabled) as? Bool ?? true
        activeViewId = defaults.string(forKey: Keys.activeViewId)
        biometricLockEnabled = defaults.object(forKey: Keys.biometricLockEnabled) as? Bool ?? false
    }

    private enum Keys {
        static let liveGridLayout = "live_grid_layout"
        static let ptzStyle = "ptz_style"
        static let lowBandwidthMode = "low_bandwidth_mode"
        static let motionTunerEnabled = "motion_tuner_enabled"
        static let bookmarksButtonEnabled = "bookmarks_button_enabled"
        static let activeViewId = "active_view_id"
        static let biometricLockEnabled = "biometric_lock_enabled"
    }
}
