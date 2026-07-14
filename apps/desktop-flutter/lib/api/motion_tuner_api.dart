// Motion tuner data layer: per-camera live activity grid, full motion config
// (exclusion mask, authoring-grid size, additive detector sources), and the
// admin-only camera-config PUT used to persist them. Ported from the old
// Tauri client's inline Motion Tuner (apps/desktop/src/app.js, `mtOpen` /
// `mtPoll` / `mtSave` / `mtApplyMotionConfig` / `mtPersistGrid`, ~line 12279
// onward) against the real endpoints in services/api/src/playback.rs
// (`GET /cameras/{id}/motion-grid`) and services/api/src/config_routes.rs
// (`GET/PUT /config/cameras/{id}`, admin only).
//
// Threshold + sensitivity (motion_threshold / motion_sensitivity) are NOT
// re-implemented here — the tuner persists those via the EXISTING
// `ServerDashboardApi.updateCameraPolicy` (lib/api/server_dashboard_api.dart),
// which already wraps `PUT /config/cameras/{id}/policy` with the same
// partial-update [PolicyPatch] shape the retention-policy editor uses. Reuse
// that, don't duplicate it.
//
// NOTE (ground truth vs the old client): app.js's `motion_source` picker
// (pixel XOR frigate) is DEPRECATED server-side (migration 0049) in favor of
// ADDITIVE per-source toggles — `motion_pixel_enabled` / `motion_frigate_enabled`
// / `motion_ha_enabled` (migration 0058, Home Assistant Phase 2) — a camera
// records on the UNION of whichever sources are enabled. This file follows the
// CURRENT `CameraDto`/`UpdateCameraRequest` shape (services/api/src/dto.rs),
// not the old single-select UI.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// `GET /cameras/{id}/motion-grid` response (`MotionGrid`, services/common/src/
/// types.rs) — the recorder's latest live per-cell foreground coverage grid,
/// plus the SAME largest-blob score + effective floor it triggers recording
/// on. `cells` is a flat, row-major array of length `cols*rows`, each 0..100
/// (% coverage of that cell). `score`/`threshold` are FRACTIONS of frame area
/// (0..1) — multiply by 100 for a percentage, matching `motion_threshold` on
/// the policy.
class MotionGridSnapshot {
  MotionGridSnapshot({
    required this.cols,
    required this.rows,
    required this.cells,
    required this.score,
    required this.threshold,
    required this.updatedAt,
  });

  final int cols;
  final int rows;
  final List<double> cells; // row-major, length cols*rows, each 0..100
  final double score; // fraction 0..1 — recorder's live largest-blob score
  final double threshold; // fraction 0..1 — recorder's live effective floor
  final DateTime? updatedAt;

  double cellAt(int gx, int gy) {
    final i = gy * cols + gx;
    if (i < 0 || i >= cells.length) return 0;
    return cells[i];
  }

  factory MotionGridSnapshot.fromJson(Map<String, dynamic> j) =>
      MotionGridSnapshot(
        cols: (j['cols'] as num?)?.toInt() ?? 0,
        rows: (j['rows'] as num?)?.toInt() ?? 0,
        cells: ((j['cells'] as List<dynamic>?) ?? const [])
            .map((e) => (e as num).toDouble())
            .toList(growable: false),
        score: (j['score'] as num?)?.toDouble() ?? 0.0,
        threshold: (j['threshold'] as num?)?.toDouble() ?? 0.0,
        updatedAt: DateTime.tryParse((j['updated_at'] as String?) ?? ''),
      );
}

/// A normalized exclusion rect `[x, y, w, h]` (0..1, relative to frame),
/// mirroring the wire shape of `motion_mask` (`CameraDto`/`UpdateCameraRequest`,
/// dto.rs — `Vec<[f32; 4]>`-equivalent `serde_json::Value`). The old client
/// also tolerates a LEGACY polygon shape (`[[x,y],...]`) it cannot edit; this
/// port only round-trips the normalized-rect form (see [motionMaskRects]).
typedef MaskRect = List<double>; // [x, y, w, h]

/// Full per-camera motion configuration for the tuner (`CameraDto`, dto.rs, as
/// returned by the admin-only `GET /config/cameras/{id}`). A superset of the
/// viewer-visible [Camera] in models.dart — includes the exclusion mask,
/// authoring-grid size, and additive detector-source toggles the wall/viewer
/// list never needs.
class CameraMotionConfig {
  CameraMotionConfig({
    required this.id,
    required this.name,
    required this.subUrl,
    required this.motionMask,
    required this.motionGridCols,
    required this.motionGridRows,
    required this.motionPixelEnabled,
    required this.motionFrigateEnabled,
    required this.motionHaEnabled,
    required this.motionAlgorithm,
    required this.motionSensitivity,
    required this.motionThreshold,
  });

  final String id;
  final String name;
  final String? subUrl; // null ⇒ no sub stream; the tuner falls back to frame.jpg only
  final List<MaskRect> motionMask; // normalized-rect exclusion zones only
  final int? motionGridCols; // operator's saved authoring-grid pref
  final int? motionGridRows;
  final bool motionPixelEnabled;
  final bool motionFrigateEnabled;
  final bool motionHaEnabled;
  final String motionAlgorithm; // census|framediff|mog2|opticalflow|ensemble
  final String motionSensitivity; // "dynamic" | "manual" (from the resolved policy)
  final double? motionThreshold; // fraction 0..1 (from the resolved policy)

  bool get hasSub => subUrl != null && subUrl!.isNotEmpty;

