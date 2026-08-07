// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

/// Value-control descriptor decoding + offered-slider gating (issue #442
/// Slice 1, PR #460): `HaEntityState.control` must decode defensively (an
/// older server that omits it decodes exactly as today via the synthesized
/// `decodeIfPresent`), and the slider is offered only when the descriptor is
/// present AND (allowed_actions is nil OR includes the descriptor's action
/// word) — mirroring `HaControlConfigTests`' button-gating pattern.
final class HaValueControlTests: XCTestCase {

    private func decodeState(_ jsonBody: String) throws -> HaEntityState {
        try JSONDecoder().decode(HaEntityState.self, from: Data(jsonBody.utf8))
    }

    private func decodeLink(_ jsonBody: String) throws -> HaLink {
        try JSONDecoder().decode(HaLink.self, from: Data(jsonBody.utf8))
    }

    /// Mirrors `HAStateCard.valueControl`'s derivation without the SwiftUI view:
    /// present iff the state carries a `control` descriptor and, when the link
    /// restricts actions, the descriptor's action word is one of them.
    private func offeredControl(link: HaLink, state: HaEntityState) -> HaControlDescriptor? {
        guard let control = state.control else { return nil }
        guard link.actionAllowed(control.action) else { return nil }
        return control
    }

    // MARK: - Decoding

    func testOlderServerPayloadOmittingControlDecodesToNil() throws {
        let state = try decodeState(
            #"{"entity_id":"light.kitchen","state":"on"}"#
        )
        XCTAssertNil(state.control)
    }

