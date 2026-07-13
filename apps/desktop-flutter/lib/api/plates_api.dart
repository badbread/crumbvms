// License-plate reads (LPR) data layer: `GET /plates`, the newest-first feed
// of recognized plates for the caller's viewer-scoped cameras. Backend
// contract is locked (see the LPR desktop task / services/api plates route).
//
// Route facts, same shape as the other JSON endpoints in [CrumbApi]: mounted
// at ROOT (no /api prefix), authed with the bearer JWT (NOT a media ?token=).
// `camera_ids` is required (csv of camera UUIDs; the server further scopes to
// what the viewer may see). An empty or LPR-disabled server returns an empty
// page rather than an error, so callers never need to special-case that.
//
// The per-plate snapshot JPEG is NOT fetched here — it's an <img>-style media
// load. When a read carries an `event_id`, the Plates UI fetches the sibling
// detection snapshot via `GET /events/{event_id}/snapshot` (Bearer-authed,
// viewer-scoped), matching how detection events expose their snapshot.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'models.dart';

/// One recognized plate read from `GET /plates`. `plate` is the normalized
/// (uppercase alphanumeric) string used for matching/display; `plateRaw` is
/// the provider's original text. `confidence` is 0..1 or null; `eventId` links
/// to the sibling detection event (may be null); `snapshotUrl` is a provider
/// snapshot path or null.
class PlateRead {
  PlateRead({
    required this.id,
    required this.cameraId,
    required this.ts,
    required this.plate,
    required this.plateRaw,
    required this.confidence,
    required this.region,
    required this.sourceId,
    required this.eventId,
    required this.snapshotUrl,
  });

  final String id;
  final String cameraId;
  final DateTime ts;
  final String plate; // normalized uppercase alphanumeric
  final String plateRaw; // provider original
  final double? confidence; // 0..1, or null
  final String? region;
  final String? sourceId;
  final String? eventId; // sibling detection event, or null
  final String? snapshotUrl; // provider snapshot path, or null

  factory PlateRead.fromJson(Map<String, dynamic> j) => PlateRead(
    id: j['id'] as String,
    cameraId: j['camera_id'] as String,
    ts: DateTime.parse(j['ts'] as String),
    plate: (j['plate'] as String?) ?? '',
    plateRaw: (j['plate_raw'] as String?) ?? '',
    confidence: (j['confidence'] as num?)?.toDouble(),
    region: j['region'] as String?,
    sourceId: j['source_id'] as String?,
    eventId: j['event_id'] as String?,
    snapshotUrl: j['snapshot_url'] as String?,
  );
}

/// `GET /plates` response: a page of reads plus the total match count and a
/// has-more flag for cursor-free offset paging.
class PlatesPage {
  PlatesPage({
    required this.plates,
    required this.total,
    required this.hasMore,
  });

  final List<PlateRead> plates;
  final int total;
  final bool hasMore;

  factory PlatesPage.fromJson(Map<String, dynamic> j) => PlatesPage(
    plates: (j['plates'] as List<dynamic>? ?? const [])
        .map((e) => PlateRead.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    total: (j['total'] as num?)?.toInt() ?? 0,
    hasMore: (j['has_more'] as bool?) ?? false,
  );
}

// [CrumbApi]'s http.Client is file-private (Dart library privacy is
// file-scoped), so this extension keeps its own module-level client for its
// stateless GETs — same construction as CrumbApi's default, just not shared.
final http.Client _client = http.Client();

extension PlatesApi on CrumbApi {
  /// `GET /plates?camera_ids=<csv>[&start=<iso>&end=<iso>&q=<str>&match=<m>&limit=&offset=]`
  ///
  /// Newest-first plate reads for [cameraIds] (further viewer-scoped
  /// server-side). `match` selects the query mode (`exact` | `prefix` |
  /// `contains` | `fuzzy`) and is only meaningful when [query] is non-empty.
  /// An empty [cameraIds] short-circuits to an empty page (the endpoint
  /// requires camera_ids). Never throws for scoping/disabled reasons — those
  /// come back as an empty page.
  Future<PlatesPage> listPlates(
    Session s, {
    required List<String> cameraIds,
    String? query,
    String match = 'contains',
    DateTime? start,
    DateTime? end,
    int limit = 200,
    int offset = 0,
  }) async {
    if (cameraIds.isEmpty) {
      return PlatesPage(plates: const [], total: 0, hasMore: false);
    }
    final params = <String, String>{
      'camera_ids': cameraIds.join(','),
      'limit': '$limit',
      'offset': '$offset',
    };
    final q = query?.trim() ?? '';
    if (q.isNotEmpty) {
      params['q'] = q;
      params['match'] = match;
    }
    if (start != null) params['start'] = start.toUtc().toIso8601String();
    if (end != null) params['end'] = end.toUtc().toIso8601String();
    final uri = Uri.parse('${s.base}/plates').replace(queryParameters: params);
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load plates (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return PlatesPage.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }
}
