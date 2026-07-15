// Home Assistant on-video overlay API calls (issue #170): a camera's linked
// entities + on-video placement, and the live states feed. Kept as an
// extension on the shared `CrumbApi` (see crumb_api.dart) rather than editing
// that file directly — same approach as `status_api.dart`, using the shared
// process-wide `TimeoutClient` since `CrumbApi`'s own client is private to
// that file.
//
// Route facts (services/api/src/ha.rs):
//   GET /cameras/{id}/ha/links                      -> HaLinkDto[] (any user
//                                                       with camera access)
//   PUT /cameras/{id}/ha/links/{link_id}/placement   body {x,y,size} pins the
//                                                       badge; a literal JSON
//                                                       `null` body clears it.
//                                                       Admin-only server-side
//                                                       (matches link writes).
//                                                       Returns the updated
//                                                       link.
//   GET /ha/states                                   -> HaStatesResponse (any
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
  /// the video frame] with a size multiplier (server clamps/validates).
  /// Returns the updated link.
  Future<HaLink> saveHaPlacement(
    Session s,
    String cameraId,
    String linkId, {
    required double x,
    required double y,
    double size = 1.0,
  }) async {
    final resp = await _putPlacement(s, cameraId, linkId, {
      'x': x,
      'y': y,
      'size': size,
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
