// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

/// Guards the plate match-mode contract: the raw values are sent verbatim as the
/// server's `match=` query parameter, so they must stay exactly
/// `contains`/`prefix`/`exact`/`fuzzy`, and `contains` must remain the default
/// (first case) offered by the picker.
final class PlateMatchTests: XCTestCase {

    func testRawValuesMatchServerContract() {
        XCTAssertEqual(PlateMatch.contains.rawValue, "contains")
        XCTAssertEqual(PlateMatch.prefix.rawValue, "prefix")
        XCTAssertEqual(PlateMatch.exact.rawValue, "exact")
        XCTAssertEqual(PlateMatch.fuzzy.rawValue, "fuzzy")
    }

    func testAllModesOfferedContainsFirst() {
        XCTAssertEqual(PlateMatch.allCases, [.contains, .prefix, .exact, .fuzzy])
    }

    func testLabels() {
        XCTAssertEqual(PlateMatch.contains.label, "Contains")
        XCTAssertEqual(PlateMatch.fuzzy.label, "Fuzzy")
    }
}
