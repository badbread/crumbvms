// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - TimeStyle

/// Granularity of a wall-clock format.
enum TimeStyle {
    /// "14:05"
    case clockShort
    /// "14:05:30"
    case clockMedium
    /// "Mon Jun 3, 14:05:30"
    case clockLong
}

// MARK: - Formatters (private singletons)

private enum _Fmt {
    static let shortClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let mediumClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let longClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // ISO 8601 with fractional seconds and Z (matches Crumb API's RFC-3339 output).
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Fallback without fractional seconds for servers that omit them.
    static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Public API

/// Format `date` as a wall-clock string in the device's current time zone.
func formatTime(_ date: Date, style: TimeStyle) -> String {
    switch style {
    case .clockShort:  return _Fmt.shortClock.string(from: date)
    case .clockMedium: return _Fmt.mediumClock.string(from: date)
    case .clockLong:   return _Fmt.longClock.string(from: date)
    }
}

/// Format `date` as a human-friendly relative string, e.g. "2 mins ago", "just now".
/// Falls back to `formatTime(_:style:)` for dates older than one day.
func formatRelativeTime(_ date: Date) -> String {
    let delta = Date().timeIntervalSince(date)
    switch delta {
    case ..<5:
        return "just now"
    case 5..<60:
        let s = Int(delta)
        return "\(s) sec\(s == 1 ? "" : "s") ago"
    case 60..<3_600:
        let m = Int(delta / 60)
        return "\(m) min\(m == 1 ? "" : "s") ago"
    case 3_600..<86_400:
        let h = Int(delta / 3_600)
        return "\(h) hr\(h == 1 ? "" : "s") ago"
    default:
        return formatTime(date, style: .clockLong)
    }
}

/// Parse an ISO 8601 / RFC-3339 string (with or without fractional seconds).
/// Returns `nil` on malformed input rather than crashing.
func parseISO8601(_ string: String) -> Date? {
    _Fmt.iso8601.date(from: string) ?? _Fmt.iso8601NoFrac.date(from: string)
}

/// Serialize `date` to an RFC-3339 UTC string suitable for Crumb API query params.
func iso8601String(_ date: Date) -> String {
    _Fmt.iso8601.string(from: date)
}

/// Format a duration in seconds as a compact human-readable string.
///
/// - Under a minute: "45s"
/// - Under an hour:  "1m 30s"
/// - An hour or more: "1h 5m"  (seconds are omitted for long durations)
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3_600

    if h > 0 {
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
    if m > 0 {
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
    return "\(s)s"
}
