// Status/detections API calls for the live-status-poll feature. Kept as an
// extension on the shared `CrumbApi` (see lib/api/crumb_api.dart) rather than
// editing that file directly. `CrumbApi`'s underlying `http.Client` is
// private, so this extension uses plain top-level `http.get` calls — same
// approach, just without reusing the connection pool.
//
// Route facts (services/api/src/status.rs, services/api/src/events.rs):
//   GET /status  — Bearer, root-mounted. Per-camera recording/motion health +
//                  config_version + bookmarks_enabled. Any authed user (scope
//                  is server-enforced: viewers only see their own cameras).
//   GET /events?camera_ids=<csv>&start=<iso>&end=<iso>[&labels=<csv>][&limit=N]
//               — Bearer, root-mounted. Detection events in [start, end).
//                 `start`/`end` must be RFC3339 — `DateTime.toUtc().toIso8601String()`
//                 already yields a valid `...Z` instant.

import 'dart:convert';

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';
import 'status_models.dart';

extension StatusApi on CrumbApi {
  /// GET /status → per-camera recording/motion health + config fingerprint +
  /// the platform-wide bookmarks toggle.
  Future<SystemStatus> getStatus(Session s) async {
    final resp = await sharedHttpClient.get(
      Uri.parse('${s.base}/status'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load status (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return SystemStatus.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// GET /events for the given cameras within `[start, end)`. Used to derive
  /// "actively detecting X right now" glyphs — callers typically pass a short
  /// trailing window (e.g. the last ~25s) plus a small forward pad.
  Future<EventsResponse> getEvents(
    Session s, {
    required List<String> cameraIds,
    required DateTime start,
    required DateTime end,
    int limit = 100,
  }) async {
    if (cameraIds.isEmpty) {
      return EventsResponse(events: const [], total: 0, hasMore: false);
    }
    final uri = Uri.parse('${s.base}/events').replace(
      queryParameters: {
        'camera_ids': cameraIds.join(','),
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'limit': '$limit',
      },
    );
    final resp = await sharedHttpClient.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load events (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return EventsResponse.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }
}
