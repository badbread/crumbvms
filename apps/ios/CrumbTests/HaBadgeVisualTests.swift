// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import XCTest
@testable import Crumb

/// The detail card (`HAStateCard`) colors its header icon with the SAME
/// `HA.visual(...).color` the on-video badge uses — a lit light MUST read as warm
/// yellow, never a greyscale/washed header (shared spec across desktop/iOS/
/// Android). These lock the state→color mapping the card and badge both consume,
/// so a future palette edit can't silently desaturate the card.
final class HaBadgeVisualTests: XCTestCase {

    private func link(_ entityId: String, deviceClass: String? = nil) throws -> HaLink {
        let dc = deviceClass.map { #","device_class":"\#($0)""# } ?? ""
        let json = #"{"id":"l","entity_id":"\#(entityId)","role":"sensor","sort_order":0\#(dc)}"#
        return try JSONDecoder().decode(HaLink.self, from: Data(json.utf8))
    }

    private func state(_ raw: String) -> HaEntityState {
        HaEntityState(entityId: "e", state: raw, lastChanged: nil, unit: nil, control: nil)
    }

    func testLitLightIsWarmYellowNotGrey() throws {
        let v = HA.visual(for: try link("light.kitchen"), state: state("on"), stale: false)
        XCTAssertEqual(v.color, HA.warmYellow)
        XCTAssertNotEqual(v.color, HA.grey)
        XCTAssertFalse(v.indeterminate)
    }

    func testOffLightIsGrey() throws {
        let v = HA.visual(for: try link("light.kitchen"), state: state("off"), stale: false)
        XCTAssertEqual(v.color, HA.grey)
    }

    func testSwitchOnIsGreen() throws {
        let v = HA.visual(for: try link("switch.porch"), state: state("on"), stale: false)
        XCTAssertEqual(v.color, HA.green)
    }

    func testMotionActiveIsBlue() throws {
        let v = HA.visual(for: try link("binary_sensor.hall", deviceClass: "motion"),
                          state: state("on"), stale: false)
        XCTAssertEqual(v.color, HA.blue)
    }

    func testDoorOpenIsAmber() throws {
        let v = HA.visual(for: try link("binary_sensor.front", deviceClass: "door"),
                          state: state("on"), stale: false)
        XCTAssertEqual(v.color, HA.amber)
    }

    func testSmokeAlarmIsDangerRed() throws {
        let v = HA.visual(for: try link("binary_sensor.kitchen", deviceClass: "smoke"),
                          state: state("on"), stale: false)
        XCTAssertEqual(v.color, HA.danger)
    }

    /// The honesty invariant the card shares with the badge: a lit light that is
    /// stale greys out rather than lying warm-yellow.
    func testStaleLitLightGreysOut() throws {
        let v = HA.visual(for: try link("light.kitchen"), state: state("on"), stale: true)
        XCTAssertEqual(v.color, HA.grey)
        XCTAssertTrue(v.indeterminate)
    }

    // MARK: - "Type" row label (parity with Android haTypeLabel)

    /// device_class present ⇒ humanized device_class, first letter only.
    func testTypeUsesHumanizedDeviceClass() {
        XCTAssertEqual(HA.typeLabel(domain: "cover", deviceClass: "garage_door"), "Garage door")
        XCTAssertEqual(HA.typeLabel(domain: "sensor", deviceClass: "carbon_monoxide"), "Carbon monoxide")
    }

    /// device_class absent/empty ⇒ humanized domain, never blank.
    func testTypeFallsBackToDomainWhenDeviceClassMissing() {
        XCTAssertEqual(HA.typeLabel(domain: "light", deviceClass: nil), "Light")
        XCTAssertEqual(HA.typeLabel(domain: "light", deviceClass: ""), "Light")
        XCTAssertEqual(HA.typeLabel(domain: "media_player", deviceClass: nil), "Media player")
    }

    /// Only the first letter is capitalized — interior words untouched (not
    /// `.capitalized`, which would title-case every word).
    func testTypeCapitalizesFirstLetterOnly() {
        XCTAssertEqual(HA.typeLabel(domain: "binary_sensor", deviceClass: "garage_door"), "Garage door")
        XCTAssertNotEqual(HA.typeLabel(domain: "cover", deviceClass: "garage_door"), "Garage Door")
    }
}
