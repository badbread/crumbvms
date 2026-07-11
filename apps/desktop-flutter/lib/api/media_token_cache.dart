// Per-camera scoped media-token cache + in-flight dedupe, mirroring the old
// client's `mediaTokenCache` / `mediaTokenInflight` (apps/desktop/src/app.js,
// see `getMediaToken` / `mediaUrlForCamera` / `clearMediaTokens`).
//
// One [MediaTokenCache] should live for the lifetime of a signed-in session
// (construct it after login, drop/replace it on sign-out) and be shared by
// every widget that builds a media URL: playback segment panes, clip
// players, the filmstrip, snapshots, frame.jpg, the motion-tuner MSE stream.

import 'crumb_api.dart';
import 'media_token_api.dart';
import 'models.dart';

/// Refresh a cached token if it expires within this many seconds — mirrors
/// the old client's 10s `MEDIA_TOKEN_REFRESH_MARGIN_MS`, matched against the
/// server's 900s (`MEDIA_TOKEN_EXPIRY_SECONDS`) media-token lifetime.
const _refreshMargin = Duration(seconds: 10);

class MediaTokenCache {
  MediaTokenCache({
    required CrumbApi api,
    required Session session,
    required this.onUnauthorized,
  }) : _api = api,
       _session = session;

  final CrumbApi _api;
  Session _session;

  /// Called when a media-token request comes back 401 (session expired or
  /// revoked mid-wall). The caller is expected to drop the current token and
  /// surface a re-auth prompt (see lib/session/session_controller.dart) —
  /// this cache does not know how to do that itself. Do NOT fall back to the
  /// full bearer JWT in a media URL; let the caller retry once re-auth
  /// completes and a fresh [Session] has been supplied via [updateSession].
  final void Function() onUnauthorized;

  final Map<String, MediaToken> _cache = {};
  final Map<String, Future<String?>> _inflight = {};

  /// Swap in a fresh [Session] (e.g. after a successful re-auth). Cached
  /// tokens are left in place — they remain valid (scoped to the camera, not
  /// the login token) until their own expiry.
  void updateSession(Session session) {
    _session = session;
  }

  /// Return a fresh scoped media token for `cameraId`, minting/refreshing as
  /// needed. Concurrent callers for the same camera share one in-flight
  /// request. Returns null on failure; a 401 additionally invokes
  /// [onUnauthorized].
  Future<String?> getToken(String cameraId) {
    final cached = _cache[cameraId];
    if (cached != null &&
        cached.expiresAt.difference(DateTime.now().toUtc()) >
            _refreshMargin) {
      return Future.value(cached.token);
    }
    final existing = _inflight[cameraId];
    if (existing != null) return existing;

    final future = _mint(cameraId).whenComplete(() {
      _inflight.remove(cameraId);
    });
    _inflight[cameraId] = future;
    return future;
  }

  Future<String?> _mint(String cameraId) async {
    try {
      final tok = await _api.fetchMediaToken(_session, cameraId);
      _cache[cameraId] = tok;
      return tok.token;
    } on CrumbApiException catch (e) {
      if (e.statusCode == 401) {
        onUnauthorized();
      }
      return null; // transient/permission failure — caller's retry re-requests
    } catch (_) {
      return null;
    }
  }

  /// Append `?token=<scoped media token>` to a server-relative media URL for
  /// one camera (e.g. `/clip/<id>/clip.mp4?q=full`, `/cameras/<id>/frame.jpg`).
  /// Awaits a fresh token; returns null if none could be minted — callers
  /// must NOT fall back to putting the full bearer JWT in the URL.
  Future<String?> mediaUrl(String cameraId, String relUrl) async {
    final tok = await getToken(cameraId);
    if (tok == null) return null;
    final sep = relUrl.contains('?') ? '&' : '?';
    return '${_session.base}$relUrl${sep}token=${Uri.encodeComponent(tok)}';
  }

  /// Drop all cached/in-flight tokens (e.g. on 401 / sign-out) so a stale
  /// principal's scoped tokens are never reused by the next signed-in user.
  void clear() {
    _cache.clear();
    _inflight.clear();
  }
}
