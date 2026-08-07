// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import XCTest
@testable import Crumb

/// State-honesty coverage for the HA badge visual resolver (`HA.visual` /
/// `HA.badgeBackground`). The invariant under test: a toggle-domain entity
/// (light/switch/…) whose Home Assistant state is `unavailable`/`unknown`/empty,
/// or whose snapshot is stale, is rendered INDETERMINATE (grey), never a
/// confident "Off". This mirrors the Android `defaultVisual` and desktop
/// `haVisualFor`, where `edgeOn(state) == nil` greys the badge for EVERY domain
/// (regression guard for the iOS-only light/switch exclusion bug).
final class HomeAssistantVisualTests: XCTestCase {

    // MARK: - Decode helpers (HaLink/HaEntityState are Decodable-only)

    private func makeLink(
        entityId: String,
        deviceClass: String? = nil,
        overlayColor: String? = nil,
        overlayBgColor: String? = nil,
        overlayBgColorOn: String? = nil,
        overlayIcon: String? = nil
    ) throws -> HaLink {
        var d: [String: Any] = ["id": "l1", "entity_id": entityId]
        if let deviceClass { d["device_class"] = deviceClass }
        if let overlayColor { d["overlay_color"] = overlayColor }
        if let overlayBgColor { d["overlay_bg_color"] = overlayBgColor }
        if let overlayBgColorOn { d["overlay_bg_color_on"] = overlayBgColorOn }
        if let overlayIcon { d["overlay_icon"] = overlayIcon }
        let data = try JSONSerialization.data(withJSONObject: d)
        return try JSONDecoder().decode(HaLink.self, from: data)
    }

    private func makeState(entityId: String, state: String, unit: String? = nil) throws -> HaEntityState {
        var d: [String: Any] = ["entity_id": entityId, "state": state]
        if let unit { d["unit"] = unit }
        let data = try JSONSerialization.data(withJSONObject: d)
        return try JSONDecoder().decode(HaEntityState.self, from: data)
    }

    // MARK: - edgeOn (tri-state, aligned byte-for-byte with the other clients)

    func testEdgeOnGenuineValues() {
        XCTAssertEqual(HA.edgeOn("on"), true)
        XCTAssertEqual(HA.edgeOn("OPEN"), true)
        XCTAssertEqual(HA.edgeOn("detected"), true)
        XCTAssertEqual(HA.edgeOn("off"), false)
        XCTAssertEqual(HA.edgeOn("closed"), false)
        XCTAssertEqual(HA.edgeOn("no_motion"), false)
        // whitespace is trimmed, matching Android/desktop `state.trim()`.
        XCTAssertEqual(HA.edgeOn("  on  "), true)
    }

    func testEdgeOnUnknownLikeIsNil() {
        XCTAssertNil(HA.edgeOn("unavailable"))
        XCTAssertNil(HA.edgeOn("unknown"))
        XCTAssertNil(HA.edgeOn(""))
        XCTAssertNil(HA.edgeOn("72"))
    }

    // MARK: - Light: unavailable/unknown/empty must NOT read as Off

