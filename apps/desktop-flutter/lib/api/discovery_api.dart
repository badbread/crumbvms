// "Find my server": LAN discovery of Crumb servers, ported from the Tauri
// desktop's Rust `discover_servers`/`scan_hosts`/`local_subnet_cidr`
// (apps/desktop/src-tauri/src/lib.rs) and its `loginDiscover` UI
// (apps/desktop/src/app.js).
//
// Probes candidate (scheme, port) pairs against every host in a /24 (or a
// user-supplied CIDR / `a.b.c.x-y` range) for the unauthenticated `/health`
// signature (`GET /health` body contains `"crumb-api"` even when the DB is
// degraded — see services/api/src/main.rs `health()`), 64-way concurrent,
// with a short per-connection timeout. Self-signed TLS is accepted for the
// probe only (discovery never reads anything beyond the public /health and
// /version bodies).
//
// This is plain Dart (`dart:io` sockets), not flutter_rust_bridge — no new
// platform-native surface is needed, `HttpClient` already gives us a
// per-connection timeout and a bad-certificate override.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'crumb_api.dart';

/// One server found by [DiscoveryApi.discoverServers].
class DiscoveredServer {
  DiscoveredServer({required this.url, required this.ip, required this.port, this.version});

  /// Full base URL, e.g. `http://<lan-ip>:8080` or `https://<lan-ip>:8443`.
  final String url;
  final String ip;
  final int port;
  final String? version;

  bool get isHttps => url.startsWith('https://');
}

/// LAN server discovery, added as an extension (not a method on [CrumbApi]
/// itself) so this feature stays a self-contained file — see
/// apps/desktop-flutter/lib/api/crumb_api.dart's header comment. Discovery
/// probes are unauthenticated and don't need a [Session], so these methods
/// take no session/token.
extension DiscoveryApi on CrumbApi {
  /// The device's own /24 as a CIDR string (e.g. `a.b.c.0/24`), for
  /// prefilling the "scan a specific subnet" field. `null` if no usable IPv4
  /// interface can be found.
  Future<String?> localSubnetCidr() async {
    final ip = await _localIpv4();
    if (ip == null) return null;
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.0/24';
  }

  /// Scan the LAN for Crumb servers. `range` is `null`/empty for the local
  /// /24, or a user-entered CIDR (scans that /24), a bare `a.b.c` base, a
  /// single `a.b.c.d`, or an `a.b.c.x-y` dash range on the last octet — same
  /// grammar as the old Rust `scan_hosts`. `port`, if given, is probed on
  /// both http and https in addition to the default 8080/8443 pair, so a
  /// custom deployment is still found.
  ///
  /// Throws [CrumbApiException] if `range` can't be resolved to a subnet.
  Future<List<DiscoveredServer>> discoverServers({int? port, String? range}) async {
    final hosts = await _resolveHosts(range);
    if (hosts == null || hosts.isEmpty) {
      throw CrumbApiException('Could not determine a subnet to scan.');
    }

    final candidates = <(bool isHttps, int port)>[(false, 8080), (true, 8443)];
    if (port != null && !candidates.any((c) => c.$2 == port)) {
      candidates.add((false, port));
      candidates.add((true, port));
    }

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    final httpsClient = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500)
      // Discovery only reads the unauthenticated /health signature; a LAN
      // server's TLS cert is typically self-signed, so don't reject it here.
      ..badCertificateCallback = (cert, host, port) => true;

    try {
      final probes = <(String ip, bool isHttps, int port)>[
        for (final ip in hosts)
          for (final c in candidates) (ip, c.$1, c.$2),
      ];

      final found = <DiscoveredServer>[];
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= probes.length) return;
          final (ip, isHttps, p) = probes[i];
          final client = isHttps ? httpsClient : httpClient;
          final scheme = isHttps ? 'https' : 'http';
          final result = await _probeServer(client, scheme, ip, p);
          if (result != null) found.add(result);
        }
      }

      // 64-way concurrent, matching the Rust `buffer_unordered(64)`.
      await Future.wait(List.generate(64, (_) => worker()));

      // Collapse the plain+TLS front doors of a *single* host into one
      // entry: if the same IP answers on both http:8080 and https:8443, keep
      // only the secure URL. Distinct hosts and genuinely different ports
      // stay separate.
      final dual = found
          .where((s) => s.isHttps && s.port == 8443)
          .map((s) => s.ip)
          .toSet();
      found.removeWhere((s) => s.port == 8080 && !s.isHttps && dual.contains(s.ip));

      found.sort((a, b) {
        int lastOctet(String ip) => int.tryParse(ip.split('.').last) ?? 0;
        final byIp = lastOctet(a.ip).compareTo(lastOctet(b.ip));
        if (byIp != 0) return byIp;
        return a.port.compareTo(b.port);
      });
      return found;
    } finally {
      httpClient.close(force: true);
      httpsClient.close(force: true);
    }
  }
}

