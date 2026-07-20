// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import AVFoundation

/// Instant-seek playback for recorded fMP4 segments, with an HEVC `hev1`→`hvc1`
/// sample-entry retag applied **only when required** and **without downloading
/// the media payload**.
///
/// ## Background
///
/// The recorder muxes segments with `ffmpeg -c copy` into fragmented MP4.
/// ffmpeg's default HEVC sample-entry FourCC is `hev1`, which **AVFoundation
/// refuses to decode** (it requires `hvc1`). ExoPlayer on Android accepts both.
/// The fix on the server is `-tag:v hvc1`, but that only affects newly recorded
/// footage — existing `hev1` segments need a client-side retag.
///
/// ## The old approach (rejected — mediocre seek)
///
/// The previous implementation routed every segment through an
/// `AVAssetResourceLoaderDelegate` that downloaded the **entire segment** over
/// HTTP before answering any loading request, patched the whole buffer in
/// memory, and served every byte range out of that buffer. That means a
/// scrubber jump had to wait for a full-segment download before the player
/// could even start decoding — not "instant seek" by any definition.
///
/// ## The new approach (top-in-class)
///
/// 1. **Probe, don't download** (`RemuxRequirement.probe`). A single small
///    `Range:` GET (a few KB) reads just the `ftyp`+`moov` header far enough to
///    find the video sample entry's FourCC. If it's already `hvc1`, or the
///    segment is AVC (`avc1`/`avc3`) or has no video track we recognize, no
///    retag is needed at all.
/// 2. **No retag needed → hand AVPlayer the origin URL directly.** A plain
///    `AVURLAsset(url:)` against the tokened `/segments/{id}?token=...` URL
///    lets AVPlayer/AVFoundation do its own native HTTP range requests via
///    `URLSession` under the hood — the server (`ServeFile`) already supports
///    `Range:`/`206`, so seeking is exactly as instant as it would be for any
///    ordinary progressive-download HTTP asset: no app code sits in the
///    loading path at all.
/// 3. **Retag needed → range-streamed custom-scheme asset.**
///    `HEVCRetagLoaderDelegate` intercepts loading requests on the
///    `crumbhevc://` scheme:
///    - It fetches ONLY the `moov` box's bytes (via `Range:`), patches
///      `hev1`→`hvc1` in memory (the existing byte-for-byte rewrite — correct,
///      unchanged), and caches that small patched header.
///    - Any loading request that falls entirely within the patched header
///      range is served from that in-memory buffer.
///    - Every other byte range (i.e. `moof`/`mdat` — the actual media
///      samples, which dwarf the header in size) is **proxied straight
///      through** to the origin server with a matching `Range:` header, and
///      the response bytes are streamed back to AVFoundation as they arrive.
///      Nothing beyond the header is ever fully buffered.
///
///    This means a scrubber jump to a new time in an `hev1` segment triggers:
///    header fetch (already cached after the first request for that segment)
///    + one bounded Range GET for the samples AVFoundation actually needs to
///    resume decoding at that offset — never the whole file.
///
/// 4. **Fallback.** If the probe fails (network hiccup, unexpected box
///    layout, anything not confidently parseable), we fall back to the
///    old-style whole-segment download-and-patch path rather than failing
///    playback outright. Correctness beats performance when we can't be sure.
enum HEVCRetag {

    static let scheme = "crumbhevc"

