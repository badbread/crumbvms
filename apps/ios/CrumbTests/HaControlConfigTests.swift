// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

/// Per-link control config (migration 0075, issue #440): the iOS client must
/// decode `require_confirm` + `allowed_actions` defensively (an older server that
/// omits them decodes exactly as today via `decodeIfPresent`) and derive the
/// offered action set from `allowed_actions` when present.
final class HaControlConfigTests: XCTestCase {

    private func decodeLink(_ jsonBody: String) throws -> HaLink {
        try JSONDecoder().decode(HaLink.self, from: Data(jsonBody.utf8))
    }

    /// Mirror `HAStateCard.actions`' derivation without the SwiftUI view.
    private func offered(_ link: HaLink) -> [String] {
        guard let allowed = link.allowedActions else {
            return HA.actions(for: link.domain).map(\.action)
        }
        return HA.allActions(for: link.domain).filter { allowed.contains($0.action) }.map(\.action)
    }

    func testOlderServerPayloadDefaultsToTodayBehavior() throws {
        let link = try decodeLink(
            #"{"id":"l1","entity_id":"light.kitchen","role":"actuator","sort_order":0}"#
        )
        XCTAssertFalse(link.requireConfirm)
        XCTAssertNil(link.allowedActions)
        XCTAssertTrue(link.actionAllowed("turn_on"))
        // Null allowed_actions ⇒ the default light card set (On/Off), unchanged.
        XCTAssertEqual(offered(link), ["turn_on", "turn_off"])
    }

    func testPresentFieldsParseAndRestrictOfferedActions() throws {
        let link = try decodeLink(
            #"{"id":"l2","entity_id":"light.kitchen","role":"actuator","sort_order":0,"require_confirm":true,"allowed_actions":["turn_on"]}"#
        )
        XCTAssertTrue(link.requireConfirm)
        XCTAssertEqual(link.allowedActions, ["turn_on"])
        XCTAssertTrue(link.actionAllowed("turn_on"))
        XCTAssertFalse(link.actionAllowed("turn_off"))
        XCTAssertEqual(offered(link), ["turn_on"])
    }

    func testLightMayBeRestrictedToExactlyToggle() throws {
        let link = try decodeLink(
            #"{"id":"l3","entity_id":"light.kitchen","role":"actuator","sort_order":0,"allowed_actions":["toggle"]}"#
        )
        // `toggle` is a full-set superset verb the default card omits.
        XCTAssertEqual(offered(link), ["toggle"])
    }

    func testCoverRestrictedToOpenAndCloseDropsStop() throws {
        let link = try decodeLink(
            #"{"id":"l4","entity_id":"cover.garage","role":"actuator","sort_order":0,"allowed_actions":["open_cover","close_cover"]}"#
        )
        XCTAssertEqual(offered(link), ["open_cover", "close_cover"])
    }
}