    func testLightUnavailableIsIndeterminateNotOff() throws {
        let link = try makeLink(entityId: "light.porch")
        let v = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "unavailable"), stale: false)
        XCTAssertTrue(v.indeterminate, "unavailable light must be indeterminate")
        XCTAssertFalse(v.isOn)
        XCTAssertNotEqual(v.stateText, "Off", "unavailable must never render as a confident Off")
        XCTAssertEqual(v.stateText, "Unavailable")
        XCTAssertEqual(v.color, HA.grey)
    }

    func testLightUnknownIsIndeterminate() throws {
        let link = try makeLink(entityId: "light.porch")
        let v = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "unknown"), stale: false)
        XCTAssertTrue(v.indeterminate)
        XCTAssertFalse(v.isOn)
        XCTAssertEqual(v.stateText, "Unknown")
        XCTAssertEqual(v.color, HA.grey)
    }

    func testLightMissingFromStatesIsIndeterminate() throws {
        // Entity absent from the latest /ha/states snapshot ⇒ state == nil.
        let link = try makeLink(entityId: "light.porch")
        let v = HA.visual(for: link, state: nil, stale: false)
        XCTAssertTrue(v.indeterminate)
        XCTAssertFalse(v.isOn)
        XCTAssertEqual(v.stateText, "Unknown")
    }

    // MARK: - Switch: same honesty

    func testSwitchUnavailableIsIndeterminate() throws {
        let link = try makeLink(entityId: "switch.pump")
        let v = HA.visual(for: link, state: try makeState(entityId: "switch.pump", state: "unavailable"), stale: false)
        XCTAssertTrue(v.indeterminate)
        XCTAssertFalse(v.isOn)
        XCTAssertNotEqual(v.stateText, "Off")
        XCTAssertEqual(v.color, HA.grey)
    }

    // MARK: - Genuine readings still resolve determinately

    func testLightGenuineOn() throws {
        let link = try makeLink(entityId: "light.porch")
        let v = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "on"), stale: false)
        XCTAssertFalse(v.indeterminate)
        XCTAssertTrue(v.isOn)
        XCTAssertEqual(v.stateText, "On")
        XCTAssertEqual(v.color, HA.warmYellow)
    }

    func testLightGenuineOff() throws {
        let link = try makeLink(entityId: "light.porch")
        let v = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "off"), stale: false)
        XCTAssertFalse(v.indeterminate)
        XCTAssertFalse(v.isOn)
        XCTAssertEqual(v.stateText, "Off")
        XCTAssertEqual(v.color, HA.grey)
    }

    func testSwitchGenuineOnOff() throws {
        let link = try makeLink(entityId: "switch.pump")
        let on = HA.visual(for: link, state: try makeState(entityId: "switch.pump", state: "on"), stale: false)
        XCTAssertTrue(on.isOn); XCTAssertFalse(on.indeterminate); XCTAssertEqual(on.stateText, "On")
        let off = HA.visual(for: link, state: try makeState(entityId: "switch.pump", state: "off"), stale: false)
        XCTAssertFalse(off.isOn); XCTAssertFalse(off.indeterminate); XCTAssertEqual(off.stateText, "Off")
    }

    // MARK: - Stale overrides even a genuine reading

    func testStaleGenuineOnIsIndeterminate() throws {
        let link = try makeLink(entityId: "light.porch")
        let v = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "on"), stale: true)
        XCTAssertTrue(v.indeterminate, "a stale snapshot greys even a genuine 'on'")
        XCTAssertFalse(v.isOn)
        XCTAssertEqual(v.color, HA.grey)
    }

    // MARK: - Binary sensor (non-toggle domain) unchanged: still indeterminate

    func testBinarySensorUnavailableIsIndeterminate() throws {
        let link = try makeLink(entityId: "binary_sensor.front", deviceClass: "door")
        let v = HA.visual(for: link, state: try makeState(entityId: "binary_sensor.front", state: "unavailable"), stale: false)
        XCTAssertTrue(v.indeterminate)
        XCTAssertFalse(v.isOn)
        XCTAssertNotEqual(v.stateText, "Closed")
    }

    // MARK: - #534 on-background applies ONLY to a genuine "on"

    func testOnBackgroundOnlyWhenGenuinelyOn() throws {
        let link = try makeLink(entityId: "light.porch", overlayBgColorOn: "#FF0000")
        let onColor = HA.colorFromHex("#FF0000")
        XCTAssertNotNil(onColor)

        let onVisual = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "on"), stale: false)
        XCTAssertEqual(HA.badgeBackground(link: link, visual: onVisual), onColor,
                       "genuine on ⇒ overlay_bg_color_on wins")

        let unknownVisual = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "unavailable"), stale: false)
        XCTAssertEqual(HA.badgeBackground(link: link, visual: unknownVisual), HA.defaultBadgeBackground,
                       "unavailable ⇒ on-background must NOT be consulted")

        let offVisual = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "off"), stale: false)
        XCTAssertEqual(HA.badgeBackground(link: link, visual: offVisual), HA.defaultBadgeBackground,
                       "off ⇒ on-background must NOT be consulted")
    }

    // MARK: - overlay_color tint is suppressed on indeterminate

    func testOverlayColorNotAppliedWhenIndeterminate() throws {
        // A per-badge color override must never colorize an unknown/unavailable
        // reading — the grey honesty treatment wins (indeterminate branch skips
        // `applyOverrides`).
        let link = try makeLink(entityId: "light.porch", overlayColor: "#00FF00")
        let v = HA.visual(for: link, state: try makeState(entityId: "light.porch", state: "unavailable"), stale: false)
        XCTAssertTrue(v.indeterminate)
        XCTAssertEqual(v.color, HA.grey, "overlay_color must not tint an indeterminate badge")
    }
}