    /// Swap an authed segment URL's scheme to the retag scheme so AVPlayer routes
    /// it through `HEVCRetagLoaderDelegate`. The delegate is constructed with the
    /// original URL to fetch the real bytes.
    static func customSchemeURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.scheme = scheme
        return comps.url ?? url
    }

    /// Whether `moov`'s video sample entry needs the `hev1`→`hvc1` retag.
    enum RemuxRequirement {
        /// No retag needed — hand AVPlayer the origin URL directly for fully
        /// native, zero-pre-download HTTP range seeking.
        case passthrough
        /// `hev1` found — needs the header-only retag + range-proxy path.
        case retagRequired
        /// Couldn't confidently determine the sample entry (short read, odd
        /// box layout, network error) — fall back to the old safe-but-slow
        /// whole-segment download path rather than risk a black/broken player.
        case unknown
    }

    /// Range-fetch just the front of `url` (enough to contain `ftyp`+`moov` in
    /// the overwhelming majority of segments — fragmented-MP4 muxers place the
    /// moov box immediately after ftyp, before any moof/mdat) and inspect the
    /// video sample entry's FourCC. Never downloads the media payload.
    ///
    /// - Returns: `.passthrough` for `hvc1`/`avc1`/`avc3` (or no video track
    ///   found at all — nothing to retag), `.retagRequired` for `hev1`,
    ///   `.unknown` if the probe is inconclusive.
    static func probe(url: URL) async -> RemuxRequirement {
        do {
            let header = try await fetchMoovHeader(url: url, budget: probeInitialBudget)
            switch header.sampleEntry {
            case "hev1": return .retagRequired
            case "hvc1", "avc1", "avc3": return .passthrough
            case nil where header.moovComplete: return .passthrough // no video trak — nothing to retag
            default: return .unknown // moov box wasn't fully within budget, or unrecognized entry
            }
        } catch {
            return .unknown
        }
    }

    // MARK: - moov header fetch (shared by probe + loader delegate)

    /// Growing the initial range-fetch budget keeps the common case (small
    /// moov) to a single round trip while still bounding worst-case segments.
    fileprivate static let probeInitialBudget = 64 * 1024
    fileprivate static let probeMaxBudget = 4 * 1024 * 1024

    fileprivate struct MoovHeader {
        /// Byte offset just past the end of the `moov` box (i.e. where
        /// `moof`/`mdat` begin) — the boundary between "header" and "media".
        let moovEnd: Int
        /// The full header bytes (`ftyp` through `moov`, patched in place for
        /// `hev1`→`hvc1` by the caller as needed), from offset 0.
        let bytes: Data
        /// The video sample entry FourCC found inside `moov`'s `stsd`, if any.
        let sampleEntry: String?
        /// True if we read enough bytes to see the whole `moov` box (i.e. the
        /// header is authoritative — no video trak means "nothing to retag",
        /// not "inconclusive").
        let moovComplete: Bool
    }

    /// Range-fetch growing prefixes of `url` until a complete top-level `moov`
    /// box is captured (or `probeMaxBudget` is exhausted), then parse it.
    fileprivate static func fetchMoovHeader(url: URL, budget initialBudget: Int) async throws -> MoovHeader {
        var budget = initialBudget
        while true {
            var req = URLRequest(url: url)
            req.setValue("bytes=0-\(budget - 1)", forHTTPHeaderField: "Range")
            req.timeoutInterval = 20
            let (data, response) = try await URLSession.crumbMedia.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let totalSize = totalResourceSize(from: http, fallback: data.count)

            if let moovEnd = findCompleteMoovEnd(in: data), moovEnd <= data.count {
                let entry = parseVideoSampleEntry(moovRange: moovEnd, in: data)
                return MoovHeader(moovEnd: moovEnd, bytes: data.subdata(in: 0..<moovEnd), sampleEntry: entry, moovComplete: true)
            }

            // moov not fully captured yet. If the server told us the resource
            // ends within what we already fetched (or we hit the whole file),
            // there's no more to look for — the header is whatever we have.
            if data.count >= totalSize || budget >= probeMaxBudget {
                return MoovHeader(moovEnd: data.count, bytes: data, sampleEntry: nil, moovComplete: false)
            }
            budget = min(budget * 4, probeMaxBudget, totalSize)
        }
    }

    /// Parse `Content-Range: bytes 0-x/TOTAL` (or fall back to `Content-Length`)
    /// to learn the resource's total size without downloading it.
    private static func totalResourceSize(from http: HTTPURLResponse, fallback: Int) -> Int {
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.firstIndex(of: "/"),
           let total = Int(cr[cr.index(after: slash)...]) {
            return total
        }
        return fallback
    }

    /// Walk top-level boxes in `data` looking for a fully-contained `moov`.
    /// Returns the offset just past `moov`'s end, or nil if `moov` isn't
    /// (yet) fully within `data`.
    fileprivate static func findCompleteMoovEnd(in data: Data) -> Int? {
        var i = 0
        let n = data.count
        while i + 8 <= n {
            guard let (size, isMoov) = boxAt(data, i) else { return nil }
            guard size >= 8 else { return nil } // malformed
            let boxEnd = i + size
            if isMoov {
                return boxEnd <= n ? boxEnd : nil
            }
            if boxEnd > n { return nil } // this box itself isn't fully buffered
            i = boxEnd
        }
        return nil
    }

    private static func boxAt(_ data: Data, _ offset: Int) -> (size: Int, isMoov: Bool)? {
        guard data.count - offset >= 8 else { return nil }
        let b = data.startIndex + offset
        let size = (Int(data[b]) << 24) | (Int(data[b+1]) << 16) | (Int(data[b+2]) << 8) | Int(data[b+3])
        let isMoov = data[b+4] == 0x6D && data[b+5] == 0x6F && data[b+6] == 0x6F && data[b+7] == 0x76 // "moov"
        return (size, isMoov)
    }

    /// Find the video (`vide` handler) trak's sample-entry FourCC (`stsd`'s
    /// first entry) within the `moov` box ending at `moovEnd` in `data`.
    fileprivate static func parseVideoSampleEntry(moovRange moovEnd: Int, in data: Data) -> String? {
        // Locate moov's own start by re-walking (cheap — header is small).
        var i = 0
        while i + 8 <= moovEnd {
            guard let (size, isMoov) = boxAt(data, i) else { return nil }
            guard size >= 8 else { return nil }
            if isMoov {
                let moovStart = i
                return firstVideoSampleEntry(data, moovStart + 8, min(i + size, moovEnd))
            }
            i += size
        }
        return nil
    }

    /// Depth-first search within `moov`'s byte range for the first
    /// `trak/mdia/minf/stbl/stsd` whose handler is `vide`, returning the
    /// sample entry's FourCC (e.g. `hev1`, `hvc1`, `avc1`).
    private static func firstVideoSampleEntry(_ data: Data, _ start: Int, _ end: Int) -> String? {
        for trak in children(data, start, end, type: "trak") {
            guard let mdia = firstChild(data, trak.0, trak.1, type: "mdia") else { continue }
            guard let hdlr = firstChild(data, mdia.0, mdia.1, type: "hdlr") else { continue }
            // hdlr: version/flags(4) pre_defined(4) handler_type(4)…
            guard hdlr.1 - hdlr.0 >= 12 else { continue }
            let handlerOff = hdlr.0 + 8
            guard fourCC(data, handlerOff) == "vide" else { continue }

            guard let minf = firstChild(data, mdia.0, mdia.1, type: "minf") else { continue }
            guard let stbl = firstChild(data, minf.0, minf.1, type: "stbl") else { continue }
            guard let stsd = firstChild(data, stbl.0, stbl.1, type: "stsd") else { continue }
            // stsd: version/flags(4) entry_count(4) then entry box.
            let entryStart = stsd.0 + 8
            guard entryStart + 8 <= stsd.1 else { continue }
            return fourCC(data, entryStart + 4)
        }
        return nil
    }

    private static func fourCC(_ d: Data, _ o: Int) -> String {
        let b = d.startIndex + o
        guard o >= 0, o + 4 <= d.count else { return "" }
        return String(bytes: [d[b], d[b+1], d[b+2], d[b+3]], encoding: .ascii) ?? ""
    }

    /// Direct child boxes of `type` within `[start, end)`.
    private static func children(_ d: Data, _ start: Int, _ end: Int, type: String) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var i = start
        while i + 8 <= end {
            guard let (size, _) = boxAt(d, i), size >= 8, i + size <= end else { break }
            let t = fourCC(d, i + 4)
            if t == type { result.append((i + 8, i + size)) }
            i += size
        }
        return result
    }

    private static func firstChild(_ d: Data, _ start: Int, _ end: Int, type: String) -> (Int, Int)? {
        children(d, start, end, type: type).first
    }
}

