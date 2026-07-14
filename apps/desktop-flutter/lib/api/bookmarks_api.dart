// Bookmarks: saved playback moments (camera + time + optional note), with
// optional retention protection so surrounding footage survives eviction.
//
// Route facts (see services/api/src/bookmarks.rs, mounted at ROOT, no /api
// prefix): GET/POST /bookmarks, PATCH & DELETE /bookmarks/:id. All Bearer
// JWT auth like the rest of CrumbApi. Bookmark rows are scope-filtered
// server-side (own vs all) per the caller's role — this client just renders
// whatever the server returns.
//
// The platform-wide toggle lives at GET /status → `bookmarks_enabled`
// (services/api/src/status.rs); [bookmarksEnabled] reads just that field so
// callers can gate the "Bookmarks" nav entry without pulling in the rest of
// the (large, admin-oriented) status payload.

import 'dart:convert';

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// A saved playback moment (`GET/POST /bookmarks` → the `Bookmark` DTO in
/// services/common/src/types.rs).
class Bookmark {
  Bookmark({
    required this.id,
    required this.cameraId,
    this.cameraName,
    required this.ts,
    this.description,
    this.protectUntil,
    this.protectStartTs,
    this.protectEndTs,
    required this.createdAt,
  });

  final String id; // UUID
  final String cameraId; // UUID
  /// Joined camera name; null on create or when the server didn't join it.
  final String? cameraName;
  final DateTime ts;
  final String? description;
  /// While in the future, the footage window below is protected from
  /// auto-archive/delete. Null = not protected.
  final DateTime? protectUntil;
  final DateTime? protectStartTs;
  final DateTime? protectEndTs;
  final DateTime createdAt;

  /// True while [protectUntil] is set and still in the future.
  bool get isProtected =>
      protectUntil != null && protectUntil!.isAfter(DateTime.now());

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
    id: j['id'] as String,
    cameraId: j['camera_id'] as String,
    cameraName: j['camera_name'] as String?,
    ts: DateTime.parse(j['ts'] as String),
    description: j['description'] as String?,
    protectUntil: j['protect_until'] == null
        ? null
        : DateTime.tryParse(j['protect_until'] as String),
    protectStartTs: j['protect_start_ts'] == null
        ? null
        : DateTime.tryParse(j['protect_start_ts'] as String),
    protectEndTs: j['protect_end_ts'] == null
        ? null
        : DateTime.tryParse(j['protect_end_ts'] as String),
    createdAt: DateTime.parse(j['created_at'] as String),
  );
}

/// Options for [BookmarksApi.createBookmark]'s optional retention protection.
/// Mirrors the server's clamping (services/api/src/bookmarks.rs): days is
/// clamped 1..30, pre/post seconds 0..3600. Omit entirely for an unprotected
/// bookmark.
class BookmarkProtection {
  const BookmarkProtection({
    required this.days,
    this.preSeconds = 60,
    this.postSeconds = 300,
  });

  final int days;
  final int preSeconds;
  final int postSeconds;

  Map<String, dynamic> toJson() => {
    'protect_days': days.clamp(1, 30),
    'protect_pre_seconds': preSeconds.clamp(0, 3600),
    'protect_post_seconds': postSeconds.clamp(0, 3600),
  };
}

extension BookmarksApi on CrumbApi {
  Map<String, String> _authHeaders(Session s) => {
    'authorization': 'Bearer ${s.token}',
  };

  Map<String, String> _jsonHeaders(Session s) => {
    'authorization': 'Bearer ${s.token}',
    'content-type': 'application/json',
  };

  /// GET /status → just the `bookmarks_enabled` platform-wide toggle. Used to
  /// gate the Bookmarks nav entry; ignores every other field in the (large,
  /// admin-oriented) status payload.
  Future<bool> bookmarksEnabled(Session s) async {
    final resp = await sharedHttpClient.get(
      Uri.parse('${s.base}/status'),
      headers: _authHeaders(s),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load status (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return (j['bookmarks_enabled'] as bool?) ?? true;
  }

  /// GET /bookmarks — all bookmarks visible to the caller (server applies
  /// role scope: own vs all), newest first.
  ///
  /// GET /bookmarks?camera_id=... — one camera's bookmarks. Pass [cameraId]
  /// for that scoped call (e.g. timeline markers in a playback view).
  Future<List<Bookmark>> listBookmarks(Session s, {String? cameraId}) async {
    final uri = Uri.parse('${s.base}/bookmarks').replace(
      queryParameters: cameraId == null ? null : {'camera_id': cameraId},
    );
    final resp = await sharedHttpClient.get(uri, headers: _authHeaders(s));
    if (resp.statusCode == 403) {
      throw CrumbApiException(
        'Your role does not permit bookmark access.',
        statusCode: 403,
      );
    }
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load bookmarks (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// POST /bookmarks — pin a moment, optionally protecting the surrounding
  /// footage window from eviction for [protection]'s day count.
  Future<Bookmark> createBookmark(
    Session s, {
    required String cameraId,
    required DateTime ts,
    String? description,
    BookmarkProtection? protection,
  }) async {
    final body = <String, dynamic>{
      'camera_id': cameraId,
      'ts': ts.toUtc().toIso8601String(),
      'description': (description == null || description.trim().isEmpty)
          ? null
          : description.trim(),
      ...?protection?.toJson(),
    };
    final resp = await sharedHttpClient.post(
      Uri.parse('${s.base}/bookmarks'),
      headers: _jsonHeaders(s),
      body: jsonEncode(body),
    );
    if (resp.statusCode != 201) {
      throw CrumbApiException(
        'Add bookmark failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return Bookmark.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// PATCH /bookmarks/:id — edit the note (empty/null clears it).
  Future<Bookmark> updateBookmarkDescription(
    Session s,
    String id,
    String? description,
  ) async {
    final trimmed = description?.trim();
    final resp = await sharedHttpClient.patch(
      Uri.parse('${s.base}/bookmarks/${Uri.encodeComponent(id)}'),
      headers: _jsonHeaders(s),
      body: jsonEncode({
        'description': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      }),
    );
    if (resp.statusCode == 404) {
      throw CrumbApiException('Bookmark not found.', statusCode: 404);
    }
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Update bookmark failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return Bookmark.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// DELETE /bookmarks/:id. A 404 (already gone) is treated as success, same
  /// as the old Tauri client's row-removal-on-404 behavior.
  Future<void> deleteBookmark(Session s, String id) async {
    final resp = await sharedHttpClient.delete(
      Uri.parse('${s.base}/bookmarks/${Uri.encodeComponent(id)}'),
      headers: _authHeaders(s),
    );
    if (resp.statusCode != 204 && resp.statusCode != 404) {
      throw CrumbApiException(
        'Delete bookmark failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }
}
