// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

/// Covers the hand-rolled comparator behind the update-available checker
/// (`docs/UPDATE-SYSTEM-PLAN.md` §2.2, task C4) — in particular the
/// "unparsable own version ⇒ never show the banner" rule.
final class SemVerTests: XCTestCase {

    func testStrictlyGreaterIsNewer() {
        XCTAssertTrue(SemVer.isNewer("0.0.2", than: "0.0.1"))
        XCTAssertTrue(SemVer.isNewer("0.1.0", than: "0.0.9"))
        XCTAssertTrue(SemVer.isNewer("1.0.0", than: "0.9.9"))
    }

    func testEqualOrOlderIsNotNewer() {
        XCTAssertFalse(SemVer.isNewer("0.0.1", than: "0.0.1"))
        XCTAssertFalse(SemVer.isNewer("0.0.1", than: "0.0.2"))
        XCTAssertFalse(SemVer.isNewer("0.9.0", than: "1.0.0"))
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertTrue(SemVer.isNewer("0.1", than: "0.0.9"))
        XCTAssertFalse(SemVer.isNewer("0.0", than: "0.0.1"))
        XCTAssertFalse(SemVer.isNewer("1", than: "1.0.0"))
    }

    func testUnparsableNeverReportsNewer() {
        // A dev build's own version (e.g. "0.0.1-dev") never parses, so it
        // can never be reported as behind a real release either.
        XCTAssertFalse(SemVer.isNewer("0.0.2", than: "0.0.1-dev"))
        XCTAssertFalse(SemVer.isNewer("not-a-version", than: "0.0.1"))
        XCTAssertFalse(SemVer.isNewer("0.0.2", than: ""))
        XCTAssertFalse(SemVer.isNewer("1.2.3.4", than: "1.2.3"))
    }
}
