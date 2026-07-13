// Export tab API surface: batch clip export (list of {camera, start, end}
// items bundled into one job), progress polling, and file download.
//
// Route facts (see services/api/src/export.rs + services/api/src/filmstrip.rs,
// services/api/src/auth.rs — routes mounted at ROOT, no /api prefix):
//   POST   /export/batch                        -> 202 {job_id, status_url}
//   GET    /export/{job_id}                      -> ExportJob snapshot (poll)
//   DELETE /export/{job_id}                      -> cancel (204)
//   GET    /export/{job_id}/files/{camera_id}     -> one output file (bytes)
//   GET    /export/{job_id}/archive               -> the zip archive (bytes)
//   GET    /filmstrip/{camera_id}                 -> list of thumb frame URLs
//   GET    /filmstrip/{camera_id}/frame?ts=&width= -> one JPEG frame
//   GET    /media-token?camera=<id>                -> scoped short-lived token
//
// The export create/poll/cancel/download routes are authenticated with the
// bearer JWT (Authorization header) exactly like the rest of CrumbApi — the
// old Tauri client kept those on the full-JWT pattern deliberately (see
// apps/desktop/src/app.js:1954-1956, and `LegacyQueryTokenUser` in
// services/api/src/auth_mw.rs) because a multi-camera archive has no single
// scoped camera and there's no browser <a download> element here forcing a
// URL-embedded token. The filmstrip PREVIEW frames, however, are per-camera
// media and MUST use the short-lived `?token=` media claim (golden rule 1,
// never the bearer JWT) — this file mints and caches those via GET
// /media-token, mirroring apps/desktop/src/app.js's getMediaToken/-cache.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'models.dart';

// ─── models ────────────────────────────────────────────────────────────────

/// Status of an export job (`services/api/src/dto.rs::ExportStatus`,
/// `#[serde(rename_all = "lowercase")]`).
enum ExportJobStatus {
  queued,
  running,
  done,
  failed,
  cancelled;

  static ExportJobStatus fromJson(String s) => switch (s) {
    'queued' => ExportJobStatus.queued,
    'running' => ExportJobStatus.running,
    'done' => ExportJobStatus.done,
    'failed' => ExportJobStatus.failed,
    'cancelled' => ExportJobStatus.cancelled,
    _ => ExportJobStatus.failed,
  };
}

/// One clip to include in a batch export: a single camera over its own
/// `[start, end)` range (`BatchExportItem` in dto.rs).
class BatchExportItem {
  BatchExportItem({
    required this.cameraId,
    required this.start,
    required this.end,
  });

  final String cameraId; // UUID
  final DateTime start;
  final DateTime end;

  Map<String, dynamic> toJson() => {
    'camera_id': cameraId,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
  };
}

/// A single produced output file for one camera, or the whole-job ZIP archive
/// (`camera_id` is the nil UUID for the archive entry). `ExportOutputFile`.
class ExportOutputFile {
  ExportOutputFile({
    required this.cameraId,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.filename,
  });

  final String cameraId;
  final String downloadUrl; // server-relative, e.g. /export/{job}/files/{cam}
  final int sizeBytes;
  final String filename;

  bool get isArchive =>
      cameraId == '00000000-0000-0000-0000-000000000000' ||
      filename.toLowerCase().endsWith('.zip');

  factory ExportOutputFile.fromJson(Map<String, dynamic> j) =>
      ExportOutputFile(
        cameraId: j['camera_id'] as String,
        downloadUrl: j['download_url'] as String,
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        filename: (j['filename'] as String?) ?? '',
      );
}

/// `GET /export/{job_id}` response snapshot (`ExportJob` in dto.rs).
class ExportJob {
  ExportJob({
    required this.id,
    required this.status,
    required this.cameraIds,
    required this.start,
    required this.end,
    required this.burnTimestamp,
    required this.createdAt,
    required this.outputFiles,
    required this.error,
    required this.progressPct,
  });

  final String id;
  final ExportJobStatus status;
  final List<String> cameraIds;
  final DateTime start;
  final DateTime end;
  final bool burnTimestamp;
  final DateTime createdAt;
  final List<ExportOutputFile> outputFiles;
  final String? error;
  final int progressPct; // 0-100