Future<DiscoveredServer?> _probeServer(
  HttpClient client,
  String scheme,
  String ip,
  int port,
) async {
  final base = '$scheme://$ip:$port';
  try {
    final body = await _get(client, '$base/health').timeout(const Duration(milliseconds: 1200));
    if (body == null || !body.contains('crumb-api')) return null;

    String? version;
    try {
      final vBody = await _get(client, '$base/version').timeout(const Duration(milliseconds: 1200));
      if (vBody != null) {
        final j = jsonDecode(vBody) as Map<String, dynamic>;
        version = j['version'] as String?;
      }
    } catch (_) {
      // /version is best-effort; a server that answers /health but not
      // /version is still a valid hit.
    }

    return DiscoveredServer(url: base, ip: ip, port: port, version: version);
  } catch (_) {
    return null;
  }
}

Future<String?> _get(HttpClient client, String url) async {
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    return await resp.transform(utf8.decoder).join();
  } on Object {
    return null;
  }
}

/// Best-effort local IPv4 of a non-loopback interface. Unlike the Rust
/// implementation (a UDP "connect" to reveal the outbound source address),
/// this just picks the first non-loopback, non-link-local IPv4 address —
/// `dart:io` has no portable equivalent of a connected UDP socket's local
/// address, and this is good enough to seed the "scan a specific subnet"
/// field on a typical single-NIC desktop.
Future<String?> _localIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
  } catch (_) {
    // No usable interface — fall through to null.
  }
  return null;
}

/// Resolve a user-entered range to host IPs (dotted-decimal strings).
/// `null`/empty → the local /24. Accepts CIDR (scans that /24), a bare
/// `a.b.c` base, a single `a.b.c.d`, or `a.b.c.x-y`. Returns `null` if the
/// range can't be parsed (mirrors the Rust `scan_hosts`' `Option` return).
Future<List<String>?> _resolveHosts(String? range) async {
  List<String> base24(int a, int b, int c) => [
    for (var l = 1; l <= 254; l++) '$a.$b.$c.$l',
  ];

  final r = (range ?? '').trim();
  if (r.isEmpty) {
    final ip = await _localIpv4();
    if (ip == null) return null;
    final o = ip.split('.').map(int.parse).toList();
    return base24(o[0], o[1], o[2]);
  }

  // Dash range on the last octet: a.b.c.x-y (or a.b.c.x-a.b.c.y).
  if (r.contains('-')) {
    final idx = r.indexOf('-');
    final lo = r.substring(0, idx).trim();
    final hi = r.substring(idx + 1).trim();
    final lp = lo.split('.').map((s) => int.tryParse(s)).toList();
    if (lp.length != 4 || lp.any((v) => v == null)) return null;
    int? hVal = int.tryParse(hi);
    hVal ??= hi.split('.').map((s) => int.tryParse(s)).lastWhere(
          (v) => v != null,
          orElse: () => null,
        );
    if (hVal == null || hVal < lp[3]!) return null;
    return [for (var l = lp[3]!; l <= hVal; l++) '${lp[0]}.${lp[1]}.${lp[2]}.$l'];
  }

  // CIDR or base → scan the address's /24.
  final addr = r.contains('/') ? r.split('/').first : r;
  final parts = addr.split('.').map((s) => int.tryParse(s)).toList();
  if (r.contains('/') && parts.length >= 3 && parts.sublist(0, 3).every((v) => v != null)) {
    return base24(parts[0]!, parts[1]!, parts[2]!);
  }
  if (parts.length == 3 && parts.every((v) => v != null)) {
    return base24(parts[0]!, parts[1]!, parts[2]!);
  }
  if (parts.length == 4 && parts.every((v) => v != null)) {
    return ['${parts[0]}.${parts[1]}.${parts[2]}.${parts[3]}'];
  }
  return null;
}
