// State + data-fetch logic for the motion timeline. Ported from the
// pbState.intensity* / pbFetchIntensity / pbFetchDetections / pbPrevMotion /
// pbNextMotion family in apps/desktop/src/app.js. This controller owns no UI
// — [MotionTimelineView] paints from it.
//
// Usage: construct with the API + session + a way to resolve the current wall
// camera set, call `configure()` whenever the visible window or selected
// camera changes, and call `refresh()` to (re)fetch. `jumpToMotion` drives
// prev/next navigation and calls back via `onSeek`.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../api/crumb_api.dart';
import '../../api/models.dart';
import '../../api/motion_timeline_api.dart';

/// "Nice" motion-histogram bucket widths (ms), ported from
/// PB_INTENSITY_BUCKET_MS. A width is picked from this fixed ladder (instead
/// of windowDur / N) and the fetch range is snapped to absolute epoch
/// multiples of it, so panning the window only TRANSLATES the bars — it never
/// re-buckets them into different heights. Only a zoom change picks a new
/// width.
const List<int> kIntensityBucketLadderMs = [
  1000, 2000, 5000, 10000, 15000, 30000,
  60000, 120000, 300000, 600000, 900000, 1800000, 3600000,
];

/// Motion-run leading-edge coalescing gap, ported from pbSelectedMotionStarts.
/// Bridges brief sub-threshold dips so one continuous burst isn't split into
/// several "events" — a new run only starts after an off-gap longer than this.
const int kMotionCoalesceGapMs = 8000;

/// 0.4% largest-blob fraction — ANY motion, the recorder's own detection
/// floor. Ported from TL_MOTION_ABS in app.js; anything at/above this counts
/// as "on" for run-start and hover-hint purposes.
const double kMotionAbsFloor = 0.004;

/// Choose a stable bucket WIDTH (ms) for the current zoom: ~1 bucket per 5 CSS
/// px of timeline width, rounded UP to the nearest ladder value. Ported from
/// pbIntensityBucketMs.
int intensityBucketMs(int windowDurMs, double timelineWidthPx) {
  final target = math
      .max(60, math.min(240, ((timelineWidthPx <= 0 ? 480 : timelineWidthPx) / 5).round()))
      .toInt();
  final raw = math.max(1000, windowDurMs / target);
  for (final b in kIntensityBucketLadderMs) {
    if (b >= raw) return b;
  }
  return kIntensityBucketLadderMs.last;
}

