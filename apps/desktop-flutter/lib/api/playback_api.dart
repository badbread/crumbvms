// Playback API — segment resolve + timeline spans + scoped media tokens.
//
// Route facts (see services/api/src/timeline.rs, services/api/src/playback.rs,
// services/api/src/auth.rs — all mounted at ROOT, no /api prefix):
//
//   GET /timeline?camera_ids=<csv>&start=<iso>&end=<iso>&limit=&offset=
//       -> { spans: [RecordedSpan], total, has_more }
//   GET /play/{camera_id}?ts=<iso>&stream=main|sub
//       -> ResolvedSegment { camera_id, segment_id, url, start, end,
//                            duration_ms, has_motion }
//       404 (no segment covers ts) is a normal "no footage" outcome, not an
//       error — callers get `null`.
//   GET /play/aligned?camera_ids=<csv>&ts=<iso>&stream=main|sub -> [ResolvedSegment]
//   GET /media-token?camera=<id> (Bearer JWT) -> { token, camera_id, expires_at }
//       A SHORT-LIVED (~15 min) scoped token. Media endpoints (the /segments/{id}
//       URL a ResolvedSegment points at) are authenticated via `?token=`, NOT the
//       bearer JWT — putting the long-lived JWT in a media URL would leak it into
//       proxy/access logs and the mpv/media_kit "open URL" call. Mirrors app.js's
//       mediaTokenCache (see apps/desktop/src/app.js ~line 1958): cached per
//       (server, camera), refreshed a bit before expiry, in-flight requests
//       deduped so concurrent segment resolves for the same camera don't mint N
//       tokens.
//
// This file only ADDS an extension on the existing `CrumbApi` — it does not
// touch crumb_api.dart. It uses `package:http` directly (module-level calls)
// since `CrumbApi._http` is private to that file.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'models.dart';

/// A merged recorded span for one camera (`GET /timeline` -> `spans[]`).
/// Contiguous segments (gap < ~1s) are already merged server-side.
class RecordedSpan {
  RecordedSpan({
    required this.cameraId,
    required this.start,
    required this.end,
    required this.hasMotion,
    required this.stage,
  });

  final String cameraId;
  final DateTime start; // UTC
  final DateTime end; // UTC
  final bool hasMotion;
  final String stage; // "live" | "archive"

  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  factory RecordedSpan.fromJson(Map<String, dynamic> j) => RecordedSpan(
    cameraId: j['camera_id'] as String,
    start: DateTime.parse(j['start'] as String).toUtc(),
    end: DateTime.parse(j['end'] as String).toUtc(),
    hasMotion: (j['has_motion'] as bool?) ?? false,
    stage: (j['stage'] as String?) ?? 'live',
  );
}

/// A resolved recording segment (`GET /play/{camera_id}` / `/play/aligned`).
/// `url` is API-relative (e.g. `/segments/{id}`); use
/// [PlaybackApi.mediaUrlForSegment] to turn it into a playable, token-bearing
/// absolute URL.
class ResolvedSegment {
  ResolvedSegment({
    required this.cameraId,
    required this.segmentId,
    required this.url,
    required this.start,
    required this.end,
    required this.durationMs,
    required this.hasMotion,
  });

  final String cameraId;
  final String segmentId;
  final String url;
  final DateTime start;
  final DateTime end;
  final int durationMs;
  final bool hasMotion;

  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  /// True if `t` falls within `[start, end)` — mirrors the server's segment
  /// resolve semantics (start inclusive, end exclusive).
  bool covers(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  factory ResolvedSegment.fromJson(Map<String, dynamic> j) => ResolvedSegment(
    cameraId: j['camera_id'] as String,
    segmentId: j['segment_id'] as String,
    url: j['url'] as String,
    start: DateTime.parse(j['start'] as String).toUtc(),
    end: DateTime.parse(j['end'] as String).toUtc(),
    durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
    hasMotion: (j['has_motion'] as bool?) ?? false,
  );
}

class _CachedMediaToken {
  _CachedMediaToken(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt; // UTC
}

extension PlaybackApi on CrumbApi {
  static final Map<String, _CachedMediaToken> _tokenCache = {};
  static final Map<String, Future<String?>> _tokenInflight = {};

  Map<String, String> _authHeaders(Session s) => {
    'authorization': 'Bearer ${s.token}',
  };

