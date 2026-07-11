// Thin Dart HTTP client for the Crumb server API. JSON + Bearer JWT.
//
// Route facts (see services/api): login is POST /auth/login (NOT under /api);
// cameras + per-camera streams are at the root (/cameras, /cameras/{id}/streams).
// The bearer JWT goes in the Authorization header on every authed call. The
// short-lived ?token= media claim is a SEPARATE thing used for HTTP media
// (snapshots/segments/MSE) — the live RTSP wall does not use it, so it isn't
// implemented here yet.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class CrumbApiException implements Exception {
  CrumbApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'CrumbApiException($statusCode): $message';
}

class CrumbApi {
  CrumbApi({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static String _normalizeBase(String base) {
    var b = base.trim();
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'http://$b';
    }
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /// POST /auth/login → a bearer session. `remember` yields a long-lived token.
  Future<Session> login(
    String base,
    String username,
    String password, {
    bool remember = true,
  }) async {
    final b = _normalizeBase(base);
    final resp = await _http.post(
      Uri.parse('$b/auth/login'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'remember': remember,
      }),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        resp.statusCode == 401
            ? 'Invalid username or password.'
            : 'Login failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return Session(
      base: b,
      token: j['token'] as String,
      expiresAt: DateTime.tryParse((j['expires_at'] as String?) ?? ''),
    );
  }

  /// GET /cameras → the viewer-visible camera list.
  Future<List<Camera>> listCameras(Session s) async {
    final resp = await _http.get(
      Uri.parse('${s.base}/cameras'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load cameras (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => Camera.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// GET /cameras/{id}/streams → live RTSP (+ WebRTC) URLs for one camera.
  Future<StreamUrls> cameraStreams(Session s, String cameraId) async {
    final resp = await _http.get(
      Uri.parse('${s.base}/cameras/$cameraId/streams'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load streams (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return StreamUrls.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  void close() => _http.close();
}