    func testControlDescriptorDecodesFullPayload() throws {
        let state = try decodeState(
            #"""
            {"entity_id":"light.kitchen","state":"on",
             "control":{"action":"set_brightness","kind":"percent","value":62,"min":0,"max":100,"step":1,"unit":null}}
            """#
        )
        let control = try XCTUnwrap(state.control)
        XCTAssertEqual(control.action, "set_brightness")
        XCTAssertEqual(control.kind, "percent")
        XCTAssertEqual(control.value, 62)
        XCTAssertEqual(control.min, 0)
        XCTAssertEqual(control.max, 100)
        XCTAssertEqual(control.step, 1)
        XCTAssertNil(control.unit)
    }

    func testControlDescriptorWithMissingSubfieldsDecodesDefensively() throws {
        // A leaner payload than the frozen contract promises — every numeric
        // field is individually optional, so this must still decode rather
        // than fail the whole entity state.
        let state = try decodeState(
            #"{"entity_id":"cover.garage","state":"open","control":{"action":"set_position","kind":"percent"}}"#
        )
        let control = try XCTUnwrap(state.control)
        XCTAssertEqual(control.action, "set_position")
        XCTAssertNil(control.value)
        XCTAssertNil(control.min)
        XCTAssertNil(control.max)
        XCTAssertNil(control.step)
    }

    // MARK: - Offered-slider gating

    func testNoControlDescriptorMeansNoSlider() throws {
        let link = try decodeLink(
            #"{"id":"l1","entity_id":"light.kitchen","role":"actuator","sort_order":0}"#
        )
        let state = try decodeState(#"{"entity_id":"light.kitchen","state":"on"}"#)
        XCTAssertNil(offeredControl(link: link, state: state))
    }

    func testControlDescriptorOfferedWhenAllowedActionsIsNil() throws {
        let link = try decodeLink(
            #"{"id":"l2","entity_id":"light.kitchen","role":"actuator","sort_order":0}"#
        )
        let state = try decodeState(
            #"""
            {"entity_id":"light.kitchen","state":"on",
             "control":{"action":"set_brightness","kind":"percent","value":40,"min":0,"max":100,"step":1,"unit":null}}
            """#
        )
        XCTAssertEqual(offeredControl(link: link, state: state)?.action, "set_brightness")
    }

    func testControlDescriptorOfferedWhenAllowedActionsIncludesTheValueWord() throws {
        let link = try decodeLink(
            #"""
            {"id":"l3","entity_id":"cover.garage","role":"actuator","sort_order":0,
             "allowed_actions":["open_cover","close_cover","set_position"]}
            """#
        )
        let state = try decodeState(
            #"""
            {"entity_id":"cover.garage","state":"open",
             "control":{"action":"set_position","kind":"percent","value":75,"min":0,"max":100,"step":1,"unit":null}}
            """#
        )
        XCTAssertEqual(offeredControl(link: link, state: state)?.action, "set_position")
    }

    func testControlDescriptorSuppressedWhenAllowedActionsExcludesTheValueWord() throws {
        // A link restricted to exactly open/close (no set_position) must not
        // offer the slider, even though the state carries a descriptor.
        let link = try decodeLink(
            #"""
            {"id":"l4","entity_id":"cover.garage","role":"actuator","sort_order":0,
             "allowed_actions":["open_cover","close_cover"]}
            """#
        )
        let state = try decodeState(
            #"""
            {"entity_id":"cover.garage","state":"open",
             "control":{"action":"set_position","kind":"percent","value":75,"min":0,"max":100,"step":1,"unit":null}}
            """#
        )
        XCTAssertNil(offeredControl(link: link, state: state))
    }

    // MARK: - Slider label formatting (mirrors HAValueSlider.label)

    func testPercentLabelFormatting() throws {
        let state = try decodeState(
            #"""
            {"entity_id":"fan.bedroom","state":"on",
             "control":{"action":"set_speed","kind":"percent","value":33,"min":0,"max":100,"step":25,"unit":null}}
            """#
        )
        let control = try XCTUnwrap(state.control)
        XCTAssertEqual(HAValueSlider.label(for: 33, control: control), "33%")
    }

    // MARK: - Post-commit hold (issue #465: slider bounce-back on release)

    /// The poll converges once it lands within a step (plus the rounding margin)
    /// of the committed value; until then the thumb keeps holding the commit so
    /// the transitioning OLD value can't snap it back — the #465 bounce.
    func testHoldConvergesWithinAStepPlusMargin() {
        // Exact hit converges.
        XCTAssertTrue(HAValueSlider.holdConverged(polled: 60, committed: 60, step: 1))
        // Off by one step (percent↔brightness rounding) still converges.
        XCTAssertTrue(HAValueSlider.holdConverged(polled: 59, committed: 60, step: 1))
        XCTAssertTrue(HAValueSlider.holdConverged(polled: 61, committed: 60, step: 1))
        // Coarser grids honor their own step.
        XCTAssertTrue(HAValueSlider.holdConverged(polled: 50, committed: 75, step: 25))
    }

    /// The device's transitioning OLD value (still far from target) must NOT be
    /// treated as converged, or the thumb would bounce back to it.
    func testHoldDoesNotConvergeOnTheStaleTransitioningValue() {
        // Released at 80 but the first poll still reports the old 20 → hold.
        XCTAssertFalse(HAValueSlider.holdConverged(polled: 20, committed: 80, step: 1))
        // Two steps away on a step=25 grid is still a genuine mismatch.
        XCTAssertFalse(HAValueSlider.holdConverged(polled: 25, committed: 75, step: 25))
    }

    /// On release the raw drag position is clamped and snapped to the
    /// descriptor's grid (never a hardcoded 0...100) so the POSTed value is
    /// step-aligned even though the slider tracks the finger continuously.
    func testSnapToStepQuantizesAndClampsTheReleasedValue() {
        // step=25 grid: 63 rounds to 75, 62 rounds to 50.
        XCTAssertEqual(HAValueSlider.snapToStep(63, min: 0, max: 100, step: 25), 75)
        XCTAssertEqual(HAValueSlider.snapToStep(62, min: 0, max: 100, step: 25), 50)
        // Clamps outside the range.
        XCTAssertEqual(HAValueSlider.snapToStep(140, min: 0, max: 100, step: 1), 100)
        XCTAssertEqual(HAValueSlider.snapToStep(-5, min: 0, max: 100, step: 1), 0)
        // Grid measured from a non-zero min (e.g. a 10–30 °C thermostat, step 0.5).
        XCTAssertEqual(HAValueSlider.snapToStep(21.2, min: 10, max: 30, step: 0.5), 21)
        // A degenerate step falls back to 1 rather than dividing by zero.
        XCTAssertEqual(HAValueSlider.snapToStep(7.4, min: 0, max: 100, step: 0), 7)
    }

    // MARK: - Confirm gate (issue #505)

    /// A value commit confirms under exactly the same conditions a discrete
    /// action does: the link's own `require_confirm`, or a physical-security
    /// domain. Everything else fires straight away, like a light's brightness.
    func testValueConfirmGateMatchesThePhysicalSecurityDomains() throws {
        let cover = try decodeLink(
            #"{"id":"c1","entity_id":"cover.garage","role":"actuator","sort_order":0}"#
        )
        let lock = try decodeLink(
            #"{"id":"c2","entity_id":"lock.front","role":"actuator","sort_order":0}"#
        )
        let light = try decodeLink(
            #"{"id":"c3","entity_id":"light.kitchen","role":"actuator","sort_order":0}"#
        )
        let confirmingLight = try decodeLink(
            #"""
            {"id":"c4","entity_id":"light.kitchen","role":"actuator","sort_order":0,
             "require_confirm":true}
            """#
        )
        XCTAssertTrue(HA.valueNeedsConfirm(cover))
        XCTAssertTrue(HA.valueNeedsConfirm(lock))
        XCTAssertTrue(HA.valueNeedsConfirm(confirmingLight))
        XCTAssertFalse(HA.valueNeedsConfirm(light))
    }

    // MARK: - Release decision (issue #505a: a cancelled confirm must not pin)

    /// An ungated release fires immediately AND is allowed to pin the thumb —
    /// the `.commit` case is the only one that sets the post-commit hold.
    func testUngatedReleaseCommitsTheSnappedTarget() {
        XCTAssertEqual(
            HAValueSlider.releaseDecision(raw: 63, needsConfirm: false, min: 0, max: 100, step: 25),
            .commit(75)
        )
    }

    /// A confirm-gated release must NOT commit: nothing has been POSTed yet, so
    /// no hold may be set. It only asks, carrying the same step-snapped target.
    func testConfirmGatedReleaseAsksInsteadOfCommitting() {
        XCTAssertEqual(
            HAValueSlider.releaseDecision(raw: 78, needsConfirm: true, min: 0, max: 100, step: 5),
            .confirm(80)
        )
    }

    // MARK: - Thumb sync (issue #505b: every hold-clear path resumes tracking)

    /// While the confirm prompt is up the thumb shows the value being asked
    /// about; a poll tick must not yank it out from under the prompt.
    func testThumbIgnoresThePollWhileAConfirmIsPending() {
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: 20, fallback: 0, dragging: false,
                                    awaitingConfirm: true, committed: nil, step: 1),
            .ignore
        )
    }

    /// Cancelling the confirm clears `awaitingConfirm` with no hold ever set, so
    /// the very next sync reverts the thumb to the live polled value — a cover
    /// asked to go to 80 and then cancelled reads its real 20 again.
    func testCancelledConfirmRevertsTheThumbToTheLiveValue() {
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: 20, fallback: 0, dragging: false,
                                    awaitingConfirm: false, committed: nil, step: 1),
            .follow(20)
        )
    }

    /// A mid-drag poll tick never moves the thumb, confirm or no confirm.
    func testThumbIgnoresThePollMidDrag() {
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: 20, fallback: 0, dragging: true,
                                    awaitingConfirm: false, committed: 80, step: 1),
            .ignore
        )
    }

    /// The #465 hold still works: a committed target the device is transitioning
    /// to keeps the thumb pinned rather than bouncing to the stale old value.
    func testHoldKeepsTheThumbWhileTheDeviceIsStillTransitioning() {
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: 20, fallback: 0, dragging: false,
                                    awaitingConfirm: false, committed: 80, step: 1),
            .hold
        )
    }

    /// Clearing the hold (a failed/rejected POST, or the safety timeout) resumes
    /// tracking on the SAME polled value that was in play when the hold was set.
    /// This is the #505b regression: keying the re-seed only on the polled value
    /// meant an unchanged poll never fired it and the thumb stayed stranded at
    /// the target — a cover slider reading 80% over a cover sitting at 20%.
    func testClearingTheHoldResumesTrackingWithoutAFreshPollValue() {
        // Hold set at 80 while the poll still reports 20 → pinned.
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: 20, fallback: 0, dragging: false,
                                    awaitingConfirm: false, committed: 80, step: 1),
            .hold
        )
        // The POST is rejected, the hold is dropped, the poll has NOT moved.
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: 20, fallback: 0, dragging: false,
                                    awaitingConfirm: false, committed: nil, step: 1),
            .follow(20)
        )
    }

    /// A hold whose poll has converged releases itself and follows the live
    /// value — the ordinary happy path after a successful commit.
    func testConvergedHoldFollowsTheLiveValue() {
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: 79, fallback: 0, dragging: false,
                                    awaitingConfirm: false, committed: 80, step: 1),
            .follow(79)
        )
    }

    /// With no live value at all the thumb falls back to the descriptor's `min`,
    /// the value the slider seeds itself with — never left parked on a target
    /// nothing ever confirmed.
    func testThumbFallsBackToTheSeedWhenHaHasReportedNoValue() {
        XCTAssertEqual(
            HAValueSlider.thumbSync(polled: nil, fallback: 10, dragging: false,
                                    awaitingConfirm: false, committed: nil, step: 0.5),
            .follow(10)
        )
    }
}