class MotionTimelineController extends ChangeNotifier {
  MotionTimelineController({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  /// Visible window, ms epoch. Callers (the playback host) own scrubbing and
  /// call [configure] when it changes.
  int windowStartMs = DateTime.now()
      .subtract(const Duration(hours: 1))
      .millisecondsSinceEpoch;
  int windowEndMs = DateTime.now().millisecondsSinceEpoch;

  /// Every camera currently in the playback grid — the selected one is drawn
  /// prominent, the rest faded, so cross-camera activity stays visible.
  List<String> wallCameraIds = const [];

  /// The camera whose track is drawn prominent and whose prev/next-motion
  /// buttons operate.
  String? selectedCameraId;

  double timelineWidthPx = 480;

  final Map<String, IntensityBuckets> intensityByCam = {};
  List<DetectionEvent> detections = const [];

  bool loading = false;
  String? error;

  int _seq = 0;

  /// Update window/selection/camera-set; caller still must call [refresh].
  void configure({
    int? windowStartMs,
    int? windowEndMs,
    List<String>? wallCameraIds,
    String? selectedCameraId,
    double? timelineWidthPx,
  }) {
    if (windowStartMs != null) this.windowStartMs = windowStartMs;
    if (windowEndMs != null) this.windowEndMs = windowEndMs;
    if (wallCameraIds != null) this.wallCameraIds = wallCameraIds;
    if (selectedCameraId != null) this.selectedCameraId = selectedCameraId;
    if (timelineWidthPx != null && timelineWidthPx > 0) {
      this.timelineWidthPx = timelineWidthPx;
    }
  }

  IntensityBuckets? get selectedIntensity =>
      selectedCameraId != null ? intensityByCam[selectedCameraId] : null;

  /// Fetch the intensity histogram for every camera in the wall grid (fanned
  /// out, latest-wins) plus object-detection events for the loaded window.
  /// Ported from pbReloadTimeline -> pbFetchIntensity / pbFetchDetections.
  Future<void> refresh() async {
    final winDur = (windowEndMs - windowStartMs) > 0
        ? (windowEndMs - windowStartMs)
        : 3600000;
    final bucketMs = intensityBucketMs(winDur, timelineWidthPx);

    // Fetch ±1 window of margin, epoch-snapped to bucketMs boundaries — keeps
    // bars stable under panning within the loaded range.
    final center = (windowStartMs + windowEndMs) / 2;
    final fetchStart = ((center - winDur) / bucketMs).floor() * bucketMs;
    final fetchEnd = ((center + winDur) / bucketMs).ceil() * bucketMs;
    final bucketCount = math.max(1, ((fetchEnd - fetchStart) / bucketMs).round());

    final camIds = {...wallCameraIds}.where((id) => id.isNotEmpty).toList();
    if (camIds.isEmpty) {
      intensityByCam.clear();
      detections = const [];
      notifyListeners();
      return;
    }

    // Drop cached intensity for cameras no longer in the grid.
    intensityByCam.removeWhere((id, _) => !camIds.contains(id));

    final mySeq = ++_seq;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final results = await Future.wait(
        camIds.map((id) async {
          try {
            final r = await api.fetchIntensity(
              session,
              id,
              DateTime.fromMillisecondsSinceEpoch(fetchStart, isUtc: true),
              DateTime.fromMillisecondsSinceEpoch(fetchEnd, isUtc: true),
              buckets: bucketCount,
            );
            return MapEntry(id, r);
          } catch (_) {
            return null; // per-camera failure shouldn't sink the whole fetch
          }
        }),
      );
      if (mySeq != _seq) return; // superseded by a newer refresh

      for (final e in results) {
        if (e != null) intensityByCam[e.key] = e.value;
      }

      final events = await api.fetchEvents(
        session,
        camIds,
        DateTime.fromMillisecondsSinceEpoch(fetchStart, isUtc: true),
        DateTime.fromMillisecondsSinceEpoch(fetchEnd, isUtc: true),
        limit: 500,
      );
      if (mySeq != _seq) return;
      // Motion events are already rendered as the intensity ribbon; showing
      // each as a glyph too would flood the row. Object detections only.
      detections = events.where((e) => e.iconKey.isNotEmpty && e.iconKey != 'motion').toList();

      loading = false;
      notifyListeners();
    } catch (e) {
      if (mySeq != _seq) return;
      loading = false;
      error = '$e';
      notifyListeners();
    }
  }

  /// Motion-run START times (ms) for [cameraId] within the currently loaded
  /// buckets — the leading edge of each contiguous run at/above
  /// [kMotionAbsFloor]. Ascending. Ported from pbSelectedMotionStarts.
  List<int> motionStartsFor(String? cameraId) {
    final intensity = cameraId != null ? intensityByCam[cameraId] : null;
    if (intensity == null || intensity.buckets.isEmpty) return const [];
    final buckets = intensity.buckets;
    final n = buckets.length;
    final span = (intensity.endMs - intensity.startMs) == 0
        ? 1
        : (intensity.endMs - intensity.startMs);
    final bucketMs = intensity.bucketMs > 0 ? intensity.bucketMs : (span / n).round();
    final gapBuckets = math.max(1, (kMotionCoalesceGapMs / bucketMs).round());
    final starts = <int>[];
    var lastOn = -1 << 30;
    for (var i = 0; i < n; i++) {
      if (buckets[i] < kMotionAbsFloor) continue;
      if (i - lastOn > gapBuckets) starts.add(intensity.startMs + i * bucketMs);
      lastOn = i;
    }
    return starts;
  }

  /// Cameras with motion at [ms] (for a hover hint), each with its start-of-
  /// bucket color already resolvable via `cameraMotionColor`. Ported from
  /// pbMotionCamerasAt.
  List<String> camerasWithMotionAt(int ms) {
    final out = <String>[];
    for (final entry in intensityByCam.entries) {
      final i = entry.value.indexAt(ms);
      if (i != null && entry.value.buckets[i] >= kMotionAbsFloor) {
        out.add(entry.key);
      }
    }
    return out;
  }

  /// Prev/Next motion navigation: searches the WHOLE recording via the
  /// backend first (reaches events outside the loaded window), falling back
  /// to a scan of the currently loaded buckets if the server call fails.
  /// Ported from pbPrevMotion/pbNextMotion + the *Local fallbacks. Returns the
  /// target ms, or null with [error] set to a status message if there's
  /// nothing in that direction.
  Future<int?> jumpToMotion({
    required String cameraId,
    required int fromMs,
    required bool next,
  }) async {
    try {
      final start = await api.fetchMotionEdge(
        session,
        cameraId,
        DateTime.fromMillisecondsSinceEpoch(fromMs, isUtc: true),
        next: next,
      );
      if (start != null) return start.millisecondsSinceEpoch;
      error = next ? 'No later motion on this camera' : 'No earlier motion on this camera';
      notifyListeners();
      return null;
    } catch (_) {
      return _jumpToMotionLocal(cameraId: cameraId, fromMs: fromMs, next: next);
    }
  }

  int? _jumpToMotionLocal({
    required String cameraId,
    required int fromMs,
    required bool next,
  }) {
    final starts = motionStartsFor(cameraId);
    if (starts.isEmpty) {
      error = 'No motion data for the selected camera';
      notifyListeners();
      return null;
    }
    if (next) {
      for (final s in starts) {
        if (s > fromMs + 500) return s;
      }
      error = 'No more motion on this camera in the loaded range';
      notifyListeners();
      return null;
    }
    var curIdx = -1;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= fromMs + 500) {
        curIdx = i;
      } else {
        break;
      }
    }
    if (curIdx > 0) return starts[curIdx - 1];
    if (curIdx < 0) {
      error = 'No earlier motion on this camera in the loaded range';
      notifyListeners();
      return null;
    }
    return starts[0];
  }
}
