// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

final class LprMatchingTests: XCTestCase {
    // MARK: - normalizePlate

    func testNormalizeDropsSpacesAndDashesAndUppercases() {
        XCTAssertEqual(Lpr.normalizePlate("abc 123"), "ABC123")
        XCTAssertEqual(Lpr.normalizePlate("ab-c 1.2 3"), "ABC123")
        XCTAssertEqual(Lpr.normalizePlate("  x Y z  "), "XYZ")
        XCTAssertEqual(Lpr.normalizePlate(""), "")
        XCTAssertEqual(Lpr.normalizePlate("---"), "")
    }

    // MARK: - confusable

    func testConfusablePairs() {
        XCTAssertTrue(Lpr.confusable("O", "0"))
        XCTAssertTrue(Lpr.confusable("0", "O"))
        XCTAssertTrue(Lpr.confusable("I", "1"))
        XCTAssertTrue(Lpr.confusable("B", "8"))
        XCTAssertTrue(Lpr.confusable("S", "5"))
        XCTAssertTrue(Lpr.confusable("Z", "2"))
        XCTAssertTrue(Lpr.confusable("G", "6"))
        // Shared 0-bucket: D pairs with both O and 0.
        XCTAssertTrue(Lpr.confusable("D", "0"))
        XCTAssertTrue(Lpr.confusable("D", "O"))
    }

    func testConfusableUnrelatedCharactersAreFalse() {
        XCTAssertFalse(Lpr.confusable("A", "4"))
        XCTAssertFalse(Lpr.confusable("C", "X"))
        XCTAssertFalse(Lpr.confusable("7", "1"))
        // Same character is never "confusable" with itself.
        XCTAssertFalse(Lpr.confusable("O", "O"))
        XCTAssertFalse(Lpr.confusable("5", "5"))
    }

    // MARK: - levenshtein

    func testLevenshteinConfusableZeroCost() {
        XCTAssertEqual(Lpr.levenshtein("0BC123", "OBC123", confusableZeroCost: true), 0)
        XCTAssertEqual(Lpr.levenshtein("0BC123", "OBC123", confusableZeroCost: false), 1)
    }

    func testLevenshteinBasics() {
        XCTAssertEqual(Lpr.levenshtein("ABC", "ABC", confusableZeroCost: true), 0)
        XCTAssertEqual(Lpr.levenshtein("ABC", "ABX", confusableZeroCost: true), 1)
        XCTAssertEqual(Lpr.levenshtein("ABC", "AB", confusableZeroCost: true), 1)
        XCTAssertEqual(Lpr.levenshtein("", "ABC", confusableZeroCost: true), 3)
        XCTAssertEqual(Lpr.levenshtein("ABC", "", confusableZeroCost: true), 3)
        // Confusable at every position collapses to zero.
        XCTAssertEqual(Lpr.levenshtein("OIB", "018", confusableZeroCost: true), 0)
        // Confusable free, non-confusable still costs.
        XCTAssertEqual(Lpr.levenshtein("8XC", "BXY", confusableZeroCost: true), 1)
    }

    // MARK: - allowedEdits

    func testAllowedEdits() {
        XCTAssertEqual(Lpr.allowedEdits(reference: "ABC123", fuzz: 0), 0)
        XCTAssertEqual(Lpr.allowedEdits(reference: "ABC123", fuzz: 0.5), 3)
        // Clamped above 0.5.
        XCTAssertEqual(Lpr.allowedEdits(reference: "ABC123", fuzz: 1.0), 3)
        // Negative clamps to 0.
        XCTAssertEqual(Lpr.allowedEdits(reference: "ABC123", fuzz: -1.0), 0)
        // floor(0.2 * 6) = 1; normalization applies to the reference.
        XCTAssertEqual(Lpr.allowedEdits(reference: "AB-C 123", fuzz: 0.2), 1)
    }

    // MARK: - matchesWatch

    func testMatchesWatchExactAtFuzzZero() {
        XCTAssertTrue(Lpr.matchesWatch(read: "abc 123", entryPlate: "ABC123", fuzz: 0))
        XCTAssertFalse(Lpr.matchesWatch(read: "ABC124", entryPlate: "ABC123", fuzz: 0))
    }

    func testMatchesWatchConfusableOffMatchesAtFuzzZero() {
        // O vs 0 is a zero-cost confusable substitution, so this still matches
        // even with no fuzz budget.
        XCTAssertTrue(Lpr.matchesWatch(read: "0BC123", entryPlate: "OBC123", fuzz: 0))
    }

    func testMatchesWatchGenuinelyDifferentPlateDoesNotMatchAtLowFuzz() {
        // 6-char reference, fuzz 0.2 → 1 allowed edit; "XYZ789" is far away.
        XCTAssertFalse(Lpr.matchesWatch(read: "XYZ789", entryPlate: "ABC123", fuzz: 0.2))
    }

    // MARK: - collapse

    private func read(
        _ id: String,
        camera: String = "cam1",
        tsMs: Int64,
        plate: String,
        confidence: Double? = nil
    ) -> Lpr.PlateReadLite {
        Lpr.PlateReadLite(id: id, cameraId: camera, tsMs: tsMs, plate: plate, confidence: confidence)
    }

    func testCollapseMergesNearDuplicates() {
        // Newest-first: r1 at t=105s, r2 at t=100s (5s apart), same camera,
        // similar plates, r2 has the higher confidence.
        let r1 = read("r1", tsMs: 105_000, plate: "ABC123", confidence: 0.60)
        let r2 = read("r2", tsMs: 100_000, plate: "ABC128", confidence: 0.95)
        let groups = Lpr.collapse([r1, r2], enabled: true)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[0].representative.id, "r2")
        XCTAssertEqual(groups[0].id, "r2")
        // Members stay newest-first (input order).
        XCTAssertEqual(groups[0].members.map(\.id), ["r1", "r2"])
    }

    func testCollapseDoesNotMergeBeyondTimeWindow() {
        let r1 = read("r1", tsMs: 120_000, plate: "ABC123", confidence: 0.9)
        let r2 = read("r2", tsMs: 100_000, plate: "ABC123", confidence: 0.9) // 20s apart
        let groups = Lpr.collapse([r1, r2], enabled: true)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.id), ["r1", "r2"])
    }

    func testCollapseDoesNotMergeAcrossCameras() {
        let r1 = read("r1", camera: "cam1", tsMs: 105_000, plate: "ABC123")
        let r2 = read("r2", camera: "cam2", tsMs: 100_000, plate: "ABC123")
        let groups = Lpr.collapse([r1, r2], enabled: true)
        XCTAssertEqual(groups.count, 2)
    }

    func testCollapseDoesNotMergeDissimilarPlates() {
        let r1 = read("r1", tsMs: 105_000, plate: "ABC123")
        let r2 = read("r2", tsMs: 100_000, plate: "XYZ789")
        let groups = Lpr.collapse([r1, r2], enabled: true)
        XCTAssertEqual(groups.count, 2)
    }

    func testCollapseDisabledYieldsSingletons() {
        let r1 = read("r1", tsMs: 105_000, plate: "ABC123", confidence: 0.6)
        let r2 = read("r2", tsMs: 100_000, plate: "ABC123", confidence: 0.9)
        let groups = Lpr.collapse([r1, r2], enabled: false)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.id), ["r1", "r2"])
        XCTAssertTrue(groups.allSatisfy { $0.count == 1 })
    }
}
