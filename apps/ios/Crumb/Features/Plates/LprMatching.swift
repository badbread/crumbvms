// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure plate-matching + duplicate-collapse logic, ported 1:1 from the server
// (`services/common/src/db.rs`: `normalize_plate`, `confusable`, `levenshtein`,
// `allowed_edits`) so client-side match previews and grouping agree with the
// backend. No SwiftUI, no networking — logic only.

import Foundation

enum Lpr {
    // MARK: - Normalization

    /// Normalize a plate for matching: keep only ASCII alphanumerics
    /// `[A-Za-z0-9]`, uppercase them, drop everything else (spaces, dashes,
    /// punctuation, non-ASCII).
    static func normalizePlate(_ s: String) -> String {
        String(s.unicodeScalars.compactMap { scalar -> Character? in
            guard scalar.isASCII else { return nil }
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                return Character(c.uppercased())
            }
            return nil
        })
    }

    // MARK: - Confusable characters

    /// Canonical bucket for visually-confusable characters that plate OCR
    /// routinely flips: `{O,0,D} {I,1} {B,8} {S,5} {Z,2} {G,6}`. Characters
    /// outside the listed buckets are their own bucket.
    private static func canon(_ c: Character) -> Character {
        switch c {
        case "O", "0", "D": return "0"
        case "I", "1": return "1"
        case "B", "8": return "8"
        case "S", "5": return "5"
        case "Z", "2": return "2"
        case "G", "6": return "6"
        default: return c
        }
    }

    /// True iff `a != b` and both map to the same canonical bucket (i.e. they
    /// are a known OCR-confusable pair). Operates on uppercased characters.
    static func confusable(_ a: Character, _ b: Character) -> Bool {
        a != b && canon(a) == canon(b)
    }

    // MARK: - Edit distance

    /// Classic two-row dynamic-programming Levenshtein edit distance.
    ///
    /// When `confusableZeroCost` is true, a substitution between two
    /// `confusable` characters costs 0 instead of 1; insertions, deletions,
    /// and all other substitutions cost 1. Inputs are assumed to already be
    /// normalized by the caller.
    static func levenshtein(_ a: String, _ b: String, confusableZeroCost: Bool) -> Int {
        let ac = Array(a)
        let bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }

        // `prev`/`curr` are two rows of the DP table (row = position in `a`).
        var prev: [Int] = Array(0...bc.count)
        var curr: [Int] = Array(repeating: 0, count: bc.count + 1)
        for (i, ca) in ac.enumerated() {
            curr[0] = i + 1
            for (j, cb) in bc.enumerated() {
                let cost: Int
                if ca == cb {
                    cost = 0
                } else if confusableZeroCost && confusable(ca, cb) {
                    cost = 0
                } else {
                    cost = 1
                }
                // deletion, insertion, substitution.
                curr[j + 1] = min(prev[j + 1] + 1, curr[j] + 1, prev[j] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bc.count]
    }

    // MARK: - Watch/ignore matching

    /// How many character edits a read may differ from `reference` and still
    /// count as a match, under the length-scaled character-tolerance model:
    /// `floor(clamp(fuzz, 0, 0.5) * normalizedReferenceLength)`.
    /// `fuzz == 0` yields 0 edits, i.e. exact match after normalization.
    static func allowedEdits(reference: String, fuzz: Double) -> Int {
        let len = Double(normalizePlate(reference).count)
        let clamped = min(max(fuzz, 0.0), 0.5)
        return Int((clamped * len).rounded(.down))
    }

    /// Whether `read` matches the watch/ignore `entryPlate` under the server's
    /// character-tolerance model: confusable-zero-cost edit distance between
    /// the normalized plates, within `allowedEdits(reference:fuzz:)` of the
    /// entry's plate.
    static func matchesWatch(read: String, entryPlate: String, fuzz: Double) -> Bool {
        levenshtein(
            normalizePlate(read),
            normalizePlate(entryPlate),
            confusableZeroCost: true
        ) <= allowedEdits(reference: entryPlate, fuzz: fuzz)
    }

    // MARK: - Duplicate-read collapse

    /// Lightweight plate-read value for collapse logic, decoupled from the
    /// Decodable `PlateRead` networking model.
    struct PlateReadLite {
        let id: String
        let cameraId: String
        let tsMs: Int64
        let plate: String
        let confidence: Double?
    }

    /// A collapsed group of near-duplicate reads of (probably) the same
    /// vehicle pass: same camera, within a 15 s window of the group's oldest
    /// member, with a similar plate string.
    struct PlateGroup: Identifiable {
        /// Representative read id.
        let id: String
        /// The highest-confidence member (nil confidence treated as lowest).
        let representative: PlateReadLite
        /// All members, newest-first.
        let members: [PlateReadLite]
        var count: Int { members.count }
    }

    /// Time window: a read may join a group only if it is within 15 s of the
    /// group's OLDEST member.
    private static let collapseWindowMs: Int64 = 15_000

    /// Whether two normalized plates are "similar" for collapse purposes:
    /// plain Levenshtein (NO confusable discount) within
    /// `max(1, round(maxLen * 0.34))` edits.
    private static func platesSimilar(_ a: String, _ b: String) -> Bool {
        let maxLen = max(a.count, b.count)
        let maxEdits = max(1, Int((Double(maxLen) * 0.34).rounded()))
        return levenshtein(a, b, confusableZeroCost: false) <= maxEdits
    }

    /// Collapse near-duplicate reads into groups. Input is assumed to be
    /// newest-first; overall ordering is preserved by each group's first
    /// (newest) member. If `enabled` is false, every read becomes its own
    /// singleton group in input order.
    static func collapse(_ reads: [PlateReadLite], enabled: Bool) -> [PlateGroup] {
        guard enabled else {
            return reads.map { PlateGroup(id: $0.id, representative: $0, members: [$0]) }
        }

        // Mutable accumulator; finalized into PlateGroup at the end.
        struct Builder {
            var members: [PlateReadLite]   // newest-first (input order)
            var best: PlateReadLite        // highest-confidence member so far
            var oldestTsMs: Int64
        }

        var builders: [Builder] = []
        for read in reads {
            var joined = false
            for idx in builders.indices {
                let group = builders[idx]
                guard group.best.cameraId == read.cameraId else { continue }
                guard abs(group.oldestTsMs - read.tsMs) <= collapseWindowMs else { continue }
                guard platesSimilar(group.best.plate, read.plate) else { continue }

                builders[idx].members.append(read)
                builders[idx].oldestTsMs = min(builders[idx].oldestTsMs, read.tsMs)
                let bestConf = builders[idx].best.confidence ?? -Double.infinity
                let readConf = read.confidence ?? -Double.infinity
                if readConf > bestConf {
                    builders[idx].best = read
                }
                joined = true
                break
            }
            if !joined {
                builders.append(Builder(members: [read], best: read, oldestTsMs: read.tsMs))
            }
        }

        return builders.map { builder in
            PlateGroup(id: builder.best.id, representative: builder.best, members: builder.members)
        }
    }
}