  factory ExportJob.fromJson(Map<String, dynamic> j) => ExportJob(
    id: j['id'] as String,
    status: ExportJobStatus.fromJson(j['status'] as String),
    cameraIds: (j['camera_ids'] as List<dynamic>? ?? const [])
        .cast<String>(),
    start: DateTime.parse(j['start'] as String),
    end: DateTime.parse(j['end'] as String),
    burnTimestamp: (j['burn_timestamp'] as bool?) ?? true,
    createdAt: DateTime.parse(j['created_at'] as String),
    outputFiles: (j['output_files'] as List<dynamic>? ?? const [])
        .map((e) => ExportOutputFile.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    error: j['error'] as String?,
    progressPct: (j['progress_pct'] as num?)?.toInt() ?? 0,
  );
}

/// `POST /export/batch` response (`CreateExportResponse` in dto.rs).
class CreateExportResult {
  CreateExportResult({required this.jobId, required this.statusUrl});
  final String jobId;
  final String statusUrl;
}

/// One thumbnail frame entry from `GET /filmstrip/{camera_id}`.
class FilmstripFrame {
  FilmstripFrame({required this.ts, required this.url});
  final DateTime ts;
  final String url; // server-relative, e.g. /filmstrip/{cam}/frame?ts=..&width=..

  factory FilmstripFrame.fromJson(Map<String, dynamic> j) => FilmstripFrame(
    ts: DateTime.parse(j['ts'] as String),
    url: j['url'] as String,
  );
}

// ─── scoped media-token cache ─────────────────────────────────────────────
// Mirrors apps/desktop/src/app.js's mediaTokenCache: mint once per camera via
// GET /media-token (Bearer JWT), reuse until close to expiry, then refresh.
// Keyed by "base|token|cameraId" so switching sessions/logins never reuses a
// stale principal's token.

class _CachedMediaToken {
  _CachedMediaToken(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt;
}

final Map<String, _CachedMediaToken> _mediaTokenCache = {};
const _mediaTokenRefreshMargin = Duration(seconds: 10);

// ─── extension ─────────────────────────────────────────────────────────────
// Uses the top-level http.get/post/delete functions (each a one-shot
// connection), matching the existing bookmarks_api.dart convention rather
// than threading CrumbApi's own private http.Client through here.

extension ExportApi on CrumbApi {
  Map<String, String> _authHeaders(Session s) => {
    'authorization': 'Bearer ${s.token}',
  };

  // ── GET /media-token?camera=<id> ──────────────────────────────────────────

  /// Mint (or reuse a cached) short-lived, single-camera-scoped media token.
  /// Used ONLY as `?token=` on filmstrip preview frame URLs — never the bearer
  /// JWT (golden rule 1).
  Future<String?> mintMediaToken(Session s, String cameraId) async {
    final key = '${s.base}|${s.token}|$cameraId';
    final cached = _mediaTokenCache[key];
    if (cached != null &&
        cached.expiresAt.difference(DateTime.now()) >
            _mediaTokenRefreshMargin) {
      return cached.token;
    }
    final resp = await http.get(
      Uri.parse(
        '${s.base}/media-token?camera=${Uri.encodeQueryComponent(cameraId)}',
      ),
      headers: _authHeaders(s),
    );
    if (resp.statusCode != 200) return null;
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = j['token'] as String?;
    if (token == null) return null;
    final expiresAt =
        DateTime.tryParse((j['expires_at'] as String?) ?? '') ??
        DateTime.now().add(const Duration(minutes: 1));
    _mediaTokenCache[key] = _CachedMediaToken(token, expiresAt);
    return token;
  }

  // ── GET /filmstrip/{camera_id} + /frame ───────────────────────────────────

