// Home Assistant integration API calls: connection config + entity linking
// (issue #52, desktop port of the admin console's flow) and the on-video
// overlay's linked entities + placement + live states feed (issue #170).
// Kept as an extension on the shared `CrumbApi` (see crumb_api.dart) rather
// than editing that file directly — same approach as `status_api.dart`,
// using the shared process-wide `TimeoutClient` since `CrumbApi`'s own
// client is private to that file.
//
// Route facts (services/api/src/ha.rs):
//   GET  /config/ha                                 -> HaConfigDto. Admin.
//   PUT  /config/ha            body {enabled,base_url,token?} -> HaConfigDto.
//                                                       Admin. Omit `token`
//                                                       to leave it
//                                                       unchanged, `""` to
//                                                       clear, non-empty to
//                                                       set — write-only,
//                                                       never returned.
//   POST /config/ha/test                             -> {ok:true} or an
//                                                       error. Admin. Tests
//                                                       the SAVED config —
//                                                       save first.
//   GET  /ha/entities?domain=binary_sensor|controls  -> HaEntity[]. Admin.
//                                                       The picker's data
//                                                       source; `controls` =
//                                                       light+switch+scene.
//   GET  /cameras/{id}/ha/links                      -> HaLinkDto[] (any user
//                                                       with camera access)
//   PUT  /cameras/{id}/ha/links  body {links:[...]}  -> HaLinkDto[]. Admin.
//                                                       Replaces the
//                                                       camera's FULL link
//                                                       set (not a diff).
//   PUT  /cameras/{id}/ha/links/{link_id}/placement   body {x,y,size, color?,
//                                                       icon?, show_state?,
//                                                       show_age?, label?} pins
//                                                       the badge (+ per-badge
//                                                       style, migration 0059);
//                                                       a literal JSON `null`
//                                                       body clears it.
//                                                       Admin-only server-side
//                                                       (matches link writes).
//                                                       Returns the updated
//                                                       link.
//   GET  /ha/states                                  -> HaStatesResponse (any
//                                                       authenticated user;
//                                                       RBAC-projected to the
//                                                       caller's cameras)

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'ha_models.dart';
import 'http_client.dart';
import 'models.dart';

