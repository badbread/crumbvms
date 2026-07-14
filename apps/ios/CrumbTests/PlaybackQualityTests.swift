// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

/// Covers the quality model that governs live + recorded playback. The persisted
/// string values and the Full/Data-saver/Auto → low decision must stay identical
/// to Android's `PlaybackQuality` (`feature/playback/PlaybackScreen.kt`), so a
/// drift here is a cross-client parity bug.
final class PlaybackQualityTests: XCTestCase {

    // MARK: - persisted raw values (must match Android)

    func testRawValuesMatchAndroid() {
        XCTAssertEqual(PlaybackQuality.auto.rawValue, "auto")
        XCTAssertEqual(PlaybackQuality.full.rawValue, "full")
        // "Data saver" persists as "low", NOT "data_saver".
        XCTAssertEqual(PlaybackQuality.low.rawValue, "low")
    }

    func testPersistedInitToleratesNilAndUnknown() {
        XCTAssertEqual(PlaybackQuality(persisted: nil), .auto)      // default
        XCTAssertEqual(PlaybackQuality(persisted: ""), .auto)
        XCTAssertEqual(PlaybackQuality(persisted: "garbage"), .auto)
        XCTAssertEqual(PlaybackQuality(persisted: "auto"), .auto)
        XCTAssertEqual(PlaybackQuality(persisted: "full"), .full)
        XCTAssertEqual(PlaybackQuality(persisted: "low"), .low)
    }

    // MARK: - useLow decision (metered mapping)

    func testFullNeverUsesLow() {
        XCTAssertFalse(PlaybackQuality.full.useLow(metered: false))
        XCTAssertFalse(PlaybackQuality.full.useLow(metered: true))
    }

    func testDataSaverAlwaysUsesLow() {
        XCTAssertTrue(PlaybackQuality.low.useLow(metered: false))
        XCTAssertTrue(PlaybackQuality.low.useLow(metered: true))
    }

    func testAutoFollowsMetered() {
        XCTAssertFalse(PlaybackQuality.auto.useLow(metered: false)) // Wi-Fi → full
        XCTAssertTrue(PlaybackQuality.auto.useLow(metered: true))   // cellular → low
    }

    // MARK: - one-tap cycle order (Auto → Full → Data saver → Auto)

    func testCycleOrderMatchesAndroid() {
        XCTAssertEqual(PlaybackQuality.auto.next, .full)
        XCTAssertEqual(PlaybackQuality.full.next, .low)
        XCTAssertEqual(PlaybackQuality.low.next, .auto)
    }

    // MARK: - badge labels

    func testShortBadges() {
        XCTAssertEqual(PlaybackQuality.full.short, "HD")
        XCTAssertEqual(PlaybackQuality.low.short, "SD")
        XCTAssertEqual(PlaybackQuality.auto.short, "AUTO")
    }
}
