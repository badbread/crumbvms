// API call for the update-available check. Kept as an extension on the
// shared `CrumbApi` (see lib/api/crumb_api.dart) rather than editing that
// file directly — `CrumbApi`'s underlying `http.Client` is private, so this
// uses plain top-level `http.get`, same approach as
// lib/api/recording_alerts_api.dart / lib/api/status_api.dart.
//
// Route facts (services/api/src/updates.rs):
//   GET /updates/latest            — Bearer, ANY authenticated user (viewers
//                                     running wall displays/phones included;
//                                     not admin-only).
//   GET /updates/latest?refresh=1  — same route, forces a fresh server-side
//                                     GitHub check ("Check now"), itself
//                                     rate-limited server-side to 1/60s.
//
// `enabled: false` in a 200 body means the operator has the check turned off
// (server-mediated per docs/UPDATE-SYSTEM-PLAN.md D2 — this client never
// talks to GitHub itself). A 404 means the server predates this endpoint
// entirely. Both cases mean "show nothing" to the caller, but are
// distinguished here (null vs. a disabled response) in case a future caller
// wants to tell them apart; UpdateCheckController collapses both to "no
// update state" today, matching the old client's updCheck.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'models.dart';
import 'updates_models.dart';

extension UpdatesApi on CrumbApi {
  /// GET /updates/latest (optionally forcing a fresh GitHub check server-side
  /// via `?refresh=1`, "Check now"). Returns `null` for a 404 (server too old
  /// for the endpoint) so callers can silently show nothing rather than
  /// treating a missing route as an error.
  Future<UpdateCheckResponse?> getLatestUpdate(
    Session s, {
    bool refresh = false,
  }) async {
    final uri = Uri.parse(
      '${s.base}/updates/latest${refresh ? '?refresh=1' : ''}',
    );
    final resp = await http.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to check for updates (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return UpdateCheckResponse.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
}