extension HaApi on CrumbApi {
  /// GET /config/ha — admin. The Home Assistant connection config (never
  /// includes the token itself — see [HaConfig.hasToken]).
  Future<HaConfig> getHaConfig(Session s) async {
    final resp = await sharedHttpClient.get(
      Uri.parse('${s.base}/config/ha'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load Home Assistant settings '
        '(HTTP ${resp.statusCode}): ${_errorDetail(resp)}',
        statusCode: resp.statusCode,
      );
    }
    return HaConfig.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// PUT /config/ha — admin. `token` is write-only: pass `null` to leave the
  /// stored token unchanged, `''` to clear it, or a non-empty string to set
  /// it — mirrors the admin console's `saveHa()` (never sends `token` unless
  /// the operator typed one). Returns the updated config.
  Future<HaConfig> putHaConfig(
    Session s, {
    required bool enabled,
    required String baseUrl,
    String? token,
  }) async {
    final resp = await sharedHttpClient.put(
      Uri.parse('${s.base}/config/ha'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'enabled': enabled,
        'base_url': baseUrl,
        if (token != null) 'token': token,
      }),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to save Home Assistant settings '
        '(HTTP ${resp.statusCode}): ${_errorDetail(resp)}',
        statusCode: resp.statusCode,
      );
    }
    return HaConfig.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// POST /config/ha/test — admin. Authenticated reachability check against
  /// the STORED (already-saved) config — mirrors the admin console's "Save
  /// first, then Test" note. Throws [CrumbApiException] with the server's
  /// detail message on failure; returns normally on success.
  Future<void> testHaConfig(Session s) async {
    final resp = await sharedHttpClient.post(
      Uri.parse('${s.base}/config/ha/test'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(_errorDetail(resp), statusCode: resp.statusCode);
    }
  }

  /// GET /ha/entities?domain=... — admin. The entity picker's data source;
  /// `domain` is `binary_sensor` (sensor picker) or `controls` (light+switch
  /// +scene, actuator picker) — mirrors the admin console's `haOpenPicker`.
  Future<List<HaEntity>> haEntities(Session s, {required String domain}) async {
    final resp = await sharedHttpClient.get(
      Uri.parse(
        '${s.base}/ha/entities',
      ).replace(queryParameters: {'domain': domain}),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load Home Assistant entities '
        '(HTTP ${resp.statusCode}): ${_errorDetail(resp)}',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => HaEntity.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// PUT /cameras/{id}/ha/links — admin. Replaces the camera's FULL link set
  /// (mirrors the admin console's `saveHaLinks()` — the whole array, not a
  /// diff). Returns the saved links (with server-assigned ids).
  Future<List<HaLink>> saveCameraHaLinks(
    Session s,
    String cameraId,
    List<HaLinkInput> links,
  ) async {
    final resp = await sharedHttpClient.put(
      Uri.parse('${s.base}/cameras/$cameraId/ha/links'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({'links': links.map((l) => l.toJson()).toList()}),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to save Home Assistant links '
        '(HTTP ${resp.statusCode}): ${_errorDetail(resp)}',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => HaLink.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// GET /cameras/{id}/ha/links — the camera's linked HA entities, including
  /// on-video placement if any.
  Future<List<HaLink>> cameraHaLinks(Session s, String cameraId) async {
    final resp = await sharedHttpClient.get(
      Uri.parse('${s.base}/cameras/$cameraId/ha/links'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load HA links (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => HaLink.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<http.Response> _putPlacement(
    Session s,
    String cameraId,
    String linkId,
    Object? body,
  ) {
    return sharedHttpClient.put(
      Uri.parse('${s.base}/cameras/$cameraId/ha/links/$linkId/placement'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
  }

  /// PUT .../placement — pin the badge at `(x, y)` [each 0..1, a fraction of
  /// the video frame] with a size multiplier (server clamps/validates), plus
  /// the per-badge display overrides (migration 0059): `color` is a
  /// '#RRGGBB' hex string, `icon` a curated slug, `showState`/`showAge` pin
  /// the live state text / relative age next to the badge on the wall.
  /// `label` edits the LINK-level caption and follows the `PUT /config/ha`
  /// token convention: null ⇒ unchanged, `''` ⇒ cleared, non-empty ⇒ set.
  /// Returns the updated link.
  Future<HaLink> saveHaPlacement(
    Session s,
    String cameraId,
    String linkId, {
    required double x,
    required double y,
    double size = 1.0,
    String? color,
    String? icon,
    bool showState = false,
    bool showAge = false,
    double opacity = 1.0,
    String? shape,
    String? bgColor,
    bool outline = false,
    String? label,
  }) async {
    final resp = await _putPlacement(s, cameraId, linkId, {
      'x': x,
      'y': y,
      'size': size,
      if (color != null) 'color': color,
      if (icon != null) 'icon': icon,
      'show_state': showState,
      'show_age': showAge,
      'opacity': opacity,
      if (shape != null) 'shape': shape,
      if (bgColor != null) 'bg_color': bgColor,
      'outline': outline,
      if (label != null) 'label': label,
    });
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to save HA badge placement (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return HaLink.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// PUT .../placement with a `null` body — clears the badge's placement.
  /// Returns the updated (now-unplaced) link.
  Future<HaLink> clearHaPlacement(
    Session s,
    String cameraId,
    String linkId,
  ) async {
    final resp = await _putPlacement(s, cameraId, linkId, null);
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to clear HA badge placement (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return HaLink.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// GET /ha/states — current state of every HA entity linked to a camera
  /// the caller can access, from the server's demand-driven cache. Throws
  /// [CrumbApiException] on any non-200 (400 "not enabled", 502 "unreachable"
  /// past the server's stale window, ...) — callers should treat any failure
  /// as "keep last-known, mark stale", mirroring
  /// `LiveStatusController`'s `/events` failure handling.
  Future<HaStatesSnapshot> haStates(Session s) async {
    final resp = await sharedHttpClient.get(
      Uri.parse('${s.base}/ha/states'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load HA states (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return HaStatesSnapshot.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }
}

/// Best-effort extraction of the server's `{"error":..., "message":...}`
/// JSON error body (services/api/src/error.rs) down to a human-readable
/// string; falls back to the raw body. Mirrors `export_api.dart`'s identical
/// inline pattern, factored out here since four methods above need it.
String _errorDetail(http.Response resp) {
  try {
    return (jsonDecode(resp.body) as Map<String, dynamic>)['message']
            as String? ??
        resp.body;
  } catch (_) {
    return resp.body;
  }
}
