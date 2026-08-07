// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

/// Contracts behind the Plates tab's copy-plate and name-a-plate affordances
/// (issue #363). These are the parts that quietly go wrong: copying the pretty
/// name instead of the plate the operator actually needs to paste, treating an
/// emptied name field as "set to empty" instead of "clear", and letting a plate
/// string escape its URL path segment.
final class PlateNamingTests: XCTestCase {

    // MARK: display-name resolution

    func testResolvedNameTrims() {
        XCTAssertEqual(PlateNaming.resolvedName("  Delivery van  "), "Delivery van")
    }

    func testResolvedNameNilForAbsentOrBlank() {
        XCTAssertNil(PlateNaming.resolvedName(nil))
        XCTAssertNil(PlateNaming.resolvedName(""))
        XCTAssertNil(PlateNaming.resolvedName("   \n "))
    }

    // MARK: copy target

    /// The whole point of the copy affordance: even when the row is showing the
    /// operator-assigned name in the plate's place, the clipboard gets the plate.
    func testCopyTargetIsAlwaysTheRawPlateNeverTheName() {
        XCTAssertEqual(PlateNaming.copyTarget(plate: "7XYZ432", displayName: "Delivery van"), "7XYZ432")
        XCTAssertEqual(PlateNaming.copyTarget(plate: "7XYZ432", displayName: nil), "7XYZ432")
    }

    func testCopyTargetTrimsAndRejectsEmpty() {
        XCTAssertEqual(PlateNaming.copyTarget(plate: "  7XYZ432 ", displayName: nil), "7XYZ432")
        XCTAssertNil(PlateNaming.copyTarget(plate: "", displayName: "Delivery van"))
        XCTAssertNil(PlateNaming.copyTarget(plate: "   ", displayName: nil))
    }

    // MARK: set / clear / no-op

    func testBlankInputClearsAnExistingName() {
        XCTAssertEqual(PlateNaming.action(input: "", current: "Delivery van"), .clear)
        XCTAssertEqual(PlateNaming.action(input: "   ", current: "Delivery van"), .clear)
    }

    /// Blank over an already-unnamed plate is nothing to do — clearing it would
    /// only earn a 404 from `DELETE /lpr/plate-labels/:plate`.
    func testBlankInputOnUnnamedPlateIsNoChange() {
        XCTAssertEqual(PlateNaming.action(input: "", current: nil), .noChange)
        XCTAssertEqual(PlateNaming.action(input: "  ", current: "   "), .noChange)
    }

    func testNewNameSetsTrimmed() {
        XCTAssertEqual(PlateNaming.action(input: "  Delivery van ", current: nil), .set("Delivery van"))
        XCTAssertEqual(PlateNaming.action(input: "Neighbour", current: "Delivery van"), .set("Neighbour"))
    }

    func testUnchangedNameSpendsNoRequest() {
        XCTAssertEqual(PlateNaming.action(input: "Delivery van", current: "Delivery van"), .noChange)
        XCTAssertEqual(PlateNaming.action(input: " Delivery van ", current: "Delivery van"), .noChange)
    }

    // MARK: path escaping

    func testNormalizedPlatePassesThroughUnescaped() {
        XCTAssertEqual(PlateNaming.pathEscaped("7XYZ432"), "7XYZ432")
    }

    /// A separator in a plate string must not be able to reach another route.
    func testSeparatorsAreEscaped() {
        XCTAssertEqual(PlateNaming.pathEscaped("A/B"), "A%2FB")
        XCTAssertEqual(PlateNaming.pathEscaped("A B"), "A%20B")
        XCTAssertEqual(PlateNaming.pathEscaped("A#B"), "A%23B")
        XCTAssertEqual(PlateNaming.pathEscaped("A?B"), "A%3FB")
    }
}