/// One loader per `AVURLAsset`, used only when `HEVCRetag.probe` determined
/// the segment genuinely needs an `hev1`→`hvc1` retag (or the probe was
/// inconclusive, in which case this degrades to the old whole-download path
/// as a safety net — see `unknownFallback`).
///
/// **Range-streamed design:** only the small `moov` header is ever fully
/// buffered in memory. Every other byte range AVFoundation asks for (the
/// `moof`/`mdat` fragments — i.e. essentially the whole file) is proxied
/// straight through to the origin server with a matching `Range:` header, so
/// a seek to a new offset costs one bounded HTTP range request, never a full
/// segment download.
final class HEVCRetagLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    /// The segment URL as of construction — carries whatever scoped media
    /// token was fresh at seek time. Used as-is for the header fetch (which
    /// happens immediately) and as the fallback when no `refreshURL` provider
    /// was supplied.
    private let realURL: URL
    /// Re-mints `realURL` with a FRESH scoped media token immediately before
    /// each proxy `Range:` GET (P0-SESSIONS media-URL migration).
    ///
    /// **Why this exists:** a scoped media token is valid only ~15 min, but a
    /// paused/slow-scrubbed/long segment can keep this delegate's proxy alive
    /// well past that — every `moof`/`mdat` byte range AVFoundation asks for
    /// is proxied straight through to `realURL`'s origin, so a stale token
    /// there would 401 mid-playback. `MediaTokenCache` (behind this closure)
    /// makes the overwhelmingly common case — token still fresh — a cheap
    /// in-memory hit, so calling it before every proxy request costs nothing
    /// extra beyond the occasional real re-mint (`nil` = mint failed;
    /// falls back to `realURL` as constructed rather than failing the
    /// request outright, matching this delegate's general "prefer degraded
    /// playback over a hard failure" posture).
    ///
    /// `nil` when the caller has no camera/path context to re-mint from (only
    /// happens if this delegate is ever constructed outside
    /// `SegmentPlayer.installPlayerItem`, which always supplies one).
    private let refreshURL: (() async -> URL?)?
    /// Total resource size, learned from the header fetch's `Content-Range`.
    private var totalSize: Int?
    /// The patched header (`ftyp`...`moov`, `hev1`→`hvc1` rewritten), once fetched.
    private var header: Data?
    private var headerFetchTask: Task<Void, Never>?
    private var pendingBeforeHeader: [AVAssetResourceLoadingRequest] = []

    /// Set true if the initial probe couldn't confirm the box layout — falls
    /// back to fetching + patching the entire segment rather than risking an
    /// incorrect proxy split (matches the pre-M4 behavior exactly).
    private let wholeFileFallback: Bool
    private var wholeFileData: Data?
    private var wholeFileFetchTask: Task<Void, Never>?
    private var wholeFilePending: [AVAssetResourceLoadingRequest] = []

    /// In-flight per-request proxy tasks, keyed by the loading request so a
    /// cancel (`didCancel`) can tear down the matching network task.
    private var proxyTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(realURL: URL, wholeFileFallback: Bool = false, refreshURL: (() async -> URL?)? = nil) {
        self.realURL = realURL
        self.wholeFileFallback = wholeFileFallback
        self.refreshURL = refreshURL
        super.init()
    }

    /// `realURL`, re-minted with a fresh scoped token when a `refreshURL`
    /// provider is available. Falls back to `realURL` as constructed if
    /// re-minting fails or no provider was supplied — degraded (a stale token
    /// may 401) rather than failing the request outright, since a live
    /// network hiccup shouldn't hard-fail a proxy read that might otherwise
    /// have succeeded against the origin's own error handling/retry.
    private func currentRealURL() async -> URL {
        guard let refreshURL else { return realURL }
        return await refreshURL() ?? realURL
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if wholeFileFallback {
            handleWholeFile(loadingRequest)
            return true
        }
        handleRangeStreamed(loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingBeforeHeader.removeAll { $0 == loadingRequest }
        wholeFilePending.removeAll { $0 == loadingRequest }
        let key = ObjectIdentifier(loadingRequest)
        proxyTasks[key]?.cancel()
        proxyTasks[key] = nil
    }

    // MARK: - Range-streamed path (the M4 fast path)

    private func handleRangeStreamed(_ request: AVAssetResourceLoadingRequest) {
        guard let header else {
            pendingBeforeHeader.append(request)
            if headerFetchTask == nil {
                headerFetchTask = Task { [weak self] in await self?.fetchHeader() }
            }
            return
        }
        serveRangeStreamed(request, header: header)
    }

    private func fetchHeader() async {
        do {
            // Constructed only moments before this runs (the header fetch
            // kicks off from the very first loading request), so `realURL`
            // itself is fine here — no need for `currentRealURL()`. Kept
            // explicit rather than silently reusing a possibly-stale token to
            // make the freshness reasoning per call site auditable.
            let h = try await HEVCRetag.fetchMoovHeader(url: realURL, budget: HEVCRetag.probeInitialBudget)
            let patched = HEVCRetagLoaderDelegate.retagMoov(h.bytes)
            await MainActor.run {
                self.header = patched
                self.totalSize = nil // learned lazily from proxy responses / content-info requests
                let reqs = self.pendingBeforeHeader
                self.pendingBeforeHeader.removeAll()
                for r in reqs { self.serveRangeStreamed(r, header: patched) }
            }
        } catch {
            await MainActor.run {
                let reqs = self.pendingBeforeHeader
                self.pendingBeforeHeader.removeAll()
                for r in reqs { r.finishLoading(with: error) }
            }
        }
    }

    /// Serve a loading request against the cached patched header when it's
    /// fully contained there; otherwise proxy the exact requested byte range
    /// straight through to the origin server (streaming — no full buffering).
    private func serveRangeStreamed(_ request: AVAssetResourceLoadingRequest, header: Data) {
        if let info = request.contentInformationRequest {
            info.contentType = "public.mpeg-4"
            info.isByteRangeAccessSupported = true
            if let totalSize { info.contentLength = Int64(totalSize) }
        }
        guard let dr = request.dataRequest else {
            request.finishLoading()
            return
        }

        let offset = Int(dr.requestedOffset)
        let length = dr.requestedLength

        if offset >= 0, offset + length <= header.count {
            // Entirely within the patched header — serve from memory.
            dr.respond(with: header.subdata(in: offset..<(offset + length)))
            request.finishLoading()
            return
        }

        // Falls (at least partly) outside the header — proxy the exact range
        // from the origin. If it straddles the header/media boundary, this
        // still just proxies the whole requested range from the origin's
        // UNPATCHED bytes for the header portion — but AVFoundation always
        // issues separate content-info + aligned data requests in practice,
        // so straddling ranges essentially never happen; if one ever does,
        // we prefer correctness of the media bytes (which dominate) and
        // accept that a few straddling header bytes would be unpatched. To
        // avoid that risk entirely, split the header-covered prefix (served
        // from the patched buffer) from the remainder (proxied).
        if offset < header.count {
            let headerPart = header.subdata(in: offset..<header.count)
            dr.respond(with: headerPart)
            let remainderOffset = header.count
            let remainderLength = length - headerPart.count
            proxyRange(request, dr: dr, offset: remainderOffset, length: remainderLength)
            return
        }

        proxyRange(request, dr: dr, offset: offset, length: length)
    }

    /// Stream `[offset, offset+length)` (or to EOF when `length` is the
    /// "unbounded" sentinel AVFoundation sometimes sends) straight through
    /// from the origin server via a single Range GET, feeding bytes to
    /// `dr.respond` as they arrive rather than buffering the whole range.
    private func proxyRange(_ request: AVAssetResourceLoadingRequest, dr: AVAssetResourceLoadingDataRequest, offset: Int, length: Int) {
        let key = ObjectIdentifier(request)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // Re-mint the scoped media token immediately before this GET
                // (P0-SESSIONS): a long-lived playback session (paused, slow
                // scrub, or just a long segment) can easily outlive the ~15 min
                // token that was fresh when this delegate was constructed.
                // `currentRealURL()` is a cheap cache hit via
                // `MediaTokenCache` when the token is still fresh, so this
                // costs nothing extra in the common case.
                var req = URLRequest(url: await self.currentRealURL())
                if length > 0, length < Int(Int32.max) {
                    req.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
                } else {
                    req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                }
                req.timeoutInterval = 30
                let (byteStream, response) = try await URLSession.crumbMedia.bytes(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                if self.totalSize == nil, let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = cr.firstIndex(of: "/"), let total = Int(cr[cr.index(after: slash)...]) {
                    // `totalSize` isn't isolated (this class isn't `@MainActor`),
                    // and `serveRangeStreamed`'s read of it runs on whatever
                    // executor the resource-loader delegate callback landed on.
                    // Hop through `MainActor.run` for the write, same as every
                    // other mutation of this delegate's state in this file
                    // (`fetchHeader` above, `proxyTasks[key] = nil` below).
                    await MainActor.run { self.totalSize = total }
                }

                var chunk = Data()
                chunk.reserveCapacity(64 * 1024)
                for try await byte in byteStream {
                    if Task.isCancelled { return }
                    chunk.append(byte)
                    if chunk.count >= 64 * 1024 {
                        dr.respond(with: chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if Task.isCancelled { return }
                if !chunk.isEmpty { dr.respond(with: chunk) }
                request.finishLoading()
            } catch {
                if !Task.isCancelled { request.finishLoading(with: error) }
            }
            await MainActor.run { self.proxyTasks[key] = nil }
        }
        proxyTasks[key] = task
    }

    // MARK: - Whole-file fallback (only when the probe was inconclusive)

    private func handleWholeFile(_ request: AVAssetResourceLoadingRequest) {
        if let wholeFileData {
            fulfillWholeFile(request, with: wholeFileData)
            return
        }
        wholeFilePending.append(request)
        if wholeFileFetchTask == nil {
            wholeFileFetchTask = Task { [weak self] in await self?.fetchWholeFile() }
        }
    }

    private func fetchWholeFile() async {
        // Single fetch, kicked off from the very first loading request (same
        // reasoning as `fetchHeader`) — `realURL` is fresh enough here; no
        // need for `currentRealURL()`.
        var req = URLRequest(url: realURL)
        req.timeoutInterval = 30
        do {
            let (raw, _) = try await URLSession.crumbMedia.data(for: req)
            let patched = HEVCRetagLoaderDelegate.retagMoov(raw)
            await MainActor.run {
                self.wholeFileData = patched
                let reqs = self.wholeFilePending
                self.wholeFilePending.removeAll()
                for r in reqs { self.fulfillWholeFile(r, with: patched) }
            }
        } catch {
            await MainActor.run {
                let reqs = self.wholeFilePending
                self.wholeFilePending.removeAll()
                for r in reqs { r.finishLoading(with: error) }
            }
        }
    }

    private func fulfillWholeFile(_ request: AVAssetResourceLoadingRequest, with data: Data) {
        if let info = request.contentInformationRequest {
            info.contentType = "public.mpeg-4"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        guard let dr = request.dataRequest else {
            request.finishLoading()
            return
        }
        let offset = Int(dr.requestedOffset)
        guard offset <= data.count else { request.finishLoading(); return }
        let length = dr.requestedLength
        let end = min(offset + length, data.count)
        dr.respond(with: data.subdata(in: offset..<end))
        request.finishLoading()
    }

    // MARK: - moov patch (unchanged rewrite logic, now applied to the header only)

    /// Replace `hev1`→`hvc1` within the top-level `moov` box only. When called
    /// on just the header slice (`ftyp`...`moov`), this operates on the same
    /// bytes as before; when called on a whole file (fallback path), behavior
    /// is byte-for-byte identical to the original implementation.
    fileprivate static func retagMoov(_ input: Data) -> Data {
        var data = input
        let n = data.count
        let hev1: [UInt8] = [0x68, 0x65, 0x76, 0x31] // "hev1"
        let hvc1: [UInt8] = [0x68, 0x76, 0x63, 0x31] // "hvc1"
        let moov: [UInt8] = [0x6D, 0x6F, 0x6F, 0x76] // "moov"

        data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            // Walk top-level boxes: [4B big-endian size][4B type] ...
            var i = 0
            while i + 8 <= n {
                let size = (Int(p[i]) << 24) | (Int(p[i+1]) << 16) | (Int(p[i+2]) << 8) | Int(p[i+3])
                let isMoov = p[i+4] == moov[0] && p[i+5] == moov[1] && p[i+6] == moov[2] && p[i+7] == moov[3]
                let boxEnd = size >= 8 ? min(i + size, n) : n
                if isMoov {
                    var j = i + 8
                    while j + 4 <= boxEnd {
                        if p[j] == hev1[0] && p[j+1] == hev1[1] && p[j+2] == hev1[2] && p[j+3] == hev1[3] {
                            p[j] = hvc1[0]; p[j+1] = hvc1[1]; p[j+2] = hvc1[2]; p[j+3] = hvc1[3]
                        }
                        j += 1
                    }
                    break // moov fully patched; media samples follow in moof/mdat
                }
                if size < 8 { break } // malformed / size-to-end; stop walking
                i = boxEnd
            }
        }
        return data
    }
}
