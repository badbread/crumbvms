// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import Crumb

/// Covers the binary parsing behind live fMP4 audio (`Fmp4Demuxer`): pulling the
/// AudioSpecificConfig out of an `esds` descriptor tree and decoding its
/// object-type / sample-rate / channel fields. These are the fiddly,
/// device-independent bits; the end-to-end decode-and-play path is vetted on a
/// physical device (an AAC-carrying camera through go2rtc).
final class Fmp4AudioTests: XCTestCase {

    // MARK: - AudioSpecificConfig field decoding

    func testParsesAacLc44100Stereo() {
        // 0x12 0x10 = AOT 2 (AAC-LC), samplingFrequencyIndex 4 (44100), 2 channels.
        let cfg = Fmp4Demuxer().parseAudioSpecificConfig(Data([0x12, 0x10]))
        XCTAssertEqual(cfg, Fmp4Demuxer.AacConfig(objectType: 2, sampleRate: 44100, channels: 2))
    }

    func testParsesAacLc48000Stereo() {
        // 0x11 0x90 = AOT 2, samplingFrequencyIndex 3 (48000), 2 channels.
        let cfg = Fmp4Demuxer().parseAudioSpecificConfig(Data([0x11, 0x90]))
        XCTAssertEqual(cfg, Fmp4Demuxer.AacConfig(objectType: 2, sampleRate: 48000, channels: 2))
    }

    func testRejectsTooShortConfig() {
        XCTAssertNil(Fmp4Demuxer().parseAudioSpecificConfig(Data([0x12])))
    }

    // MARK: - esds → AudioSpecificConfig extraction

    func testExtractsAscFromEsds() {
        // A minimal but well-formed esds: version/flags, ES_Descriptor (0x03) →
        // DecoderConfigDescriptor (0x04, AAC objectType 0x40) → DecoderSpecificInfo
        // (0x05, length 2) carrying the AudioSpecificConfig 0x12 0x10.
        let esds = Data([
            0x00, 0x00, 0x00, 0x00,             // version + flags
            0x03, 0x19,                         // ES_Descriptor tag + length
            0x00, 0x00,                         // ES_ID
            0x00,                               // ES flags (no dependency/URL/OCR)
            0x04, 0x11,                         // DecoderConfigDescriptor tag + length
            0x40,                               // objectTypeIndication = AAC
            0x15,                               // streamType
            0x00, 0x00, 0x00,                   // bufferSizeDB
            0x00, 0x00, 0x00, 0x00,             // maxBitrate
            0x00, 0x00, 0x00, 0x00,             // avgBitrate
            0x05, 0x02,                         // DecoderSpecificInfo tag + length
            0x12, 0x10,                         // AudioSpecificConfig
        ])
        let asc = Fmp4Demuxer().extractAudioSpecificConfig(esds)
        XCTAssertEqual(asc, Data([0x12, 0x10]))
    }

    func testExtractRejectsNonEsdsBytes() {
        XCTAssertNil(Fmp4Demuxer().extractAudioSpecificConfig(Data([0x00, 0x00, 0x00, 0x00, 0xFF])))
    }

    /// End-to-end sanity: the extracted ASC feeds straight into the field
    /// decoder, the exact chain `parseAudioTrak` uses to build the format.
    func testEsdsToConfigRoundTrip() {
        let esds = Data([
            0x00, 0x00, 0x00, 0x00,
            0x03, 0x19, 0x00, 0x00, 0x00,
            0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x02, 0x11, 0x90,
        ])
        let demuxer = Fmp4Demuxer()
        guard let asc = demuxer.extractAudioSpecificConfig(esds) else {
            return XCTFail("esds parse failed")
        }
        XCTAssertEqual(demuxer.parseAudioSpecificConfig(asc),
                       Fmp4Demuxer.AacConfig(objectType: 2, sampleRate: 48000, channels: 2))
    }
}