  factory CameraMotionConfig.fromJson(Map<String, dynamic> j) {
    final rawMask = j['motion_mask'];
    final rects = <MaskRect>[];
    if (rawMask is List) {
      for (final r in rawMask) {
        // Only normalized [x,y,w,h] numeric rects are editable here; a legacy
        // polygon ([[x,y],...]) is silently skipped (matches the old client's
        // mtRectsToCells, which only consumes numeric rects — the caller
        // should warn the operator separately if it wants mtLoadMaskToCells's
        // "legacy polygon" notice).
        if (r is List && r.length >= 4 && r[0] is num) {
          rects.add(r.map((e) => (e as num).toDouble()).toList());
        }
      }
    }
    final policy = j['policy'] as Map<String, dynamic>?;
    return CameraMotionConfig(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '(unnamed)',
      subUrl: j['sub_url'] as String?,
      motionMask: rects,
      motionGridCols: (j['motion_grid_cols'] as num?)?.toInt(),
      motionGridRows: (j['motion_grid_rows'] as num?)?.toInt(),
      motionPixelEnabled: (j['motion_pixel_enabled'] as bool?) ?? true,
      motionFrigateEnabled: (j['motion_frigate_enabled'] as bool?) ?? false,
      motionHaEnabled: (j['motion_ha_enabled'] as bool?) ?? false,
      motionAlgorithm: (j['motion_algorithm'] as String?) ?? 'census',
      motionSensitivity:
          (policy?['motion_sensitivity'] as String?) ?? 'dynamic',
      motionThreshold: (policy?['motion_threshold'] as num?)?.toDouble(),
    );
  }

  /// True if there's a legacy non-rect entry the tuner can't show (dropped by
  /// [fromJson]) — saving a new mask from this session would replace it.
  static bool hasLegacyPolygon(Map<String, dynamic> j) {
    final rawMask = j['motion_mask'];
    if (rawMask is! List) return false;
    return rawMask.any((r) => r is List && r.isNotEmpty && r[0] is List);
  }
}

/// A partial-update body for `PUT /config/cameras/{id}` (`UpdateCameraRequest`,
/// dto.rs), scoped to just the fields the motion tuner edits. Every field is
/// OMITTED unless explicitly set, matching the server's "absent = unchanged"
/// semantics — `motionMask(null)` sends an explicit JSON `null` (clears the
/// mask; the field uses the server's `Some(None)`-clears `double_option`
/// pattern), never calling it leaves the mask untouched.
class MotionConfigPatch {
  final Map<String, dynamic> _fields = {};

  bool get isEmpty => _fields.isEmpty;
  Map<String, dynamic> toJson() => Map.unmodifiable(_fields);

  /// Set (or clear, with `null`) the exclusion mask as normalized rects.
  void motionMask(List<MaskRect>? rects) =>
      _fields['motion_mask'] = rects?.map((r) => r.toList()).toList();

  void motionGridCols(int v) => _fields['motion_grid_cols'] = v;
  void motionGridRows(int v) => _fields['motion_grid_rows'] = v;
  void motionPixelEnabled(bool v) => _fields['motion_pixel_enabled'] = v;
  void motionFrigateEnabled(bool v) => _fields['motion_frigate_enabled'] = v;
  void motionHaEnabled(bool v) => _fields['motion_ha_enabled'] = v;
  void motionAlgorithm(String v) => _fields['motion_algorithm'] = v;
}

// CrumbApi doesn't expose its internal http.Client to other files (Dart
// library-privacy is file-scoped) — mirrors motion_timeline_api.dart /
// server_dashboard_api.dart, each carrying its own module-level client rather
// than editing crumb_api.dart.
final http.Client _client = TimeoutClient();

extension MotionTunerApi on CrumbApi {
  /// `GET /cameras/{id}/motion-grid` — the live per-cell activity grid for the
  /// tuner's heatmap + meter. Returns `null` if the recorder hasn't published
  /// one yet (motion disabled, camera just added, or no sub-stream analyzed).
  Future<MotionGridSnapshot?> fetchMotionGrid(
    Session s,
    String cameraId,
  ) async {
    final resp = await _client.get(
      Uri.parse('${s.base}/cameras/${Uri.encodeComponent(cameraId)}/motion-grid'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'GET motion-grid failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final body = resp.body.trim();
    if (body.isEmpty || body == 'null') return null;
    return MotionGridSnapshot.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
  }

  /// `GET /config/cameras/{id}` — full per-camera config for the tuner
  /// (admin only; 403 for non-admin accounts).
  Future<CameraMotionConfig> fetchCameraMotionConfig(
    Session s,
    String cameraId,
  ) async {
    final resp = await _client.get(
      Uri.parse('${s.base}/config/cameras/${Uri.encodeComponent(cameraId)}'),
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
        'GET /config/cameras/$cameraId failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return CameraMotionConfig.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  /// `PUT /config/cameras/{id}` with just the fields set on [patch] — saves
  /// the exclusion mask, authoring-grid size, and/or detector-source toggles.
  /// Returns the camera's full updated config (mirrors `mtSave`'s and
  /// `mtApplyMotionConfig`'s "reflect what was actually stored" behavior).
  Future<CameraMotionConfig> updateCameraMotionConfig(
    Session s,
    String cameraId,
    MotionConfigPatch patch,
  ) async {
    final resp = await _client.put(
      Uri.parse('${s.base}/config/cameras/${Uri.encodeComponent(cameraId)}'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode(patch.toJson()),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Save failed (HTTP ${resp.statusCode}): ${resp.body}',
        statusCode: resp.statusCode,
      );
    }
    return CameraMotionConfig.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
}
