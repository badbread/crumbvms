// Scoped, short-lived media tokens (`GET /media-token?camera=<id>`).
//
// Every media URL handed to a native player / <video> / <img> (recorded
// segments, clips, filmstrip thumbnails, snapshots, the motion-tuner MSE
// stream) must NOT carry the long-lived bearer JWT — that leaks into
// proxy/access logs and can be valid for up to 10 years. Instead mint a
// ~15-minute, single-camera scoped token via this route (called WITH the
// full JWT in the Authorization header) and put THAT in the media URL as
// `?token=`.
//
// Deliberately NOT covered here: the live wall (RTSP-direct to go2rtc, no
// API token in the URL to begin with) and export downloads (can span
// multiple cameras / the archive, so they keep the full-JWT / Authorization
// header pattern). See services/api/src/auth.rs (`media_token`,
// `MEDIA_TOKEN_EXPIRY_SECONDS`) and the old client's `getMediaToken` /
// `mediaUrlForCamera` in apps/desktop/src/app.js.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'models.dart';

/// `GET /media-token` response — a scoped token good for exactly one camera.
class MediaToken {
  MediaToken({
    required this.token,
    required this.cameraId,
    required this.expiresAt,
  });

  final String token;
  final String cameraId;
  final DateTime expiresAt;

  factory MediaToken.fromJson(Map<String, dynamic> j) => MediaToken(
    token: j['token'] as String,
    cameraId: (j['camera_id'] as String?) ?? '',
    // Server always sends a valid RFC 3339 expiry; fall back to a short
    // window if it's ever missing so a parse hiccup can't look "forever".
    expiresAt:
        DateTime.tryParse((j['expires_at'] as String?) ?? '') ??
        DateTime.now().toUtc().add(const Duration(seconds: 60)),
  );
}

/// Mints scoped media tokens. Added as an extension (not a method on
/// [CrumbApi] itself) so this feature stays a self-contained file — see
/// apps/desktop-flutter/lib/api/crumb_api.dart's header comment.
extension MediaTokenApi on CrumbApi {
  /// `GET /media-token?camera=<id>` (mounted at the server root, NOT under
  /// `/auth` — see `auth::media_token_routes()` in services/api/src/main.rs).
  /// Requires the full bearer JWT; the server further checks the caller can
  /// access `cameraId` (403 if not).
  ///
  /// Uses a fresh, short-lived [http.Client] per call rather than reaching
  /// into [CrumbApi]'s internal client (which is private to crumb_api.dart
  /// and this feature must not edit that file) — media-token calls are
  /// infrequent (each result is cached ~15 min per camera by
  /// [MediaTokenCache]) so this has no meaningful cost.
  Future<MediaToken> fetchMediaToken(Session s, String cameraId) async {
    final client = http.Client();
    try {
      final resp = await client.get(
        Uri.parse(
          '${s.base}/media-token?camera=${Uri.encodeComponent(cameraId)}',
        ),
        headers: {'authorization': 'Bearer ${s.token}'},
      );
      if (resp.statusCode != 200) {
        throw CrumbApiException(
          resp.statusCode == 401
              ? 'Session expired.'
              : resp.statusCode == 403
              ? 'Not permitted to view that camera.'
              : 'Failed to mint media token (HTTP ${resp.statusCode}).',
          statusCode: resp.statusCode,
        );
      }
      return MediaToken.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>,
      );
    } finally {
      client.close();
    }
  }
}
