// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Plate desk data layer for the redesigned Plates page: the header's "today"
// totals (`GET /lpr/overview`) and per-plate history for the plates on screen
// (`POST /lpr/plates/stats`). Both are `view_plates`-gated and camera-scoped
// server-side exactly like `GET /plates`, authed with the bearer JWT (they are
// JSON aggregates, never media, so no `?token=` claim is involved).
//
// Older servers do not have these routes. Both calls return null on a 404 /
// 405 so the page can degrade (header hidden, history cells "-") instead of
// showing an error; any other failure throws [CrumbApiException].

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// Max plates per `POST /lpr/plates/stats` call (the server's cap).
const int kPlateStatsMaxBatch = 200;

/// The regulars / returning / first-time split of today's unique plates.
class LprSplit {
  const LprSplit({
    required this.regulars,
    required this.returning,
    required this.firstTime,
  });

  final int regulars;
  final int returning;
  final int firstTime;

  int get total => regulars + returning + firstTime;
}

/// `GET /lpr/overview` response.
class LprOverview {
  const LprOverview({
    required this.day,
    required this.tz,
    required this.readsToday,
    required this.uniqueToday,
    required this.newToday,
    required this.watchlistHitsToday,
    required this.split,
    required this.regularMinReads30d,
  });

  final String day; // server-local YYYY-MM-DD
  final String tz;
  final int readsToday;
  final int uniqueToday;
  final int newToday;
  final int watchlistHitsToday;
  final LprSplit split;
  final int regularMinReads30d;

  factory LprOverview.fromJson(Map<String, dynamic> j) {
    final split = (j['split'] as Map<String, dynamic>?) ?? const {};
    return LprOverview(
      day: (j['day'] as String?) ?? '',
      tz: (j['tz'] as String?) ?? '',
      readsToday: _int(j['reads_today']),
      uniqueToday: _int(j['unique_today']),
      newToday: _int(j['new_today']),
      watchlistHitsToday: _int(j['watchlist_hits_today']),
      split: LprSplit(
        regulars: _int(split['regulars']),
        returning: _int(split['returning']),
        firstTime: _int(split['first_time']),
      ),
      regularMinReads30d: _int(j['regular_min_reads_30d'], fallback: 5),
    );
  }
}

/// Reads of one plate on one camera.
class PlateCameraCount {
  const PlateCameraCount(this.cameraId, this.n);
  final String cameraId;
  final int n;
}

/// One plate's history from `POST /lpr/plates/stats`. Hour and day buckets
/// are in the server's time zone; [days30] is oldest first and its last entry
/// is the server's today.
class PlateStats {
  const PlateStats({
    required this.plate,
    required this.total,
    required this.seen7d,
    required this.seen30d,
    required this.firstSeen,
    required this.lastSeen,
    required this.prevSeen,
    required this.cameras,
    required this.hours,
    required this.days30,
    this.regularMinReads30d = 5,
  });

  final String plate;
  final int total;
  final int seen7d;
  final int seen30d;
  final DateTime firstSeen;
  final DateTime lastSeen;

  /// Latest read before the server's today, or null.
  final DateTime? prevSeen;
  final List<PlateCameraCount> cameras; // most reads first
  final List<int> hours; // 24
  final List<int> days30; // 30, oldest first
  final int regularMinReads30d;

  /// Reads on the server's today.
  int get today => days30.isEmpty ? 0 : days30.last;

  /// Every visible read of this plate happened today: a first-time plate.
  bool get isNew => total > 0 && today >= total;

  /// Seen before today with at least [regularMinReads30d] reads in 30 days.
  bool get isRegular => !isNew && seen30d >= regularMinReads30d;

  /// Seen before today, but not a regular.
  bool get isReturning => !isNew && !isRegular;

  factory PlateStats.fromJson(Map<String, dynamic> j, {int regularMin = 5}) {
    List<int> ints(Object? raw, int len) {
      final out = List<int>.filled(len, 0);
      if (raw is List) {
        for (var i = 0; i < raw.length && i < len; i++) {
          final v = raw[i];
          if (v is num) out[i] = v.toInt();
        }
      }
      return out;
    }

    return PlateStats(
      plate: (j['plate'] as String?) ?? '',
      total: _int(j['total']),
      seen7d: _int(j['seen_7d']),
      seen30d: _int(j['seen_30d']),
      firstSeen:
          _date(j['first_seen']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      lastSeen: _date(j['last_seen']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      prevSeen: _date(j['prev_seen']),
      cameras: [
        for (final c in (j['cameras'] as List<dynamic>? ?? const []))
          if (c is Map<String, dynamic> && c['camera_id'] is String)
            PlateCameraCount(c['camera_id'] as String, _int(c['n'])),
      ],
      hours: ints(j['hours'], 24),
      days30: ints(j['days30'], 30),
      regularMinReads30d: regularMin,
    );
  }
}

/// Parse a whole `POST /lpr/plates/stats` body into a plate-keyed map.
Map<String, PlateStats> parsePlateStatsResponse(Map<String, dynamic> j) {
  final regularMin = _int(j['regular_min_reads_30d'], fallback: 5);
  final out = <String, PlateStats>{};
  for (final e in (j['plates'] as List<dynamic>? ?? const [])) {
    if (e is! Map<String, dynamic>) continue;
    final s = PlateStats.fromJson(e, regularMin: regularMin);
    if (s.plate.isNotEmpty) out[s.plate] = s;
  }
  return out;
}

int _int(Object? v, {int fallback = 0}) => v is num ? v.toInt() : fallback;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

final http.Client _client = TimeoutClient();

extension PlateDeskApi on CrumbApi {
  /// `GET /lpr/overview[?camera_ids=]`. Null when the server predates the
  /// endpoint (404/405), so the caller hides the header.
  Future<LprOverview?> getLprOverview(
    Session s, {
    List<String>? cameraIds,
  }) async {
    final params = <String, String>{
      if (cameraIds != null && cameraIds.isNotEmpty)
        'camera_ids': cameraIds.join(','),
    };
    final uri = Uri.parse(
      '${s.base}/lpr/overview',
    ).replace(queryParameters: params.isEmpty ? null : params);
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode == 404 || resp.statusCode == 405) return null;
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load plate overview (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return LprOverview.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// `POST /lpr/plates/stats {plates}` for at most [kPlateStatsMaxBatch]
  /// plates. Null when the server predates the endpoint (404/405).
  Future<Map<String, PlateStats>?> getPlateStats(
    Session s,
    List<String> plates,
  ) async {
    if (plates.isEmpty) return const {};
    final resp = await _client.post(
      Uri.parse('${s.base}/lpr/plates/stats'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({'plates': plates.take(kPlateStatsMaxBatch).toList()}),
    );
    if (resp.statusCode == 404 || resp.statusCode == 405) return null;
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load plate history (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return parsePlateStatsResponse(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
}
