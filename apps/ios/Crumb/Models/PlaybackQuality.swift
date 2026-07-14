// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// User-selectable media-quality preference, governing both live and recorded
/// playback. A faithful port of Android's `object PlaybackQuality`
/// (`feature/playback/PlaybackScreen.kt`): the persisted raw string values must
/// stay identical so the two clients agree on the meaning of the stored value.
///
/// - `.full` — native camera streams (main / sub) + the raw recorded segment.
///   The LAN default choice; no server-side transcode.
/// - `.low` (persisted as **`"low"`**, labelled "Data saver") — always the
///   low-bitrate variants: the `/segments/{id}/low.mp4` transcode for playback,
///   and the sub / mobile stream for live.
/// - `.auto` — decide per connection: metered/cellular ⇒ low, Wi-Fi/unmetered
///   ⇒ full (see `useLow(metered:)`).
enum PlaybackQuality: String, CaseIterable, Sendable {
    case auto = "auto"
    case full = "full"
    /// "Data saver" — note the persisted value is `"low"`, matching Android.
    case low = "low"

    /// Default when nothing is stored, matching Android's `"auto"`.
    static let fallback: PlaybackQuality = .auto

    /// Decode a persisted value, tolerating nil / unknown → `.auto`.
    init(persisted: String?) {
        self = PlaybackQuality(rawValue: persisted ?? "") ?? .fallback
    }

    /// One-tap cycle order, matching Android: Auto → Full → Data saver → Auto.
    var next: PlaybackQuality {
        switch self {
        case .auto: return .full
        case .full: return .low
        case .low: return .auto
        }
    }

    /// Full menu label (e.g. for an accessibility label / tooltip).
    var label: String {
        switch self {
        case .full: return "Full"
        case .low: return "Data saver"
        case .auto: return "Auto"
        }
    }

    /// Compact badge shown on the in-player chip, matching Android's `short()`.
    var short: String {
        switch self {
        case .full: return "HD"
        case .low: return "SD"
        case .auto: return "AUTO"
        }
    }

    /// Whether the low-bitrate variant should be used, given the current
    /// metered signal. `.full` never, `.low` always, `.auto` iff metered —
    /// identical to Android's `useLow` computation in `PlaybackScreen.kt`.
    func useLow(metered: Bool) -> Bool {
        switch self {
        case .full: return false
        case .low: return true
        case .auto: return metered
        }
    }
}
