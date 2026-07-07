// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A Crumb server found on the local network. Mirrors Android's
/// `DiscoveredServer` (`ServerDiscovery.kt`).
struct DiscoveredServer: Identifiable, Equatable {
    var id: String { ip }
    let url: String
    let ip: String
    let version: String?
}

/// M6 parity: scan the device's local /24 for Crumb servers by probing the
/// unauthenticated `GET /health` endpoint on `port` (default 8080) and
/// matching the `"service":"crumb-api"` signature — same fingerprint and same
/// **unicast TCP scan** design as Android's `ServerDiscovery.kt` (not mDNS:
/// the Crumb API runs in a bridged Docker container, so multicast discovery
/// never reaches the LAN, but ordinary TCP to the published port does).
enum ServerDiscovery {

    /// Max hosts probed at once — bounds socket pressure so a /24 finishes in
    /// a few seconds (matches Android's `SCAN_CONCURRENCY`).
    private static let scanConcurrency = 48

    /// Scan `range` (or the device's own /24 when nil) for Crumb servers.
    /// `range` accepts a CIDR (`192.0.2.0/24`), a 3-octet base (`192.0.2`,
    /// scanned `.1`-`.254`), a single IP, or a dash range on the last octet
    /// (`192.0.2.10-20`) — same grammar as Android's `parseScanHosts`.
    static func discover(range: String? = nil, port: Int = 8080) async -> [DiscoveredServer] {
        let hosts: [String]
        if let range, !range.trimmingCharacters(in: .whitespaces).isEmpty {
            hosts = parseScanHosts(range)
        } else {
            guard let localHosts = localSubnetHosts() else { return [] }
            hosts = localHosts
        }
        guard !hosts.isEmpty else { return [] }

        let session = URLSession(configuration: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 0.8
            cfg.timeoutIntervalForResource = 1.5
            cfg.waitsForConnectivity = false
            return cfg
        }())

        var results: [DiscoveredServer] = []
        await withTaskGroup(of: DiscoveredServer?.self) { group in
            var iterator = hosts.makeIterator()
            var inFlight = 0
            // Bounded concurrency: seed up to `scanConcurrency` probes, then
            // start one more each time one finishes.
            func launchNext() {
                guard let ip = iterator.next() else { return }
                inFlight += 1
                group.addTask { await probe(session: session, ip: ip, port: port) }
            }
            for _ in 0..<scanConcurrency { launchNext() }
            while inFlight > 0 {
                if let found = await group.next() {
                    inFlight -= 1
                    if let found { results.append(found) }
                    launchNext()
                }
            }
        }
        return results.sorted { lastOctet($0.ip) < lastOctet($1.ip) }
    }

    /// The device's own /24 as a CIDR string (e.g. `192.0.2.0/24`), for
    /// prefilling a "scan a specific subnet" field. `nil` when offline or the
    /// primary interface has no IPv4 address.
    static func detectLocalSubnetCidr() -> String? {
        guard let ip = selfIPv4() else { return nil }
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return "\(octets[0]).\(octets[1]).\(octets[2]).0/24"
    }

    // MARK: - probing

    private static func probe(session: URLSession, ip: String, port: Int) async -> DiscoveredServer? {
        let base = "http://\(ip):\(port)"
        guard let health = await httpGet(session: session, url: "\(base)/health"),
              health.contains("crumb-api")
        else { return nil }
        let version = (await httpGet(session: session, url: "\(base)/version")).flatMap { extractJSONString($0, key: "version") }
        return DiscoveredServer(url: base, ip: ip, version: version)
    }

    /// GET a URL and return the body for ANY response code (nil only on a
    /// network error/timeout) — Crumb is identified by the body content, not
    /// the status code (mirrors Android's `httpGet`).
    private static func httpGet(session: URLSession, url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Minimal `"key":"value"` extractor so the scan doesn't need a JSON model.
    private static func extractJSONString(_ json: String, key: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"([^\"]*)\"") else { return nil }
        let range = NSRange(json.startIndex..<json.endIndex, in: json)
        guard let match = regex.firstMatch(in: json, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: json)
        else { return nil }
        let value = String(json[r])
        return value.isEmpty ? nil : value
    }

    private static func lastOctet(_ ip: String) -> Int {
        Int(ip.split(separator: ".").last ?? "") ?? 0
    }

    // MARK: - host enumeration

    /// The up-to-254 host IPs of the device's local /24 (last octet 1...254),
    /// excluding the device's own address. `nil` when no IPv4 address is
    /// available (e.g. no active network).
    private static func localSubnetHosts() -> [String]? {
        guard let self_ = selfIPv4() else { return nil }
        let octets = self_.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return nil }
        let prefix = "\(octets[0]).\(octets[1]).\(octets[2])"
        let selfLast = octets[3]
        return (1...254).filter { $0 != selfLast }.map { "\(prefix).\($0)" }
    }

    /// Parse a user-entered scan target into host IPs. Mirrors Android's
    /// `parseScanHosts` grammar (CIDR / 3-octet base / single IP / dash range
    /// on the last octet). Bounded to <=254 hosts; invalid input -> empty.
    private static func parseScanHosts(_ input: String) -> [String] {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return [] }

        if s.contains("/") {
            let base = String(s.split(separator: "/", maxSplits: 1)[0])
            let octets = base.split(separator: ".").compactMap { Int($0) }
            guard octets.count >= 3, octets.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return [] }
            return (1...254).map { "\(octets[0]).\(octets[1]).\(octets[2]).\($0)" }
        }

        if s.contains("-") {
            let parts = s.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return [] }
            let lo = parts[0].split(separator: ".").compactMap { Int($0) }
            let hiRaw = parts[1]
            let hiLast = Int(hiRaw) ?? hiRaw.split(separator: ".").compactMap { Int($0) }.last
            guard lo.count == 4, lo.allSatisfy({ (0...255).contains($0) }),
                  let hiLast, (lo[3]...255).contains(hiLast)
            else { return [] }
            return (lo[3]...hiLast).map { "\(lo[0]).\(lo[1]).\(lo[2]).\($0)" }
        }

        let octets = s.split(separator: ".").compactMap { Int($0) }
        if octets.count == 3, octets.allSatisfy({ (0...255).contains($0) }) {
            return (1...254).map { "\(octets[0]).\(octets[1]).\(octets[2]).\($0)" }
        }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            return [s]
        }
        return []
    }

    /// The device's primary IPv4 address, preferring Wi-Fi/Ethernet
    /// interfaces (`en*`) over cellular (`pdp_ip*`) — best-effort via
    /// `getifaddrs`, works identically on iOS and macOS.
    private static func selfIPv4() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var candidate: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostBuffer)

            // Prefer en0/en1 (Wi-Fi/Ethernet) if we find one; otherwise keep
            // the first non-loopback IPv4 we saw as a fallback.
            if name.hasPrefix("en") {
                address = ip
                break
            }
            if candidate == nil { candidate = ip }
        }
        return address ?? candidate
    }
}
