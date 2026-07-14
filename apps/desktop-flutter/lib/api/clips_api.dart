// Clips API: GET /clips (time-cursor pager), POST /clips/viewed, the scoped
// media-token mint (GET /media-token?camera=<id>) that clip thumbnails/video
// ride on, and a minimal POST /bookmarks used by the clip player's bookmark
// button. See services/api/src/clips.rs, services/api/src/auth.rs
// (media_token), services/api/src/bookmarks.rs.
//
// Route facts: all mounted at ROOT (no /api prefix). `GET /clips` and
// `POST /clips/viewed` take the full bearer JWT like any other JSON route.
// The clip media endpoints (`/clip/:id/clip.mp4`, `/clip/:id/thumbnail.jpg`)
// are HTTP media (an <img>/<video> equivalent) and must NOT carry the bearer
// JWT — they take a short-lived, single-camera scoped `?token=` minted via
// `GET /media-token?camera=<id>` (itself called WITH the bearer JWT). This
// file mints and caches those tokens the same way the old Tauri client did
// (apps/desktop/src/app.js `getMediaToken`/`mediaUrlForCamera`): per-camera,
// ~15 min server-side lifetime, refreshed a bit early, concurrent callers for
// the same camera share one in-flight mint.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// One entry in the `GET /clips` feed — either a detection or a merged motion
/// run. `id` is opaque (`"d:<event-uuid>"` / `"m:<camera>:<start_ms>:<end_ms>"`)
/// and is what the media endpoints and `/clips/viewed` key off.
class ClipDescriptor {
  ClipDescriptor({
    required this.id,
    required this.cameraId,
    required this.cameraName,
    required this.kind,
    required this.label,
    required this.iconKey,
    required this.score,
    required this.startTs,
    required this.endTs,
    required this.durationMs,
    required this.thumbnailUrl,
    required this.clipUrl,
    required this.downloadUrl,
    required this.source,
    required this.viewed,
    required this.motionBbox,
  });

  final String id;
  final String cameraId;
  final String cameraName;
  final String kind; // "detection" | "motion"
  final String label;
  final String iconKey;
  final double? score;
  final DateTime startTs;
  final DateTime endTs;
  final int durationMs;
  final String thumbnailUrl; // server-relative
  final String clipUrl; // server-relative, "/clip/<id>/clip.mp4?q=preview"
  final String downloadUrl; // server-relative, "?q=full"
  final String source; // "frigate" | "crumb"
  final bool viewed;
  final List<double>? motionBbox; // normalized [x, y, w, h], 0..1

  factory ClipDescriptor.fromJson(Map<String, dynamic> j) => ClipDescriptor(
    id: j['id'] as String,
    cameraId: j['camera_id'] as String,
    cameraName: (j['camera_name'] as String?) ?? '',
    kind: (j['kind'] as String?) ?? 'detection',
    label: (j['label'] as String?) ?? '',
    iconKey: (j['icon_key'] as String?) ?? '',
    score: (j['score'] as num?)?.toDouble(),
    startTs: DateTime.parse(j['start_ts'] as String),
    endTs: DateTime.parse(j['end_ts'] as String),
    durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
    thumbnailUrl: (j['thumbnail_url'] as String?) ?? '',
    clipUrl: (j['clip_url'] as String?) ?? '',
    downloadUrl: (j['download_url'] as String?) ?? '',
    source: (j['source'] as String?) ?? 'crumb',
    viewed: (j['viewed'] as bool?) ?? false,
    motionBbox: (j['motion_bbox'] as List<dynamic>?)
        ?.map((e) => (e as num).toDouble())
        .toList(growable: false),
  );
}

/// `GET /clips` response.
class ClipsPage {
  ClipsPage({
    required this.clips,
    required this.total,
    required this.motionHighlightSeconds,
  });

  final List<ClipDescriptor> clips;
  final int total;
  final int motionHighlightSeconds;