  /// List thumbnail frame timestamps + URLs for `cameraId` in `[start, end)`.
  Future<List<FilmstripFrame>> listFilmstrip(
    Session s,
    String cameraId,
    DateTime start,
    DateTime end, {
    int width = 160,
  }) async {
    final uri = Uri.parse('${s.base}/filmstrip/$cameraId').replace(
      queryParameters: {
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'width': '$width',
      },
    );
    final resp = await http.get(uri, headers: _authHeaders(s));
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load filmstrip (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return (j['frames'] as List<dynamic>? ?? const [])
        .map((e) => FilmstripFrame.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Fetch ONE preview JPEG frame at `ts` for `cameraId` (the add/edit-clip
  /// scrubber and the list-row thumbnail both use this). Mints/reuses a scoped
  /// media token and puts it in `?token=` — never the bearer JWT. Returns null
  /// on any failure (no footage at that instant, 404, network) so callers can
  /// show a placeholder rather than crash.
  Future<Uint8List?> fetchFilmstripFrame(
    Session s,
    String cameraId,
    DateTime ts, {
    int width = 480,
  }) async {
    final tok = await mintMediaToken(s, cameraId);
    if (tok == null) return null;
    final uri = Uri.parse('${s.base}/filmstrip/$cameraId/frame').replace(
      queryParameters: {
        'ts': ts.toUtc().toIso8601String(),
        'width': '$width',
        'token': tok,
      },
    );
    try {
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  // ── POST /export/batch ────────────────────────────────────────────────────

  /// Submit a batch export job: a list of `{camera_id, start, end}` clips
  /// (max 50 server-side — export.rs::MAX_BATCH_ITEMS) bundled into ONE
  /// archive when `password` is set OR more than one output file is produced.
  /// `videoCodec` is `"copy" | "h264" | "h265"`, `container` is `"mp4" |
  /// "mkv"`. `password` empty/null -> no encryption/zip-forcing.
  Future<CreateExportResult> submitBatchExport(
    Session s, {
    required List<BatchExportItem> items,
    bool burnTimestamp = true,
    bool includeAudio = true,
    String videoCodec = 'copy',
    String container = 'mp4',
    String? password,
  }) async {
    final resp = await http.post(
      Uri.parse('${s.base}/export/batch'),
      headers: {..._authHeaders(s), 'content-type': 'application/json'},
      body: jsonEncode({
        'items': items.map((it) => it.toJson()).toList(),
        'burn_timestamp': burnTimestamp,
        'include_audio': includeAudio,
        'video_codec': videoCodec,
        'container': container,
        'password': (password == null || password.isEmpty) ? null : password,
      }),
    );
    if (resp.statusCode != 202) {
      String detail;
      try {
        detail = (jsonDecode(resp.body) as Map<String, dynamic>)['message']
                as String? ??
            resp.body;
      } catch (_) {
        detail = resp.body;
      }
      throw CrumbApiException(
        'Export request failed (HTTP ${resp.statusCode}): $detail',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return CreateExportResult(
      jobId: j['job_id'] as String,
      statusUrl: j['status_url'] as String,
    );
  }

  // ── GET /export/{job_id} ──────────────────────────────────────────────────

  /// Poll job status/progress.
  Future<ExportJob> getExportStatus(Session s, String jobId) async {
    final resp = await http.get(
      Uri.parse('${s.base}/export/$jobId'),
      headers: _authHeaders(s),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to poll export job (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return ExportJob.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  // ── DELETE /export/{job_id} ───────────────────────────────────────────────

  /// Cancel a queued/running job. Idempotent server-side.
  Future<void> cancelExport(Session s, String jobId) async {
    final resp = await http.delete(
      Uri.parse('${s.base}/export/$jobId'),
      headers: _authHeaders(s),
    );
    if (resp.statusCode != 204) {
      throw CrumbApiException(
        'Failed to cancel export job (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }

  // ── GET /export/{job_id}/files/{camera_id} + /archive ─────────────────────

  /// Download one completed output file's bytes (per-camera file OR, when
  /// `file.isArchive`, the combined zip via `/archive`). Authenticated with
  /// the bearer JWT in the Authorization header — no token in the URL, unlike
  /// the old browser client which had to (a `<a download>` element cannot set
  /// headers). `file.downloadUrl` is already the right server-relative path
  /// for either case.
  Future<Uint8List> downloadExportFile(
    Session s,
    ExportOutputFile file,
  ) async {
    final resp = await http.get(
      Uri.parse('${s.base}${file.downloadUrl}'),
      headers: _authHeaders(s),
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Download failed for ${file.filename} (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return resp.bodyBytes;
  }
}
