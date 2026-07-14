// Server dashboard API — connection/health, per-camera + per-policy storage
// stats, and the retention policy editor. All routes are mounted at ROOT (no
// /api prefix) and admin-only except GET /status, which any authenticated
// user may call (storages are omitted for non-admins server-side).
//
// Ported from apps/desktop/src/app.js (srvLoadStats, srvLoadHealth,
// srvLoadPolicyUsage, srvVerifyPolicySizes, srvLoadPolicyList, srvHandleSave)
// against services/api/src/status.rs, stats.rs, config_routes.rs.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';
import 'server_dashboard_models.dart';

extension ServerDashboardApi on CrumbApi {
  Future<T> _get<T>(
    Session s,
    String path,
    T Function(Map<String, dynamic>) parse, {
    Duration? timeout,
  }) async {
    var future = _client(this).get(
      Uri.parse('${s.base}$path'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (timeout != null) future = future.timeout(timeout);
    final resp = await future;
    if (resp.statusCode == 403) {
      throw CrumbApiException(
        'Administrator account required.',
        statusCode: 403,
      );
    }
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'GET $path failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return parse(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<RecordingPolicy> _putPolicy(
    Session s,
    String path,
    PolicyPatch patch,
  ) async {
    final resp = await _client(this).put(
      Uri.parse('${s.base}$path'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode(patch.toJson()),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Policy update failed (HTTP ${resp.statusCode}): ${resp.body}',
        statusCode: resp.statusCode,
      );
    }
    return RecordingPolicy.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  /// GET /status → connection/health snapshot: per-storage disk usage
  /// (admin only; empty list for non-admins) and per-camera recording health
  /// (all users, scoped to what they can see).
  Future<ServerStatus> getStatus(Session s) =>
      _get(s, '/status', ServerStatus.fromJson);

  /// GET /stats/cameras → per-camera storage + ingest statistics (admin only).
  Future<List<CameraStat>> getCameraStats(Session s) => _get(
    s,
    '/stats/cameras',
    (j) => ((j['cameras'] as List<dynamic>?) ?? const [])
        .map((e) => CameraStat.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
  );

  /// GET /stats/policies → per-effective-policy live/archive usage + eviction
  /// forecast (admin only).
  Future<List<PolicyStat>> getPolicyStats(Session s) => _get(
    s,
    '/stats/policies',
    (j) => ((j['policies'] as List<dynamic>?) ?? const [])
        .map((e) => PolicyStat.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
  );

  /// GET /stats/policies/verify → on-demand DB-tracked vs actual-on-disk byte
  /// reconciliation (admin only). This walks the media mounts file-by-file on
  /// the server and can legitimately take longer than the normal 30 s json
  /// timeout on a large/slow archive, so it's mounted with no server-side
  /// timeout; give the client call a generous one too.
  Future<List<PolicyVerify>> verifyPolicySizes(Session s) => _get(
    s,
    '/stats/policies/verify',
    (j) => ((j['policies'] as List<dynamic>?) ?? const [])
        .map((e) => PolicyVerify.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    timeout: const Duration(seconds: 120),
  );

  /// GET /config/cameras → full camera list with resolved policy (admin only).
  /// Used to populate the retention policy editor's per-camera picker.
  Future<List<CameraConfigSummary>> listConfigCameras(Session s) async {
    final resp = await _client(this).get(
      Uri.parse('${s.base}/config/cameras'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode == 403) {
      throw CrumbApiException(
        'Administrator account required.',
        statusCode: 403,
      );
    }
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load cameras (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => CameraConfigSummary.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// GET /config/policy/default → the global default recording policy.
  Future<RecordingPolicy> getDefaultPolicy(Session s) =>
      _get(s, '/config/policy/default', RecordingPolicy.fromJson);

  /// PUT /config/policy/default → partial update of the global default
  /// policy. Only the fields set on `patch` are sent.
  Future<RecordingPolicy> updateDefaultPolicy(Session s, PolicyPatch patch) =>
      _putPolicy(s, '/config/policy/default', patch);

  /// PUT /config/cameras/{id}/policy → partial update of one camera's own
  /// recording policy. If the camera currently inherits (from its group or
  /// the default), the server transparently forks a new per-camera policy
  /// (copy-on-write) and returns that; if it's grouped, the server 400s
  /// (ungroup or edit the group's policy instead).
  Future<RecordingPolicy> updateCameraPolicy(
    Session s,
    String cameraId,
    PolicyPatch patch,
  ) => _putPolicy(s, '/config/cameras/$cameraId/policy', patch);
}

// CrumbApi doesn't expose its internal http.Client, so this extension carries
// its own — cheap (no connection pool of its own to manage beyond the default
// client) and keeps this file from needing an edit to crumb_api.dart.
final http.Client _sharedClient = TimeoutClient();
http.Client _client(CrumbApi _) => _sharedClient;
