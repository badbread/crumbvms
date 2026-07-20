// Motion-timeline data layer: the per-camera activity histogram, prev/next
// motion navigation, and detection-event glyphs drawn on the playback
// timeline. Ported from the old Tauri client's pbFetchIntensity /
// pbFetchMotionEdge / pbFetchDetections (apps/desktop/src/app.js) against the
// real endpoints in services/api/src/timeline.rs and services/api/src/events.rs.
//
// Routes are mounted at ROOT (no /api prefix) and use the bearer JWT, same as
// every other JSON endpoint in [CrumbApi] — these are NOT media endpoints, so
// no ?token= media claim is involved.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// One `GET /timeline/intensity` response for a single camera + window: a
/// fixed-size array of 0..1 motion-magnitude values, one per time bucket.
/// Epoch-aligned by the caller (see [MotionTimelineApi.fetchIntensity]) so
/// panning the visible window without changing zoom never re-buckets the same
/// data differently.
class IntensityBuckets {
  IntensityBuckets({
    required this.cameraId,
    required this.startMs,
    required this.endMs,
    required this.bucketMs,
    required this.buckets,
  });

  final String cameraId;
  final int startMs;
  final int endMs;
  final int bucketMs;
  final List<double> buckets;

  bool get isEmpty => buckets.isEmpty;

  /// Bucket index containing [ms], or null if outside range.
  int? indexAt(int ms) {
    if (buckets.isEmpty) return null;
    final span = (endMs - startMs) == 0 ? 1 : (endMs - startMs);
    final n = buckets.length;
    final bMs = bucketMs > 0 ? bucketMs : (span / n).round();
    if (ms < startMs || ms >= endMs) return null;
    final i = ((ms - startMs) / bMs).floor();
    return i.clamp(0, n - 1);
  }
}

/// A single detection event row from `GET /events` (locked contract —
/// `DetectionEventDto` in services/api/src/events.rs). `iconKey == "motion"`
/// rows are filtered out by the timeline UI (already rendered as the
/// intensity ribbon); this model still carries the field so callers can
/// decide for themselves.
class DetectionEvent {
  DetectionEvent({
    required this.id,
    required this.cameraId,
    required this.ts,
    this.endTs,
    required this.label,
    required this.iconKey,
    this.subLabel,
    required this.score,
    required this.topScore,
    required this.zones,
    this.snapshotUrl,
    this.sourceId,
  });

  final String id;
  final String cameraId;
  final DateTime ts;
  final DateTime? endTs;
  final String label;
  final String iconKey;
  final String? subLabel;
  final double score;
  final double topScore;
  final List<String> zones;
  final String? snapshotUrl;
  final String? sourceId;

  factory DetectionEvent.fromJson(Map<String, dynamic> j) => DetectionEvent(
    id: j['id'] as String,
    cameraId: j['camera_id'] as String,
    ts: DateTime.parse(j['ts'] as String),
    endTs: j['end_ts'] != null ? DateTime.tryParse(j['end_ts'] as String) : null,
    label: (j['label'] as String?) ?? '',
    iconKey: (j['icon_key'] as String?) ?? '',
    subLabel: j['sub_label'] as String?,
    score: ((j['score'] as num?) ?? 0).toDouble(),
    topScore: ((j['top_score'] as num?) ?? 0).toDouble(),
    zones: ((j['zones'] as List<dynamic>?) ?? const [])
        .map((e) => e as String)
        .toList(growable: false),
    snapshotUrl: j['snapshot_url'] as String?,
    sourceId: j['source_id'] as String?,
  );
}

// [CrumbApi] doesn't expose its private http.Client to other files (Dart's
// library-privacy is file-scoped), so this extension keeps one module-level
// client for its own stateless GET calls — mirrors CrumbApi's own default
// `http.Client()` construction, just not shared with it.
final http.Client _client = TimeoutClient();

/// Server bases whose API 404'd `/timeline/intensity/batch` — i.e. servers
/// older than the batch endpoint (#270). Keyed by base (not a lone bool) so a
/// same-process switch to a different, newer server isn't wrongly demoted to
/// the per-camera fallback.
final Set<String> _batchUnsupportedBases = <String>{};

