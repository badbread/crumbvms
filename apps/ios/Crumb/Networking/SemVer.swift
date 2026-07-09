// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A tiny hand-rolled SemVer-precedence comparator, just enough for the
/// update-available check (`docs/UPDATE-SYSTEM-PLAN.md` §2.2): parses a
/// `MAJOR.MINOR.PATCH` triple (missing trailing components default to 0) and
/// compares numerically. Anything that doesn't parse as plain dot-separated
/// non-negative integers — including pre-release suffixes like `0.0.1-dev` —
/// is treated as unparsable, matching the plan's "unparsable own version ⇒
/// never show the banner" rule: a dev build should never falsely claim to be
/// behind (or ahead of) a tagged release. No third-party dependency, per
/// AGENTS.md golden rule 6 (this mirrors the equally tiny hand-rolled
/// comparators in the Rust/Kotlin/JS siblings).
enum SemVer {

    /// Parses `version` into up to 3 numeric components. Returns `nil` if any
    /// dot-separated segment isn't a plain non-negative integer (covers
    /// pre-release/build-metadata suffixes, empty strings, and any other
    /// non-numeric noise).
    static func parse(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let n = Int(part) else { return nil }
            components.append(n)
        }
        while components.count < 3 { components.append(0) }
        return components
    }

    /// True iff `candidate` is a strictly-greater version than `base`. Either
    /// side failing to parse means "no", never "yes" — an unparsable
    /// (typically dev/local) build never reports an update as available, and
    /// never gets treated as "ahead" of a real release either.
    static func isNewer(_ candidate: String, than base: String) -> Bool {
        guard let c = parse(candidate), let b = parse(base) else { return false }
        for i in 0..<3 where c[i] != b[i] {
            return c[i] > b[i]
        }
        return false
    }
}