  factory ClipsPage.fromJson(Map<String, dynamic> j) => ClipsPage(
    clips: (j['clips'] as List<dynamic>? ?? const [])
        .map((e) => ClipDescriptor.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    total: (j['total'] as num?)?.toInt() ?? 0,
    motionHighlightSeconds: (j['motion_highlight_seconds'] as num?)?.toInt() ?? 0,
  );
}

/// A cached scoped media token for one camera under one session.
class _CachedMediaToken {
  _CachedMediaToken(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt;
}

/// Refresh a bit before the server-side ~15 min expiry (matches the old
/// client's 10s margin, scaled up slightly for the coarser Flutter timers).
const _mediaTokenRefreshMargin = Duration(seconds: 15);

/// Process-wide scoped-media-token cache, keyed by `"<session-token>|<camera>"`
/// so a session change (logout/re-login) never reuses a stale principal's
/// token. Concurrent callers for the same camera share one in-flight mint.
final Map<String, _CachedMediaToken> _mediaTokenCache = {};
final Map<String, Future<String?>> _mediaTokenInflight = {};

/// `CrumbApi`'s own [http.Client] is private to crumb_api.dart, so this
/// extension (a separate file, per the port's file-boundary rule) uses its
/// own. Same plain JSON/Bearer story as the rest of the API.
final http.Client _client = TimeoutClient();

extension ClipsApi on CrumbApi {
  /// GET /media-token?camera=<id> → mint (or reuse a cached) scoped,
  /// short-lived, single-camera media token. Returns null on failure — callers
  /// must NOT fall back to the bearer JWT in a media URL.
  Future<String?> mediaToken(Session s, String cameraId) async {
    final key = '${s.token}|$cameraId';
    final cached = _mediaTokenCache[key];
    if (cached != null &&
        cached.expiresAt.difference(DateTime.now()) > _mediaTokenRefreshMargin) {
      return cached.token;
    }
    final inflight = _mediaTokenInflight[key];
    if (inflight != null) return inflight;

    final future = () async {
      try {
        final resp = await _client.get(
          Uri.parse(
            '${s.base}/media-token?camera=${Uri.encodeQueryComponent(cameraId)}',
          ),
          headers: {'authorization': 'Bearer ${s.token}'},
        );
        if (resp.statusCode != 200) return null;
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final tok = j['token'] as String?;
        if (tok == null) return null;
        final exp =
            DateTime.tryParse((j['expires_at'] as String?) ?? '') ??
            DateTime.now().add(const Duration(minutes: 1));
        _mediaTokenCache[key] = _CachedMediaToken(tok, exp);
        return tok;
      } catch (_) {
        return null; // transient — caller's retry will re-request
      } finally {
        _mediaTokenInflight.remove(key);
      }
    }();
    _mediaTokenInflight[key] = future;
    return future;
  }

  /// Resolve `relUrl` (server-relative, e.g. "/clip/<id>/thumbnail.jpg" or
  /// "/clip/<id>/clip.mp4?q=full") to a full URL carrying a scoped media token
  /// for `cameraId`. Returns null if no token could be minted.
  Future<String?> mediaUrlForCamera(
    Session s,
    String cameraId,
    String relUrl,
  ) async {
    final tok = await mediaToken(s, cameraId);
    if (tok == null) return null;
    final sep = relUrl.contains('?') ? '&' : '?';
    return '${s.base}$relUrl${sep}token=${Uri.encodeQueryComponent(tok)}';
  }

  /// GET /clips?camera_ids=<csv>&start=<iso>&end=<iso>&type=<t>&limit=N
  Future<ClipsPage> listClips(
    Session s, {
    required List<String> cameraIds,
    required DateTime start,
    required DateTime end,
    String type = 'all',
    int limit = 200,
  }) async {
    final uri = Uri.parse('${s.base}/clips').replace(
      queryParameters: {
        'camera_ids': cameraIds.join(','),
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'type': type,
        'limit': '$limit',
      },
    );
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load clips (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return ClipsPage.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// POST /clips/viewed {id} — mark a clip watched for the current user.
  /// Best-effort: failures are swallowed by callers the same way the old
  /// client fire-and-forgets this (dimming the card client-side regardless).
  Future<void> markClipViewed(Session s, String id) async {
    await _client.post(
      Uri.parse('${s.base}/clips/viewed'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({'id': id}),
    );
  }

  /// POST /bookmarks {camera_id, ts, description?} — used by the clip
  /// player's bookmark button to save the clip's start moment.
  Future<void> createBookmark(
    Session s, {
    required String cameraId,
    required DateTime ts,
    String? description,
  }) async {
    final resp = await _client.post(
      Uri.parse('${s.base}/bookmarks'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'camera_id': cameraId,
        'ts': ts.toUtc().toIso8601String(),
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
      }),
    );
    if (resp.statusCode != 201) {
      throw CrumbApiException(
        'Failed to save bookmark (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }
}