extension MotionTimelineApi on CrumbApi {
  /// GET /timeline/intensity?camera_id=<id>&start=<iso>&end=<iso>&buckets=<n>
  ///
  /// Per-camera motion-magnitude histogram over `[start, end)`. The server
  /// returns all-zero buckets (not 403) for a camera outside the caller's
  /// viewer scope, so this never throws for scoping reasons.
  Future<IntensityBuckets> fetchIntensity(
    Session s,
    String cameraId,
    DateTime start,
    DateTime end, {
    int buckets = 240,
  }) async {
    final uri = Uri.parse('${s.base}/timeline/intensity').replace(
      queryParameters: {
        'camera_id': cameraId,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'buckets': '$buckets',
      },
    );
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load motion intensity (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (j['buckets'] as List<dynamic>? ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
    final startMs = start.toUtc().millisecondsSinceEpoch;
    final endMs = end.toUtc().millisecondsSinceEpoch;
    final n = list.length == 0 ? 1 : list.length;
    final bucketMs = ((endMs - startMs) / n).round();
    return IntensityBuckets(
      cameraId: cameraId,
      startMs: startMs,
      endMs: endMs,
      bucketMs: bucketMs,
      buckets: list,
    );
  }

  /// GET /timeline/intensity/batch?camera_ids=<csv>&start=<iso>&end=<iso>&buckets=<n>
  ///
  /// The batched form of [fetchIntensity]: one request for the whole wall
  /// instead of one per camera (#256). Returns a map keyed by camera id; every
  /// requested camera is present (all-zero buckets for one with no footage or
  /// outside the caller's scope), so the caller can rely on a complete map.
  ///
  /// Version tolerance (#270): a server older than the batch endpoint 404s the
  /// route. Client/server skew is normal for a self-hosted VMS, so on a 404
  /// this falls back to the per-camera [fetchIntensity] fan-out every older
  /// server supports — same complete-map result, just N requests — and
  /// remembers batch-unsupported for that server so later refreshes skip the
  /// doomed batch attempt. (A server upgraded mid-session picks the batch path
  /// back up on next app start; skew in that direction is rare and harmless.)
  Future<Map<String, IntensityBuckets>> fetchIntensityBatch(
    Session s,
    List<String> cameraIds,
    DateTime start,
    DateTime end, {
    int buckets = 240,
  }) async {
    if (_batchUnsupportedBases.contains(s.base)) {
      return _fetchIntensityPerCamera(s, cameraIds, start, end, buckets);
    }
    try {
      return await _fetchIntensityBatchRaw(s, cameraIds, start, end, buckets);
    } on CrumbApiException catch (e) {
      if (e.statusCode != 404) rethrow;
      _batchUnsupportedBases.add(s.base);
      return _fetchIntensityPerCamera(s, cameraIds, start, end, buckets);
    }
  }

  /// The pre-batch per-camera fan-out (the #270 fallback path). Mirrors the
  /// batch guarantee: one entry per requested camera ([fetchIntensity] returns
  /// all-zero buckets rather than erroring for scope/no-footage cameras).
  Future<Map<String, IntensityBuckets>> _fetchIntensityPerCamera(
    Session s,
    List<String> cameraIds,
    DateTime start,
    DateTime end,
    int buckets,
  ) async {
    final results = await Future.wait(
      cameraIds.map(
        (id) => fetchIntensity(s, id, start, end, buckets: buckets),
      ),
    );
    return {for (final r in results) r.cameraId: r};
  }

  Future<Map<String, IntensityBuckets>> _fetchIntensityBatchRaw(
    Session s,
    List<String> cameraIds,
    DateTime start,
    DateTime end,
    int buckets,
  ) async {
    final uri = Uri.parse('${s.base}/timeline/intensity/batch').replace(
      queryParameters: {
        'camera_ids': cameraIds.join(','),
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'buckets': '$buckets',
      },
    );
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load motion intensity (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final cameras = (j['cameras'] as Map<String, dynamic>? ?? const {});
    final startMs = start.toUtc().millisecondsSinceEpoch;
    final endMs = end.toUtc().millisecondsSinceEpoch;
    final out = <String, IntensityBuckets>{};
    cameras.forEach((cameraId, v) {
      final list = (v as List<dynamic>? ?? const [])
          .map((e) => (e as num).toDouble())
          .toList(growable: false);
      final n = list.isEmpty ? 1 : list.length;
      final bucketMs = ((endMs - startMs) / n).round();
      out[cameraId] = IntensityBuckets(
        cameraId: cameraId,
        startMs: startMs,
        endMs: endMs,
        bucketMs: bucketMs,
        buckets: list,
      );
    });
    return out;
  }

  /// GET /timeline/motion?camera_id=<id>&from=<iso>&dir=next|prev
  ///
  /// The start of the next/previous motion EVENT relative to `from`, searched
  /// across ALL recorded history (not just the loaded window) — or null if
  /// there is none in that direction. `dir` defaults server-side to "next".
  Future<DateTime?> fetchMotionEdge(
    Session s,
    String cameraId,
    DateTime from, {
    required bool next,
  }) async {
    final uri = Uri.parse('${s.base}/timeline/motion').replace(
      queryParameters: {
        'camera_id': cameraId,
        'from': from.toUtc().toIso8601String(),
        'dir': next ? 'next' : 'prev',
      },
    );
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'GET /timeline/motion failed (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final start = j['start'] as String?;
    return start != null ? DateTime.tryParse(start) : null;
  }

  /// GET /events?camera_ids=<csv>&start=<iso>&end=<iso>[&labels=<csv>][&limit=][&offset=]
  ///
  /// Detection-event rows (object detections, e.g. Frigate) for the given
  /// cameras within `[start, end)`. Cameras outside viewer scope are silently
  /// dropped server-side, never 403. Returns `[]` if the detection feature
  /// isn't configured — never an error.
  Future<List<DetectionEvent>> fetchEvents(
    Session s,
    List<String> cameraIds,
    DateTime start,
    DateTime end, {
    List<String>? labels,
    int limit = 500,
    int offset = 0,
  }) async {
    if (cameraIds.isEmpty) return const [];
    final params = <String, String>{
      'camera_ids': cameraIds.join(','),
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'limit': '$limit',
      'offset': '$offset',
    };
    if (labels != null && labels.isNotEmpty) {
      params['labels'] = labels.join(',');
    }
    final uri = Uri.parse('${s.base}/events').replace(queryParameters: params);
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load detection events (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (j['events'] as List<dynamic>? ?? const [])
        .map((e) => DetectionEvent.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return list;
  }
}
