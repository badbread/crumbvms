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

    /// A link carrying `overlay_bg_color`/`overlay_bg_color_on`, either of which
    /// may be omitted (mirroring an older server / an unset field).
    private func linkWithBg(_ entityId: String, bgColor: String? = nil, bgColorOn: String? = nil) throws -> HaLink {
        var json = #"{"id":"l","entity_id":"\#(entityId)","role":"sensor","sort_order":0"#
        if let bgColor { json += #","overlay_bg_color":"\#(bgColor)""# }
        if let bgColorOn { json += #","overlay_bg_color_on":"\#(bgColorOn)""# }
        json += "}"
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

    // MARK: - Badge background (`overlay_bg_color` / `overlay_bg_color_on`)
    //
    // Resolution order (frozen contract): entity ON -> bg_color_on ?? bg_color
    // ?? default; OFF or indeterminate/stale -> bg_color ?? default. "On" is the
    // SAME `HAVisual.isOn` the tri-state `edgeOn` logic above already drives
    // (it also dims `overlayColor` to 45% when off) — never a separate notion of
    // "on" invented for the background.

    func testOverlayBgColorOnDecodesWhenPresent() throws {
        let l = try linkWithBg("light.kitchen", bgColorOn: "#22FF22")
        XCTAssertEqual(l.overlayBgColorOn, "#22FF22")
    }

    func testOverlayBgColorOnNilWhenAbsent() throws {
        let l = try linkWithBg("light.kitchen", bgColor: "#111111")
        XCTAssertNil(l.overlayBgColorOn)
    }

    func testBadgeBackgroundOnPrefersBgColorOn() throws {
        let l = try linkWithBg("light.kitchen", bgColor: "#111111", bgColorOn: "#22FF22")
        let v = HA.visual(for: l, state: state("on"), stale: false)
        XCTAssertTrue(v.isOn)
        XCTAssertEqual(HA.badgeBackground(link: l, visual: v), HA.colorFromHex("#22FF22"))
    }

    /// No `bg_color_on` set -> falls back to `bg_color` even while on.
    func testBadgeBackgroundOnFallsBackToBgColorWhenNoBgColorOn() throws {
        let l = try linkWithBg("light.kitchen", bgColor: "#111111")
        let v = HA.visual(for: l, state: state("on"), stale: false)
        XCTAssertTrue(v.isOn)
        XCTAssertEqual(HA.badgeBackground(link: l, visual: v), HA.colorFromHex("#111111"))
    }

    /// Off NEVER consults `bg_color_on`, even when one is set.
    func testBadgeBackgroundOffNeverUsesBgColorOn() throws {
        let l = try linkWithBg("light.kitchen", bgColor: "#111111", bgColorOn: "#22FF22")
        let v = HA.visual(for: l, state: state("off"), stale: false)
        XCTAssertFalse(v.isOn)
        XCTAssertEqual(HA.badgeBackground(link: l, visual: v), HA.colorFromHex("#111111"))
    }

    /// Unknown/indeterminate NEVER consults `bg_color_on` either.
    func testBadgeBackgroundIndeterminateNeverUsesBgColorOn() throws {
        let l = try linkWithBg("sensor.kitchen", bgColor: "#111111", bgColorOn: "#22FF22")
        let v = HA.visual(for: l, state: state("unknown"), stale: false)
        XCTAssertTrue(v.indeterminate)
        XCTAssertFalse(v.isOn)
        XCTAssertEqual(HA.badgeBackground(link: l, visual: v), HA.colorFromHex("#111111"))
    }

    /// Stale NEVER consults `bg_color_on`, even for an entity whose last-known
    /// reading was "on" — same state-honesty invariant as the color dimming.
    func testBadgeBackgroundStaleNeverUsesBgColorOn() throws {
        let l = try linkWithBg("light.kitchen", bgColor: "#111111", bgColorOn: "#22FF22")
        let v = HA.visual(for: l, state: state("on"), stale: true)
        XCTAssertTrue(v.indeterminate)
        XCTAssertFalse(v.isOn)
        XCTAssertEqual(HA.badgeBackground(link: l, visual: v), HA.colorFromHex("#111111"))
    }

    /// Neither set -> the shared default badge background, on or off.
    func testBadgeBackgroundDefaultsWhenNeitherSet() throws {
        let l = try link("light.kitchen")
        let onVisual = HA.visual(for: l, state: state("on"), stale: false)
        let offVisual = HA.visual(for: l, state: state("off"), stale: false)
        XCTAssertEqual(HA.badgeBackground(link: l, visual: onVisual), HA.defaultBadgeBackground)
        XCTAssertEqual(HA.badgeBackground(link: l, visual: offVisual), HA.defaultBadgeBackground)
    }

    // MARK: - Pill layout (migration 0078, issue #497)

    /// An older server that omits the layout keys decodes to nil, which is
    /// today's rendering: a pill hugging its content, label at the leading edge.
    func testPillLayoutAbsentDecodesToNil() throws {
        let l = try link("binary_sensor.front")
        XCTAssertNil(l.overlayPillWidth)
        XCTAssertNil(l.overlayTextAlign)
        XCTAssertNil(HA.pillWidthFactor(l.overlayPillWidth))
        XCTAssertEqual(HA.pillAlignment(l.overlayTextAlign), .leading)
    }

    /// The frozen width vocabulary — the same numbers `services/api/src/ha.rs`,
    /// the desktop `haPillWidthFactor` and `HaBadgeMetrics.pillWidthFactor` use.
    /// A fixed width is a multiple of the badge HEIGHT, so `medium` is the same
    /// pill on every client and pane.
    func testPillWidthFactorVocabulary() {
        XCTAssertNil(HA.pillWidthFactor(nil))
        XCTAssertNil(HA.pillWidthFactor("auto"))
        XCTAssertEqual(HA.pillWidthFactor("narrow"), 4)
        XCTAssertEqual(HA.pillWidthFactor("medium"), 6)
        XCTAssertEqual(HA.pillWidthFactor("wide"), 8)
    }

    /// A value this build has never shipped degrades to auto rather than
    /// inventing a width.
    func testUnknownPillWidthDegradesToAuto() {
        for bad in ["", "AUTO", "huge", "fixed", "8"] {
            XCTAssertNil(HA.pillWidthFactor(bad), bad)
        }
    }

    /// Alignment vocabulary, with the same never-guess rule.
    func testPillAlignmentVocabulary() {
        XCTAssertEqual(HA.pillAlignment(nil), .leading)
        XCTAssertEqual(HA.pillAlignment("start"), .leading)
        XCTAssertEqual(HA.pillAlignment("center"), .center)
        XCTAssertEqual(HA.pillAlignment("end"), .trailing)
        for bad in ["", "left", "right", "justify", "CENTER"] {
            XCTAssertEqual(HA.pillAlignment(bad), .leading, bad)
        }
    }
}
