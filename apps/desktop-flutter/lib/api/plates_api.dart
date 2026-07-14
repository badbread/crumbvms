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
import 'http_client.dart';
import 'models.dart';

/// One recognized plate read from `GET /plates`. `plate` is the normalized
/// (uppercase alphanumeric) string used for matching/display; `plateRaw` is
/// the provider's original text. `confidence` is 0..1 or null; `eventId` links
/// to the sibling detection event (may be null); `snapshotUrl` is a provider
/// snapshot path or null. `bbox` is the plate's bounding box within the
/// detection snapshot as `[x, y, w, h]` fractions (each 0..1) of the snapshot
/// dimensions, or null when the provider didn't report one — the single-plate
/// report uses it to crop a zoomed plate image, falling back to the full frame.
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
    required this.bbox,
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
  final List<double>? bbox; // [x,y,w,h] fractions 0..1 of snapshot, or null

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
    bbox: _parseBbox(j['bbox']),
  );
}

/// Parse a `bbox` JSON value into `[x, y, w, h]` doubles, or null when it's
/// absent/malformed — the field is optional and clients tolerate its absence.
/// Only a 4-element numeric array is accepted; anything else yields null.
List<double>? _parseBbox(Object? raw) {
  if (raw is! List || raw.length != 4) return null;
  final out = <double>[];
  for (final v in raw) {
    if (v is num) {
      out.add(v.toDouble());
    } else {
      return null;
    }
  }
  return out;
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

/// One entry from the LPR plate watchlist (`GET /lpr/watchlist`). A
/// watchlisted plate raises an alert (delivered via the server's notification
/// channels) the next time it's seen. `plate` is the normalized (uppercase
/// alphanumeric) key used for matching/display; `label`/`note`/`color` are
/// optional operator annotations (any may be null); `notify` gates whether a
/// sighting actually alerts. `kind` is `"watch"` (the default — a sighting
/// alerts) or `"ignore"` (the server drops matching reads before they land).
class PlateWatchlistEntry {
  PlateWatchlistEntry({
    required this.id,
    required this.plate,
    required this.label,
    required this.note,
    required this.color,
    required this.notify,
    required this.kind,
    required this.createdAt,
  });

  final String id; // UUID
  final String plate; // normalized uppercase alphanumeric
  final String? label; // operator label, e.g. "Mom's car"
  final String? note; // free-form note, or null
  final String? color; // "#rrggbb", or null
  final bool notify; // alert on sighting
  final String kind; // "watch" | "ignore"
  final DateTime? createdAt;

  /// True when this entry drops matching reads rather than alerting on them.
  bool get isIgnore => kind == 'ignore';

  factory PlateWatchlistEntry.fromJson(Map<String, dynamic> j) =>
      PlateWatchlistEntry(
        id: j['id'] as String,
        plate: (j['plate'] as String?) ?? '',
        label: j['label'] as String?,
        note: j['note'] as String?,
        color: j['color'] as String?,
        notify: (j['notify'] as bool?) ?? true,
        kind: (j['kind'] as String?) == 'ignore' ? 'ignore' : 'watch',
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
      );
}

/// LPR feature configuration (`GET /config/lpr`, admin-only). `watchlistFuzz`
/// (0.0..0.5) is the OCR-misread tolerance applied to both watch and ignore
/// matching; `enabled` and `retentionDays` are preserved verbatim when the
/// desktop client PUTs a fuzziness change. `hasIngestToken`/`version` are
/// read-only status the client surfaces but never writes.
class LprConfig {
  LprConfig({
    required this.enabled,
    required this.retentionDays,
    required this.watchlistFuzz,
    required this.hasIngestToken,
    required this.version,
  });

  final bool enabled;
  final int retentionDays;
  final double watchlistFuzz; // 0.0 .. 0.5
  final bool hasIngestToken;
  final int? version;

  factory LprConfig.fromJson(Map<String, dynamic> j) => LprConfig(
    enabled: (j['enabled'] as bool?) ?? false,
    retentionDays: (j['retention_days'] as num?)?.toInt() ?? 0,
    watchlistFuzz: (j['watchlist_fuzz'] as num?)?.toDouble() ?? 0.0,
    hasIngestToken: (j['has_ingest_token'] as bool?) ?? false,
    version: (j['version'] as num?)?.toInt(),
  );

  LprConfig copyWith({double? watchlistFuzz}) => LprConfig(
    enabled: enabled,
    retentionDays: retentionDays,
    watchlistFuzz: watchlistFuzz ?? this.watchlistFuzz,
    hasIngestToken: hasIngestToken,
    version: version,
  );
}

// [CrumbApi]'s http.Client is file-private (Dart library privacy is
// file-scoped), so this extension keeps its own module-level client for its
// stateless GETs — same construction as CrumbApi's default, just not shared.
final http.Client _client = TimeoutClient();

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

  /// `GET /lpr/watchlist` → every watchlisted plate the caller may see. Gated
  /// by the same `view_plates` capability as [listPlates], so any account that
  /// can reach the Plates tab can read the watchlist (only add/remove are
  /// admin-only). Order follows the server's (newest-first).
  Future<List<PlateWatchlistEntry>> listWatchlist(Session s) async {
    final resp = await _client.get(
      Uri.parse('${s.base}/lpr/watchlist'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load plate watchlist (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => PlateWatchlistEntry.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// `POST /lpr/watchlist` → add a plate to the watchlist (or, since the server
  /// keys on the normalized plate, edit an existing entry) and return the
  /// stored entry (its `plate` is the server-normalized form). [plate] is sent
  /// raw; the server normalizes (uppercase ASCII alphanumerics only). Empty
  /// [label] is omitted rather than sent as "".
  ///
  /// **Admin-only.** A non-admin viewer gets HTTP 403, surfaced as a
  /// [CrumbApiException] with `statusCode == 403` and a friendly message so the
  /// caller can soften it rather than crash.
  Future<PlateWatchlistEntry> addWatchlist(
    Session s, {
    required String plate,
    String? label,
    bool notify = true,
    String kind = 'watch',
  }) async {
    final resp = await _client.post(
      Uri.parse('${s.base}/lpr/watchlist'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'plate': plate,
        if (label != null && label.isNotEmpty) 'label': label,
        'notify': notify,
        'kind': kind == 'ignore' ? 'ignore' : 'watch',
      }),
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw CrumbApiException(
        resp.statusCode == 403
            ? 'Only admins can manage the watchlist.'
            : 'Failed to add plate to watchlist (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return PlateWatchlistEntry.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  /// `DELETE /lpr/watchlist/{id}` → remove a watchlist entry. A `404` (already
  /// gone) is treated as success — the entry is absent either way.
  ///
  /// **Admin-only.** A non-admin viewer gets HTTP 403, surfaced as a
  /// [CrumbApiException] with `statusCode == 403` and a friendly message.
  Future<void> deleteWatchlist(Session s, String id) async {
    final resp = await _client.delete(
      Uri.parse('${s.base}/lpr/watchlist/${Uri.encodeComponent(id)}'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 204 && resp.statusCode != 404) {
      throw CrumbApiException(
        resp.statusCode == 403
            ? 'Only admins can manage the watchlist.'
            : 'Failed to remove plate from watchlist (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }

  /// `GET /config/lpr` → the LPR feature config (enabled, retention, watchlist
  /// fuzziness, ingest-token status, version).
  ///
  /// **Admin-only.** A non-admin viewer gets HTTP 403, surfaced as a
  /// [CrumbApiException] with `statusCode == 403` so the caller can hide the
  /// admin-only fuzziness control rather than crash.
  Future<LprConfig> getLprConfig(Session s) async {
    final resp = await _client.get(
      Uri.parse('${s.base}/config/lpr'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        resp.statusCode == 403
            ? 'Only admins can view LPR configuration.'
            : 'Failed to load LPR config (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return LprConfig.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// `PUT /config/lpr` → update the LPR config. The body carries all three
  /// mutable fields (`enabled`, `retention_days`, `watchlist_fuzz`); callers
  /// changing only the fuzziness must pass the current `enabled`/`retention_days`
  /// through unchanged (the desktop client only edits fuzziness) so the PUT
  /// doesn't clobber them. `watchlistFuzz` is clamped to 0.0..0.5 server-side.
  ///
  /// **Admin-only.** A non-admin viewer gets HTTP 403, surfaced as a
  /// [CrumbApiException] with `statusCode == 403`.
  Future<LprConfig> putLprConfig(
    Session s, {
    required bool enabled,
    required int retentionDays,
    required double watchlistFuzz,
  }) async {
    final resp = await _client.put(
      Uri.parse('${s.base}/config/lpr'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'enabled': enabled,
        'retention_days': retentionDays,
        'watchlist_fuzz': watchlistFuzz,
      }),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        resp.statusCode == 403
            ? 'Only admins can change LPR configuration.'
            : 'Failed to save LPR config (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return LprConfig.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }
}