  /// GET /timeline — merged recorded spans for `cameraIds` over
  /// `[start, end)`. Returns `[]` on error rather than throwing, matching
  /// app.js's `pbFetchTimeline` (the timeline is best-effort, redrawn on the
  /// next reload/pan/zoom rather than surfacing a hard error to the operator).
  ///
  /// `limit`/`offset` page through the server's merged-span list (server
  /// default 2 000, hard cap 10 000 — see timeline.rs). A page shorter than
  /// `limit` means there are no more spans.
  Future<List<RecordedSpan>> fetchTimeline(
    Session s,
    List<String> cameraIds,
    DateTime start,
    DateTime end, {
    int? limit,
    int? offset,
  }) async {
    if (cameraIds.isEmpty) return const [];
    final uri = Uri.parse('${s.base}/timeline').replace(
      queryParameters: {
        'camera_ids': cameraIds.join(','),
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        if (limit != null) 'limit': '$limit',
        if (offset != null) 'offset': '$offset',
      },
    );
    try {
      final resp = await http.get(uri, headers: _authHeaders(s));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final spans = (j['spans'] as List<dynamic>? ?? const [])
          .map((e) => RecordedSpan.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
      return spans;
    } catch (_) {
      return const [];
    }
  }

  /// GET /play/{camera_id}?ts=<iso>&stream=<main|sub> — resolve the segment
  /// covering `ts`. Returns `null` on 404 ("no footage at this time" — a
  /// normal outcome, not an error) or on network failure.
  Future<ResolvedSegment?> resolveSegment(
    Session s,
    String cameraId,
    DateTime ts, {
    String stream = 'main',
  }) async {
    final uri = Uri.parse('${s.base}/play/$cameraId').replace(
      queryParameters: {'ts': ts.toUtc().toIso8601String(), 'stream': stream},
    );
    try {
      final resp = await http.get(uri, headers: _authHeaders(s));
      if (resp.statusCode != 200) return null;
      return ResolvedSegment.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// GET /play/aligned?camera_ids=<csv>&ts=<iso>&stream=<main|sub> — resolve
  /// one segment per camera at the same instant (multi-pane sync entry
  /// point). Cameras with no segment at `ts` are simply absent from the
  /// result (server behavior, not an error).
  Future<List<ResolvedSegment>> resolveAligned(
    Session s,
    List<String> cameraIds,
    DateTime ts, {
    String stream = 'main',
  }) async {
    if (cameraIds.isEmpty) return const [];
    final uri = Uri.parse('${s.base}/play/aligned').replace(
      queryParameters: {
        'camera_ids': cameraIds.join(','),
        'ts': ts.toUtc().toIso8601String(),
        'stream': stream,
      },
    );
    try {
      final resp = await http.get(uri, headers: _authHeaders(s));
      if (resp.statusCode != 200) return const [];
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list
          .map((e) => ResolvedSegment.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// GET /media-token?camera=<id> — mint (or reuse a cached) short-lived
  /// scoped media token for `cameraId`. Cached per (server, camera) and
  /// refreshed ~30s before expiry; concurrent callers for the same camera
  /// share one in-flight request (mirrors app.js `mediaTokenCache` /
  /// `mediaTokenInflight`). Returns `null` on failure — callers should treat
  /// that like "no segment" and retry later.
  Future<String?> mediaToken(Session s, String cameraId) async {
    final key = '${s.base}|$cameraId';
    final now = DateTime.now().toUtc();
    final cached = _tokenCache[key];
    if (cached != null &&
        cached.expiresAt.isAfter(now.add(const Duration(seconds: 30)))) {
      return cached.token;
    }
    final inflight = _tokenInflight[key];
    if (inflight != null) return inflight;

    final future = () async {
      try {
        final uri = Uri.parse(
          '${s.base}/media-token',
        ).replace(queryParameters: {'camera': cameraId});
        final resp = await http.get(uri, headers: _authHeaders(s));
        if (resp.statusCode != 200) return null;
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = j['token'] as String;
        final expiresAt =
            DateTime.tryParse((j['expires_at'] as String?) ?? '')?.toUtc() ??
            now.add(const Duration(minutes: 10));
        _tokenCache[key] = _CachedMediaToken(token, expiresAt);
        return token;
      } catch (_) {
        return null;
      } finally {
        _tokenInflight.remove(key);
      }
    }();
    _tokenInflight[key] = future;
    return future;
  }

  /// Build a playable absolute URL for a resolved segment, carrying the
  /// scoped `?token=` media claim (NOT the bearer JWT — see file header).
  /// Returns `null` if a token could not be minted.
  Future<String?> mediaUrlForSegment(Session s, ResolvedSegment seg) async {
    final token = await mediaToken(s, seg.cameraId);
    if (token == null) return null;
    return mediaUrlFor(s, seg.cameraId, seg.url, token);
  }

  /// Attach a caller-supplied media token to an API-relative media path
  /// (`seg.url`, a filmstrip/snapshot path, etc). Kept separate from
  /// [mediaUrlForSegment] so callers that already hold a token (e.g. a
  /// prefetch that reused the cache) don't re-mint one.
  String mediaUrlFor(
    Session s,
    String cameraId,
    String relativeUrl,
    String token,
  ) {
    final path = relativeUrl.startsWith('/')
        ? relativeUrl
        : '/$relativeUrl';
    final sep = path.contains('?') ? '&' : '?';
    return '${s.base}$path${sep}token=${Uri.encodeQueryComponent(token)}';
  }
}
