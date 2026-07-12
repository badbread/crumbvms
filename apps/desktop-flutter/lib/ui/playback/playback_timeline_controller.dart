// Playback timeline state: the visible window, playhead, zoom step, and the
// recorded spans for the selected camera. Port of the relevant slice of
// `pbState` in apps/desktop/src/app.js (windowStartMs/windowEndMs/playheadMs
// + PB_ZOOM_STEPS + pbRecenter/pbSetZoomIndex/pbCurrentZoomIdx).
//
// Model: CENTERED. The playhead is always horizontally centered in the
// visible window; panning/scrubbing/zooming all move the window edges to
// keep the playhead centered rather than moving the playhead within a fixed
// window. This matches the old client exactly (see `pbRecenter` /
// `pbJumpTo` / `pbSetZoomIndex` in app.js) and is what makes "drag right =
// scroll back in time, playhead stays under your thumb" work.

import 'package:flutter/foundation.dart';

import '../../api/playback_api.dart';

class PlaybackTimelineController extends ChangeNotifier {
  PlaybackTimelineController({
    DateTime? initialPlayhead,
    Duration initialSpan = const Duration(hours: 1),
  }) : playhead = (initialPlayhead ?? DateTime.now().toUtc()),
       _spanMs = initialSpan.inMilliseconds
           .clamp(zoomStepsMs.first, zoomStepsMs.last)
           .toInt() {
    _recenter();
  }

  /// Window durations in ms (2 min .. 24 h) — verbatim port of
  /// `PB_ZOOM_STEPS` in app.js.
  static const List<int> zoomStepsMs = [
    2 * 60000,
    5 * 60000,
    15 * 60000,
    30 * 60000,
    60 * 60000,
    3 * 3600000,
    6 * 3600000,
    12 * 3600000,
    24 * 3600000,
  ];

  late DateTime windowStart;
  late DateTime windowEnd;
  DateTime playhead;
  int _spanMs;

  /// Recorded spans for the SELECTED camera only (the painter's coverage
  /// bar). Other-camera / motion-intensity overlays are out of scope for
  /// this port.
  List<RecordedSpan> spans = const [];

  Duration get span => Duration(milliseconds: _spanMs);

  void _recenter() {
    final half = _spanMs ~/ 2;
    windowStart = playhead.subtract(Duration(milliseconds: half));
    windowEnd = playhead.add(Duration(milliseconds: _spanMs - half));
  }

  /// Move the playhead to `t` (clamped to `now`, never seek into the
  /// future), recentering the window. Notifies listeners (repaints the
  /// canvas) but does NOT itself trigger a server fetch — callers wire that
  /// up via the `onLiveSeek` / `onCommitSeek` callbacks on
  /// [PlaybackTimeline].
  void setPlayhead(DateTime t, {DateTime? now}) {
    final n = (now ?? DateTime.now().toUtc());
    playhead = t.isAfter(n) ? n : t;
    _recenter();
    notifyListeners();
  }

  void setSpans(List<RecordedSpan> s) {
    spans = s;
    notifyListeners();
  }

  /// Nearest zoom-step index whose duration is >= the current span.
  int get zoomIndex {
    final idx = zoomStepsMs.indexWhere((s) => s >= _spanMs);
    return idx == -1 ? zoomStepsMs.length - 1 : idx;
  }

  /// Step the zoom by `direction` (-1 = zoom in / shorter window, +1 = zoom
  /// out / longer window), pivoting on the (centered) playhead. Returns
  /// `true` if the zoom actually changed (callers reload the timeline +
  /// re-resolve panes only then).
  bool zoomStep(int direction) {
    final idx = zoomIndex;
    final next = (idx + direction).clamp(0, zoomStepsMs.length - 1);
    if (next == idx) return false;
    _spanMs = zoomStepsMs[next];
    _recenter();
    notifyListeners();
    return true;
  }

  /// Jump straight to an absolute zoom-step index (e.g. from a slider).
  bool setZoomIndex(int idx) {
    final clamped = idx.clamp(0, zoomStepsMs.length - 1);
    if (zoomStepsMs[clamped] == _spanMs) return false;
    _spanMs = zoomStepsMs[clamped];
    _recenter();
    notifyListeners();
    return true;
  }

  // ── Export range selection (Shift+drag on the timeline) ──────────────────
  int? _selStartMs;
  int? _selEndMs;

  int? get selStartMs => _selStartMs;
  int? get selEndMs => _selEndMs;

  /// True when a usable (start < end) export range is selected.
  bool get hasSelection =>
      _selStartMs != null && _selEndMs != null && _selEndMs! > _selStartMs!;

  /// Set (or update) the selection; values are normalized so start <= end.
  void setSelection(int? aMs, int? bMs) {
    if (aMs == null || bMs == null) {
      _selStartMs = aMs;
      _selEndMs = bMs;
    } else {
      _selStartMs = aMs < bMs ? aMs : bMs;
      _selEndMs = aMs < bMs ? bMs : aMs;
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selStartMs == null && _selEndMs == null) return;
    _selStartMs = null;
    _selEndMs = null;
    notifyListeners();
  }
}
