// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CoreMedia

/// Incremental fragmented-MP4 demuxer for a live HTTP stream. Parses the box
/// stream as bytes arrive, builds a `CMVideoFormatDescription` from the `moov`
/// (HEVC `hvc1` or AVC `avc1`), and emits one `CMSampleBuffer` per video access
/// unit from each `moof`+`mdat` fragment — flagged for immediate display so live
/// latency stays low. Audio tracks are ignored.
///
/// NOT thread-safe; the owning controller confines it to a single serial queue.
final class Fmp4Demuxer {

    var onSample: ((CMSampleBuffer) -> Void)?

    private var buffer = Data()
    private var formatDesc: CMFormatDescription?
    private var videoTrackId: UInt32?
    private var nalLengthSize = 4

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        videoTrackId = nil
        nalLengthSize = 4
    }

    func feed(_ data: Data) {
        buffer.append(data)
        parse()
        // Guard against unbounded growth if resync (below) somehow still can't
        // find a valid box boundary within a bounded window (e.g. a very long
        // run of garbage) — drop the buffer and wait for a clean restart
        // rather than growing forever.
        if buffer.count > 8_000_000 { buffer.removeAll(keepingCapacity: true) }
    }

    // MARK: - Top-level box loop

    private func parse() {
        var offset = 0
        let count = buffer.count
        parseLoop: while count - offset >= 8 {
            guard let (type, headerSize, boxSize) = boxHeader(buffer, offset) else { break }
            guard boxSize >= headerSize else {
                // M7: malformed box (declared size shorter than its own
                // header) — a discontinuity/corrupt box, not "wait for more
                // data" (that's the `boxHeader == nil` case above, already
                // handled). Previously this just `break`, stalling the parse
                // loop at `offset` until the 8MB safety-valve in `feed`
                // eventually wiped the whole buffer (losing far more than the
                // one bad box). Instead, resync: scan forward for the next
                // plausible top-level box boundary and resume there.
                if let resync = findResyncPoint(buffer, from: offset + 1, limit: count) {
                    offset = resync
                    continue
                }
                break parseLoop // no plausible boundary within the buffered window yet — wait for more bytes
            }
            guard offset + boxSize <= count else { break }        // incomplete — wait for more

            let payload = (offset + headerSize)..<(offset + boxSize)
            switch type {
            case "moov":
                parseMoov(buffer.subdata(in: payload))
            case "moof":
                // Need the following mdat too; only consume the pair together so the
                // moof's data_offset (relative to moof start) stays valid.
                if let consumed = handleFragment(moofStart: offset, moofPayload: payload, totalCount: count) {
                    offset = consumed
                    continue
                } else {
                    // mdat not fully buffered yet — stop, but still trim the already-
                    // processed fragments below so they aren't re-emitted as duplicates
                    // (which jams the display layer). Labeled break exits the WHILE, not
                    // just the switch — leaving the incomplete moof at the buffer head.
                    break parseLoop
                }
            default:
                break // ftyp, styp, sidx, free, mdat-without-moof, etc.
            }
            offset += boxSize
        }
        if offset > 0 { buffer.removeSubrange(0..<offset) }
    }

    /// M7 resync: scan `buffer[from..<limit]` byte-by-byte for the next offset
    /// that looks like a genuine top-level box start — a recognized ISO-BMFF
    /// fourCC at `+4` with a size field that's at least a plausible header
    /// length and doesn't overrun any bytes we've already confirmed are
    /// buffered. Returns nil if no such point is found in the scanned window
    /// (caller then waits for more bytes rather than scanning unboundedly).
    private func findResyncPoint(_ d: Data, from: Int, limit: Int) -> Int? {
        // Any box type this demuxer or a conformant fMP4 stream can emit at
        // the top level. `mdat` is intentionally included even though we
        // normally only reach it via `handleFragment` (paired with its
        // `moof`) — after a corrupt/truncated moof we may land mid-mdat, and
        // recognizing it here still gets us back to a real box boundary even
        // though its payload (orphaned without a preceding moof) is skipped.
        let known: Set<String> = ["ftyp", "styp", "moov", "moof", "mdat", "free", "skip", "sidx", "prft", "emsg"]
        var i = from
        while i + 8 <= limit {
            let type = fourCC(d, i + 4)
            if known.contains(type) {
                let size32 = Int(beU32(d, i))
                // A real box here must declare a size that's at least an
                // ordinary 8-byte header and must not claim to run past the
                // bytes we've actually buffered (extended/size-0 boxes are
                // fine — size32 of 0 or 1 pass this check trivially and are
                // re-validated by `boxHeader` on the next loop iteration).
                if size32 == 0 || size32 == 1 || (size32 >= 8 && i + size32 <= limit) {
                    return i
                }
            }
            i += 1
        }
        return nil
    }

    /// Process a `moof`+`mdat` pair. Returns the new top-level offset (just past the
    /// mdat) on success, or nil if the mdat isn't fully buffered yet.
    private func handleFragment(moofStart: Int, moofPayload: Range<Int>, totalCount: Int) -> Int? {
        let moofEnd = moofPayload.upperBound
        guard let (mtype, mhdr, msize) = boxHeader(buffer, moofEnd), mtype == "mdat" else {
            // If the next box isn't a complete mdat yet, wait.
            if totalCount - moofEnd < 8 { return nil }
            // Next box is something else (e.g. another moof) — skip this moof.
            return moofEnd
        }
        let mdatEnd = moofEnd + msize
        guard mdatEnd <= totalCount else { return nil } // mdat incomplete

        if let fd = formatDesc, let trun = parseMoof(buffer.subdata(in: moofPayload)) {
            // Sample data starts at moofStart + data_offset within `buffer`.
            var pos = moofStart + trun.dataOffset
            for size in trun.sampleSizes {
                guard pos >= 0, pos + size <= mdatEnd, size > 0 else { break }
                if let sb = makeSampleBuffer(buffer.subdata(in: pos..<(pos + size)), formatDesc: fd) {
                    onSample?(sb)
                }
                pos += size
            }
            _ = mhdr
        }
        return mdatEnd
    }

    // MARK: - moov (format description)

    private func parseMoov(_ moov: Data) {
        // Find the video trak: a trak whose mdia/hdlr handler is 'vide'.
        for trak in childBoxes(moov, "trak") {
            let trakData = moov.subdata(in: trak)
            guard let mdia = firstBox(trakData, "mdia") else { continue }
            let mdiaData = trakData.subdata(in: mdia)
            guard let hdlr = firstBox(mdiaData, "hdlr") else { continue }
            let hdlrData = mdiaData.subdata(in: hdlr)
            // hdlr: version/flags(4) pre_defined(4) handler_type(4)…
            guard hdlrData.count >= 12, fourCC(hdlrData, 8) == "vide" else { continue }

            // track_ID from tkhd.
            if let tkhd = firstBox(trakData, "tkhd") {
                let t = trakData.subdata(in: tkhd)
                let version = t.count > 0 ? t[0] : 0
                // version 0: id at offset 12 (after ver/flags 4 + create 4 + modify 4)
                // version 1: create/modify are 8 bytes each → id at offset 20
                let idOff = version == 1 ? 20 : 12
                if t.count >= idOff + 4 { videoTrackId = beU32(t, idOff) }
            }

            // stsd → hvc1/avc1 → config.
            guard let minf = firstBox(mdiaData, "minf") else { continue }
            let minfData = mdiaData.subdata(in: minf)
            guard let stbl = firstBox(minfData, "stbl") else { continue }
            let stblData = minfData.subdata(in: stbl)
            guard let stsd = firstBox(stblData, "stsd") else { continue }
            let stsdData = stblData.subdata(in: stsd)
            // stsd: version/flags(4) entry_count(4) then entry box.
            guard stsdData.count > 8 else { continue }
            let entry = stsdData.subdata(in: 8..<stsdData.count)
            guard let (etype, _, esize) = boxHeader(entry, 0), esize <= entry.count else { continue }
            // VisualSampleEntry: 8 (size+type) + 78 fixed bytes, then child boxes.
            let childStart = 8 + 78
            guard entry.count > childStart else { continue }
            let children = entry.subdata(in: childStart..<min(esize, entry.count))

            if etype == "hvc1" || etype == "hev1" {
                if let hvcc = firstBox(children, "hvcC") {
                    formatDesc = makeHEVCFormat(children.subdata(in: hvcc))
                    return
                }
            } else if etype == "avc1" || etype == "avc3" {
                if let avcc = firstBox(children, "avcC") {
                    formatDesc = makeAVCFormat(children.subdata(in: avcc))
                    return
                }
            }
        }
    }

    // MARK: - moof (sample sizes + data offset)

    private struct TrunInfo { var dataOffset: Int; var sampleSizes: [Int] }

    private func parseMoof(_ moof: Data) -> TrunInfo? {
        for traf in childBoxes(moof, "traf") {
            let trafData = moof.subdata(in: traf)
            guard let tfhd = firstBox(trafData, "tfhd") else { continue }
            let tfhdData = trafData.subdata(in: tfhd)
            guard tfhdData.count >= 8 else { continue }
            let tfhdFlags = beU32(tfhdData, 0) & 0x00FF_FFFF
            let trackId = beU32(tfhdData, 4)
            if let vid = videoTrackId, trackId != vid { continue } // skip audio traf

            // Default sample size lives in tfhd when present (flag 0x10).
            var defaultSampleSize = 0
            do {
                var p = 8
                if tfhdFlags & 0x1 != 0 { p += 8 }   // base_data_offset
                if tfhdFlags & 0x2 != 0 { p += 4 }   // sample_description_index
                if tfhdFlags & 0x8 != 0 { p += 4 }   // default_sample_duration
                if tfhdFlags & 0x10 != 0 {           // default_sample_size
                    if tfhdData.count >= p + 4 { defaultSampleSize = Int(beU32(tfhdData, p)) }
                }
            }

            guard let trun = firstBox(trafData, "trun") else { continue }
            let t = trafData.subdata(in: trun)
            guard t.count >= 8 else { continue }
            let flags = beU32(t, 0) & 0x00FF_FFFF
            let sampleCount = Int(beU32(t, 4))
            var p = 8
            var dataOffset = 0
            if flags & 0x1 != 0 { // data_offset present (signed, relative to moof start)
                if t.count >= p + 4 { dataOffset = Int(Int32(bitPattern: beU32(t, p))) }
                p += 4
            }
            if flags & 0x4 != 0 { p += 4 } // first_sample_flags

            let hasDuration = flags & 0x100 != 0
            let hasSize = flags & 0x200 != 0
            let hasFlags = flags & 0x400 != 0
            let hasCTS = flags & 0x800 != 0

            var sizes: [Int] = []
            sizes.reserveCapacity(sampleCount)
            for _ in 0..<sampleCount {
                if hasDuration { p += 4 }
                var size = defaultSampleSize
                if hasSize { if t.count >= p + 4 { size = Int(beU32(t, p)) }; p += 4 }
                if hasFlags { p += 4 }
                if hasCTS { p += 4 }
                sizes.append(size)
            }
            return TrunInfo(dataOffset: dataOffset, sampleSizes: sizes)
        }
        return nil
    }

    // MARK: - CMSampleBuffer

    private func makeSampleBuffer(_ data: Data, formatDesc: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = data.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sampleSize = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // Display each access unit as soon as it decodes — lowest live latency.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    // MARK: - Parameter-set → format description

    private func makeHEVCFormat(_ hvcc: Data) -> CMFormatDescription? {
        // HEVCDecoderConfigurationRecord: 22-byte header, then numOfArrays(1), then
        // arrays of [NAL_type(1)][numNalus(2)]([nalLen(2)][nal])*.
        guard hvcc.count > 23 else { return nil }
        nalLengthSize = Int(hvcc[21] & 0x3) + 1
        var p = 22
        let numArrays = Int(hvcc[p]); p += 1
        var params: [[UInt8]] = []
        for _ in 0..<numArrays {
            guard hvcc.count >= p + 3 else { break }
            p += 1 // array_completeness + NAL_unit_type
            let numNalus = Int(beU16(hvcc, p)); p += 2
            for _ in 0..<numNalus {
                guard hvcc.count >= p + 2 else { break }
                let len = Int(beU16(hvcc, p)); p += 2
                guard hvcc.count >= p + len else { break }
                params.append([UInt8](hvcc.subdata(in: p..<(p + len))))
                p += len
            }
        }
        guard params.count >= 3 else { return nil }
        var fd: CMFormatDescription?
        let status = params.withUnsafeParameterSets { ptrs, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: params.count,
                parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLengthSize), extensions: nil, formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }

    private func makeAVCFormat(_ avcc: Data) -> CMFormatDescription? {
        // AVCDecoderConfigurationRecord: 5-byte header, numSPS(1, low 5 bits), SPS*,
        // numPPS(1), PPS*.
        guard avcc.count > 6 else { return nil }
        nalLengthSize = Int(avcc[4] & 0x3) + 1
        var p = 5
        var params: [[UInt8]] = []
        let numSPS = Int(avcc[p] & 0x1F); p += 1
        for _ in 0..<numSPS {
            guard avcc.count >= p + 2 else { break }
            let len = Int(beU16(avcc, p)); p += 2
            guard avcc.count >= p + len else { break }
            params.append([UInt8](avcc.subdata(in: p..<(p + len)))); p += len
        }
        guard avcc.count > p else { return nil }
        let numPPS = Int(avcc[p]); p += 1
        for _ in 0..<numPPS {
            guard avcc.count >= p + 2 else { break }
            let len = Int(beU16(avcc, p)); p += 2
            guard avcc.count >= p + len else { break }
            params.append([UInt8](avcc.subdata(in: p..<(p + len)))); p += len
        }
        guard params.count >= 2 else { return nil }
        var fd: CMFormatDescription?
        let status = params.withUnsafeParameterSets { ptrs, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: params.count,
                parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLengthSize), formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }
}

