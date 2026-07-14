// API calls for the recording-health alert banner feature. Kept as an
// extension on the shared `CrumbApi` (see lib/api/crumb_api.dart) rather than
// editing that file directly. `CrumbApi`'s underlying `http.Client` is
// private, so this extension uses plain top-level `http.get` calls — same
// approach as lib/api/status_api.dart.
//
// Route facts (services/api/src/status.rs, services/api/src/stats.rs):
//   GET /status         — Bearer, root-mounted. `storages` + `recorder_heartbeat`
//                         are ADMIN-ONLY (empty/null for non-admin sessions —
//                         the server silently withholds them, no 403).
//   GET /stats/policies — Bearer, root-mounted, ADMIN ONLY. 403 for non-admins;
//                         callers should treat that as "no policy warnings"
//                         rather than surfacing an error banner.

import 'dart:convert';

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';
import 'recording_alerts_models.dart';

extension RecordingAlertsApi on CrumbApi {
  /// GET /status, parsed for just the admin-only storages + recorder-heartbeat
  /// fields this feature needs. Non-admin sessions get an empty/null result,
  /// not an error.
  Future<RecordingStatusSnapshot> getRecordingStatus(Session s) async {
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
    return RecordingStatusSnapshot.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  /// GET /stats/policies — admin only. Returns `null` on 403 (viewer/operator
  /// session) so callers can skip the policy-derived warnings without
  /// treating it as a transient failure.
  Future<PolicyStatsResponse?> getPolicyStats(Session s) async {
    final resp = await sharedHttpClient.get(
      Uri.parse('${s.base}/stats/policies'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode == 403) return null;
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load policy stats (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return PolicyStatsResponse.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
}
