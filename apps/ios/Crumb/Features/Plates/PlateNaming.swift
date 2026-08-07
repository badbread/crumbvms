// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Pure logic behind the Plates tab's two operator affordances: copy a plate
/// number, and give a plate a human-readable name (`plate_labels`, issue #363).
///
/// Deliberately free of SwiftUI and networking so `CrumbTests` can pin the
/// contracts that actually bite:
///
/// * **Copy takes the raw plate.** When a plate is named, the name is the
///   prominent line and the raw plate sits underneath it — the clipboard must
///   still get the plate, because that is what the operator pastes into a
///   report, a search box, or another system.
/// * **Blank means clear, not "set to empty".** The web console's `namePlate()`
///   treats an emptied prompt as a `DELETE`; this client must agree.
/// * **A name is not an alert.** Nothing here touches the watchlist. Naming
///   writes `plate_labels` only; the watchlist (`lpr_watchlist`) stays the
///   separate BOLO/alert list.
enum PlateNaming {

    /// The operator-assigned name to render for a plate, or `nil` when the
    /// server resolved none (or only whitespace) — the UI then shows the raw
    /// plate exactly as it did before names existed.
    ///
    /// The server already resolves precedence as
    /// `COALESCE(plate_labels.label, lpr_watchlist.label)`, so this only
    /// normalizes what it sent; it never re-implements that precedence.
    static func resolvedName(_ displayName: String?) -> String? {
        guard let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// What the copy affordance puts on the clipboard for a read: always the
    /// raw `plate`, never `displayName`, even when the name is the line the
    /// operator is looking at. `nil` when there is no plate to copy.
    ///
    /// `displayName` is taken as a parameter precisely so this contract is
    /// expressible (and testable) rather than implicit at the call site.
    static func copyTarget(plate: String, displayName: String?) -> String? {
        _ = displayName
        let trimmed = plate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What submitting the name editor should do for a plate whose currently
    /// shown name is `current`.
    enum Action: Equatable {
        /// `PUT /lpr/plate-labels` with this label.
        case set(String)
        /// `DELETE /lpr/plate-labels/:plate` — the operator emptied the field.
        case clear
        /// Nothing to do (unchanged, or blank when there was no name anyway) —
        /// don't spend a request, and don't provoke a spurious 404.
        case noChange
    }

    static func action(input: String, current: String?) -> Action {
        let next = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = resolvedName(current)
        if next.isEmpty {
            return now == nil ? .noChange : .clear
        }
        return next == now ? .noChange : .set(next)
    }

    /// Percent-encode a plate for the `DELETE /lpr/plate-labels/:plate` path
    /// segment. Only RFC 3986 unreserved characters survive unescaped, so a
    /// stray `/`, `#`, `?` or space in a plate string can never break out of
    /// the segment and hit a different route. Normalized plates are already
    /// alphanumeric; this is the belt on the braces.
    static func pathEscaped(_ plate: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return plate.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
