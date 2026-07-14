// PTZ "extras" beyond continuous pan/tilt/zoom/home (see crumb_api.dart):
// preset list/recall and ONVIF imaging (focus/iris) controls. Kept as a
// separate extension so crumb_api.dart stays untouched.
//
// Route facts (services/api/src/ptz.rs):
//   POST /cameras/{id}/ptz     {action:'presets'}            -> {presets:[{token,name}]}
//   POST /cameras/{id}/ptz     {action:'preset', preset:tok} -> {}
//   POST /cameras/{id}/imaging {action, speed?}              -> {}
// Both routes require Bearer auth + the server-side PTZ capability/camera
// access check (same gate as the base ptz.move/stop/home calls). `imaging`
// actions are snake_case: focus_near, focus_far, focus_stop, auto_focus,
// iris_open, iris_close, iris_auto (services/api/src/ptz.rs ImagingAction).

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// One ONVIF PTZ preset (`GET`-via-POST `action=presets` response entry).
class PtzPreset {
  PtzPreset({required this.token, required this.name});

  final String token;
  final String name;

  /// Display label: falls back to "Preset {token}" when the camera didn't
  /// set a name (mirrors app.js's `wirePtzPanel` preset-select behavior).
  String get label => name.trim().isNotEmpty ? name : 'Preset $token';

  factory PtzPreset.fromJson(Map<String, dynamic> j) => PtzPreset(
    token: j['token'] as String,
    name: (j['name'] as String?) ?? '',
  );
}

/// Imaging (focus/iris) actions for `POST /cameras/{id}/imaging`. Values are
/// the exact snake_case wire strings the server expects.
enum ImagingAction {
  focusNear('focus_near'),
  focusFar('focus_far'),
  focusStop('focus_stop'),
  autoFocus('auto_focus'),
  irisOpen('iris_open'),
  irisClose('iris_close'),
  irisAuto('iris_auto');

  const ImagingAction(this.wire);
  final String wire;
}

extension PtzExtrasApi on CrumbApi {
  Future<http.Response> _post(
    Session s,
    String path,
    Map<String, dynamic> body,
  ) {
    return httpClientForExtras.post(
      Uri.parse('${s.base}$path'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
  }

  /// List the camera's configured ONVIF presets. Best-effort: an empty list
  /// on any non-200 (matches app.js's `ptzFetchPresetsFor`, which also
  /// swallows errors — presets are a nice-to-have, not core PTZ).
  Future<List<PtzPreset>> ptzPresets(Session s, String cameraId) async {
    try {
      final resp = await _post(s, '/cameras/$cameraId/ptz', {
        'action': 'presets',
      });
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (j['presets'] as List<dynamic>?) ?? const [];
      return list
          .map((e) => PtzPreset.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Recall a saved preset by its ONVIF token.
  Future<void> ptzRecallPreset(
    Session s,
    String cameraId,
    String presetToken,
  ) async {
    final resp = await _post(s, '/cameras/$cameraId/ptz', {
      'action': 'preset',
      'preset': presetToken,
    });
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'PTZ preset recall failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }

  /// Drive ONVIF imaging (focus/iris). `speed` (0.0–1.0) only applies to
  /// focus_near/focus_far; the server defaults it when omitted.
  Future<void> imagingCmd(
    Session s,
    String cameraId,
    ImagingAction action, {
    double? speed,
  }) async {
    final resp = await _post(s, '/cameras/$cameraId/imaging', {
      'action': action.wire,
      if (speed != null) 'speed': speed,
    });
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Imaging ${action.wire} failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }
}

/// CrumbApi's `http.Client` is private; extensions can't reach it, so this
/// extra file keeps its own client instance. Cheap (no connection state is
/// shared across `http.Client`s in the package) and avoids touching
/// crumb_api.dart.
final http.Client httpClientForExtras = TimeoutClient();