// MARK: - Box helpers (all offsets are 0-based into a freshly-copied Data)

private func beU16(_ d: Data, _ o: Int) -> UInt16 { (UInt16(d[d.startIndex + o]) << 8) | UInt16(d[d.startIndex + o + 1]) }
private func beU32(_ d: Data, _ o: Int) -> UInt32 {
    let b = d.startIndex + o
    return (UInt32(d[b]) << 24) | (UInt32(d[b + 1]) << 16) | (UInt32(d[b + 2]) << 8) | UInt32(d[b + 3])
}
private func beU64(_ d: Data, _ o: Int) -> UInt64 { (UInt64(beU32(d, o)) << 32) | UInt64(beU32(d, o + 4)) }
private func fourCC(_ d: Data, _ o: Int) -> String {
    let b = d.startIndex + o
    let bytes = [d[b], d[b + 1], d[b + 2], d[b + 3]]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

/// (type, headerSize, totalBoxSize) at `offset`, or nil if not enough bytes.
private func boxHeader(_ d: Data, _ offset: Int) -> (String, Int, Int)? {
    guard d.count - offset >= 8 else { return nil }
    let size32 = Int(beU32(d, offset))
    let type = fourCC(d, offset + 4)
    if size32 == 1 {
        guard d.count - offset >= 16 else { return nil }
        return (type, 16, Int(beU64(d, offset + 8)))
    } else if size32 == 0 {
        return (type, 8, d.count - offset) // extends to end
    }
    return (type, 8, size32)
}

/// Payload ranges (after the header, i.e. the children) of every direct child box
/// of the given type — matching `firstBox` so nested lookups work.
private func childBoxes(_ d: Data, _ type: String) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var i = 0
    while d.count - i >= 8 {
        guard let (t, hdr, size) = boxHeader(d, i), size >= hdr, i + size <= d.count else { break }
        if t == type { result.append((i + hdr)..<(i + size)) }
        i += size
    }
    return result
}

/// Payload range (after the header) of the first direct child box of `type`.
private func firstBox(_ d: Data, _ type: String) -> Range<Int>? {
    var i = 0
    while d.count - i >= 8 {
        guard let (t, hdr, size) = boxHeader(d, i), size >= hdr, i + size <= d.count else { break }
        if t == type { return (i + hdr)..<(i + size) }
        i += size
    }
    return nil
}

private extension Array where Element == [UInt8] {
    /// Call `body` with parallel C arrays of parameter-set pointers and sizes, all
    /// valid for the duration of the call (nested `withUnsafeBufferPointer`).
    func withUnsafeParameterSets<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func recurse(_ i: Int) -> R {
            if i == count {
                return pointers.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { sp in
                        body(pp.baseAddress!, sp.baseAddress!)
                    }
                }
            }
            return self[i].withUnsafeBufferPointer { bp in
                pointers.append(bp.baseAddress!)
                sizes.append(bp.count)
                return recurse(i + 1)
            }
        }
        return recurse(0)
    }
}
