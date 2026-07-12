// Playback tab — recorded-footage review. Port of the playback-timeline-core
// slice of apps/desktop/src/app.js's `pb*` functions: segment resolve
// (`pbFetchSegment`/`pbResolveAllPanes`/`pbSeekAllPanes`), the tile grid
// mirroring the live wall (`pbBuildTileGrid`, tile maximize on double-click),
// the play/pause/speed transport, the date/time goto, and jump-to-latest/first
// (`pbJumpToLatest`/`pbJumpToFirst`).
//
// The scrub surface is a SINGLE unified strip (`MotionTimelineView`): motion
// intensity + Frigate detection glyphs + a thin recording-coverage line, and
// the drag-to-scrub/pan/wheel-zoom/Shift-select interaction itself, all driven
// by the shared [PlaybackTimelineController]. (The old separate bottom scrubber
// bar was folded into it.)

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/export_api.dart' show ExportApi;
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/playback_api.dart';
import 'package:crumb_desktop/api/views_api.dart' show CustomLayout;
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/ui/saved_views/saved_views_screen.dart'
    show AppliedView;
import 'package:crumb_desktop/ui/bookmarks/add_bookmark_dialog.dart';
import 'package:crumb_desktop/ui/hints/shift_hints.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/hotkeys/playback_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_controller.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_view.dart';

import 'playback_timeline_controller.dart';

class PlaybackScreen extends StatefulWidget {
  const PlaybackScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.onClose,
    this.view,
    this.hotkeys,
    this.onExportRange,
    this.initialTime,
    this.initialMaximizedCameraId,
  });

  final CrumbApi api;
  final Session session;

  /// Cameras to show on the playback grid — pass the same set as the live
  /// wall so slot/camera identity matches when the operator switches tabs
  /// (mirrors `pbGetWallCameraIds` reading the shared `state.slotMap`).
  final List<Camera> cameras;

  /// The applied saved view — playback reproduces its exact custom layout
  /// (cell spans), scaled to fit, matching the live wall. Null → an auto-grid
  /// of [cameras].
  final AppliedView? view;

  /// Open with this camera already maximized (carried over from a maximized
  /// live pane when the operator switches to Playback).
  final String? initialMaximizedCameraId;

  final VoidCallback onClose;

  /// Number-key hotkeys load the assigned camera's timeline here.
  final HotkeyConfigStore? hotkeys;

  /// Export a Shift+drag-selected range (camera + start/end) — the host opens
  /// the Export tab pre-filled with this clip.
  final void Function(String cameraId, DateTime start, DateTime end)?
  onExportRange;

  /// Open the playhead at this moment on entry (e.g. Clips "View on timeline")
  /// instead of jumping to the latest footage.
  final DateTime? initialTime;

  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
}

/// Mutable per-camera pane state: the media_kit player (created lazily, on
/// first resolved segment) plus which segment it currently has loaded.
class _PbPane {
  Player? player;
  VideoController? controller;
  ResolvedSegment? segment;
  bool loading = false;
  String? error;

  void dispose() {
    player?.dispose();
  }
}

/// Cached full-range recording coverage for one camera: merged spans over
/// `[start, freshAt]`. `freshAt` is the live edge the cache is known fresh
/// to — the periodic top-up fetches only `[freshAt − 1 min, now]` and unions
/// it in, so scrubbing/panning never triggers another wide query.
class _CoverageCache {
  _CoverageCache({
    required this.start,
    required this.freshAt,
    required this.spans,
  });

  DateTime start;
  DateTime freshAt;
  List<RecordedSpan> spans;
}

const List<double> _speeds = [0.5, 1, 2, 4, 8];

class _PlaybackScreenState extends State<PlaybackScreen> {
  late final List<Camera> _cameras = widget.cameras
      .where((c) => c.enabled)
      .toList(growable: false);
  late final List<String> _cameraIds = _cameras
      .map((c) => c.id)
      .toList(growable: false);
  final Map<String, _PbPane> _panes = {};

  late final PlaybackTimelineController _timeline =
      PlaybackTimelineController();

  // Motion-intensity + detection-glyph strip above the scrubber. Its window is
  // kept in sync with the scrubber; data (re)fetch is debounced.
  late final MotionTimelineController _motion = MotionTimelineController(
    api: widget.api,
    session: widget.session,
  );
  Timer? _motionDebounce;

  String? _selectedCameraId;
  String? _maximizedCameraId;

  // ── filmstrip scrubbing ──────────────────────────────────────────────────
  // While dragging the scrubber we DON'T reopen the video players (that caused
  // black flashing crossing segment boundaries). Instead the focused pane shows
  // a server-extracted filmstrip frame at the drag position — "rock solid"
  // scrubbing — and the real video resolve happens once on release.
  bool _scrubbing = false;
  final Map<String, Uint8List?> _scrubFrames = {};
  int _scrubToken = 0;
  DateTime _lastScrubFetch = DateTime.fromMillisecondsSinceEpoch(0);

  bool _playing = false;
  int _speedIdx = 1; // 1x
  bool _entering = true;
  String? _statusMessage;

  // Per-camera preloaded recording coverage for the timeline's thin bottom
  // line. Fetched ONCE per camera across the whole navigable range (not a
  // window around the playhead, which made the line visibly "draw itself"
  // behind the scrubber) — see _syncCoverage.
  final Map<String, _CoverageCache> _coverage = {};
  final Set<String> _coverageLoading = {};
  int _idleTicks = 0;
  bool _resolvePending = false;

  Timer? _tickTimer;
  DateTime _lastTickWall = DateTime.now();

  /// Periodic (5s) reload so newly-recorded footage + fresh motion appear on
  /// the scrubber/strip even while sitting still. Ported from pbStartTick.
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    for (final c in _cameras) {
      _panes[c.id] = _PbPane();
    }
    _selectedCameraId = _cameras.isNotEmpty ? _cameras.first.id : null;
    // Carry a maximized live pane into playback (if it's one of our cameras).
    final maxId = widget.initialMaximizedCameraId;
    if (maxId != null && _cameras.any((c) => c.id == maxId)) {
      _maximizedCameraId = maxId;
      _selectedCameraId = maxId;
    }
    // Rebuild (fresh playhead for the motion strip) + debounced motion refetch
    // whenever the scrubber window/playhead changes.
    _timeline.addListener(_onTimelineChanged);
    _enter();
    _idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _idleTicks++;
      // Live-edge top-up most ticks; a full re-fetch every ~5 min so coverage
      // evicted by retention eventually drops off the line.
      unawaited(_syncCoverage(force: _idleTicks % 60 == 0));
      _scheduleMotionRefresh();
    });
  }

  void _onTimelineChanged() {
    if (mounted) setState(() {});
    _scheduleMotionRefresh();
  }

  /// Keep the motion controller's window/selection in step with the scrubber,
  /// then (debounced) refetch intensity + detections.
  void _scheduleMotionRefresh() {
    _motion.configure(
      windowStartMs: _timeline.windowStart.millisecondsSinceEpoch,
      windowEndMs: _timeline.windowEnd.millisecondsSinceEpoch,
      wallCameraIds: _cameraIds,
      selectedCameraId: _maximizedCameraId ?? _selectedCameraId,
    );
    _motionDebounce?.cancel();
    _motionDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _motion.refresh(),
    );
  }

  /// Seek the playhead to `ms` epoch (from a motion-strip click / prev-next).
  Future<void> _seekToMs(int ms) async {
    final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    _timeline.setPlayhead(t, now: DateTime.now().toUtc());
    await _commitSeek(t);
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _idleTimer?.cancel();
    _motionDebounce?.cancel();
    _timeline.removeListener(_onTimelineChanged);
    for (final p in _panes.values) {
      p.dispose();
    }
    _timeline.dispose();
    _motion.dispose();
    super.dispose();
  }

  // ── entry / spans ─────────────────────────────────────────────────────────

  Future<void> _enter() async {
    final now = DateTime.now().toUtc();
    setState(() => _statusMessage = 'Loading timeline…');

    final spans = await widget.api.fetchTimeline(
      widget.session,
      _cameraIds,
      now.subtract(const Duration(hours: 24)),
      now.add(const Duration(minutes: 1)),
    );
    if (!mounted) return;

    DateTime target = now;
    final initial = widget.initialTime?.toUtc();
    if (initial != null) {
      target = initial.isAfter(now) ? now : initial;
    } else if (spans.isNotEmpty) {
      final latestEnd = spans
          .map((s) => s.end)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final candidate = latestEnd.subtract(const Duration(milliseconds: 1500));
      target = candidate.isAfter(now) ? now : candidate;
    }
    _timeline.setPlayhead(target, now: now);

    await _syncCoverage();
    await _resolveAll(_timeline.playhead, force: true);
    if (!mounted) return;
    setState(() {
      _entering = false;
      _statusMessage = null;
    });
  }

  // ── recording coverage (the timeline's thin bottom line) ──────────────────

  /// Coverage preload horizon behind "now" (or behind the visible window when
  /// the operator navigates deeper) — matches [_jumpToFirst]'s 30-day search.
  static const Duration _coverageHorizon = Duration(days: 30);

  /// Server hard cap per /timeline response (MAX_SPAN_LIMIT in timeline.rs);
  /// pages of this size are fetched until a short page arrives.
  static const int _coveragePageLimit = 10000;
  static const int _coverageMaxPages = 5;

  /// Bring the selected camera's coverage cache up to date and push it to the
  /// timeline. Not cached yet, `force`, or the window navigated past the
  /// cached start → ONE wide fetch (30 days behind min(now, window start));
  /// already cached → top up just the live edge since `freshAt`. Pan / zoom /
  /// scrub therefore never trigger wide queries — the coverage line is static.
  Future<void> _syncCoverage({bool force = false}) async {
    final camId = _selectedCameraId;
    if (camId == null || _coverageLoading.contains(camId)) return;
    final now = DateTime.now().toUtc();
    final end = now.add(const Duration(minutes: 1));
    final cached = _coverage[camId];

    _coverageLoading.add(camId);
    try {
      if (force ||
          cached == null ||
          _timeline.windowStart.isBefore(cached.start)) {
        final navStart = _timeline.windowStart.isBefore(now)
            ? _timeline.windowStart
            : now;
        final start = navStart.subtract(_coverageHorizon);
        final spans = await _fetchCoverage(camId, start, end);
        if (!mounted) return;
        _coverage[camId] = _CoverageCache(
          start: start,
          freshAt: now,
          spans: spans,
        );
      } else {
        // Debounce back-to-back top-ups (commit-seek right after an idle tick).
        if (now.difference(cached.freshAt) < const Duration(seconds: 2)) {
          return;
        }
        final fresh = await _fetchCoverage(
          camId,
          cached.freshAt.subtract(const Duration(minutes: 1)),
          end,
        );
        if (!mounted) return;
        cached.spans = _unionSpans(cached.spans, fresh);
        cached.freshAt = now;
      }
    } finally {
      _coverageLoading.remove(camId);
    }
    if (camId == _selectedCameraId) {
      _timeline.setSpans(_coverage[camId]!.spans);
    }
  }

  /// Fetch every merged recorded span for [cameraId] over `[start, end)`,
  /// paging past the server's per-response span cap.
  Future<List<RecordedSpan>> _fetchCoverage(
    String cameraId,
    DateTime start,
    DateTime end,
  ) async {
    final all = <RecordedSpan>[];
    var offset = 0;
    for (var page = 0; page < _coverageMaxPages; page++) {
      final spans = await widget.api.fetchTimeline(
        widget.session,
        [cameraId],
        start,
        end,
        limit: _coveragePageLimit,
        offset: offset,
      );
      all.addAll(spans);
      if (spans.length < _coveragePageLimit) break;
      offset += spans.length;
    }
    return all;
  }

  /// Union two span lists into one sorted, merged list (single camera).
  /// Overlaps and sub-second seams are merged with the same 1 s tolerance as
  /// the server's GAP_TOLERANCE_MS so a live-edge top-up extends the current
  /// span instead of stacking a duplicate next to it.
  List<RecordedSpan> _unionSpans(
    List<RecordedSpan> a,
    List<RecordedSpan> b,
  ) {
    const gapMs = 1000;
    final all = [...a, ...b]..sort((x, y) => x.startMs.compareTo(y.startMs));
    final out = <RecordedSpan>[];
    for (final s in all) {
      final last = out.isEmpty ? null : out.last;
      if (last != null && s.startMs <= last.endMs + gapMs) {
        if (s.endMs > last.endMs) {
          out[out.length - 1] = RecordedSpan(
            cameraId: last.cameraId,
            start: last.start,
            end: s.end,
            hasMotion: last.hasMotion || s.hasMotion,
            stage: last.stage,
          );
        }
      } else {
        out.add(s);
      }
    }
    return out;
  }

  // ── segment resolve ─────────────────────────────────────────────────────────

  /// Slots that currently own a pane: the maximized camera alone, or every
  /// camera in the grid — mirrors `pbActiveSlots`.
  List<Camera> _activeCameras() {
    if (_maximizedCameraId != null) {
      final c = _cameras.where((c) => c.id == _maximizedCameraId);
      return c.isEmpty ? const [] : [c.first];
    }
    return _cameras;
  }

  Future<void> _resolveAll(DateTime t, {bool force = false}) async {
    final futures = <Future<void>>[];
    for (final cam in _activeCameras()) {
      final pane = _panes[cam.id]!;
      final existing = pane.segment;
      if (!force && existing != null && existing.covers(t)) {
        continue; // still-valid segment — no network call needed
      }
      futures.add(_resolveOne(cam.id, pane, t, force));
    }
    await Future.wait(futures);
  }

  Future<void> _resolveOne(
    String cameraId,
    _PbPane pane,
    DateTime t,
    bool force,
  ) async {
    final seg = await widget.api.resolveSegment(widget.session, cameraId, t);
    if (!mounted) return;
    if (seg == null) {
      pane.segment = null;
      pane.error = null; // "no footage right now" is not an error state
      setState(() {});
      return;
    }
    final sameFile = pane.segment?.segmentId == seg.segmentId;
    if (sameFile && !force) {
      pane.segment = seg;
      return;
    }
    final url = await widget.api.mediaUrlForSegment(widget.session, seg);
    if (!mounted) return;
    if (url == null) {
      pane.error = 'media token failed';
      setState(() {});
      return;
    }
    await _openSegment(pane, seg, url, t, reuseFile: sameFile);
  }

  Future<void> _openSegment(
    _PbPane pane,
    ResolvedSegment seg,
    String url,
    DateTime t, {
    required bool reuseFile,
  }) async {
    pane.loading = true;
    if (mounted) setState(() {});
    try {
      pane.player ??= Player();
      pane.controller ??= VideoController(pane.player!);
      final p = pane.player!.platform;
      if (p is NativePlayer) {
        for (final kv in const [
          ['rtsp-transport', 'tcp'],
          ['hwdec', 'auto'],
          ['cache', 'yes'],
          ['demuxer-readahead-secs', '2.0'],
          ['demuxer-max-bytes', '32MiB'],
          ['demuxer-max-back-bytes', '1MiB'],
          ['network-timeout', '10'],
          ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
        ]) {
          try {
            await p.setProperty(kv[0], kv[1]);
          } catch (_) {
            /* non-fatal */
          }
        }
      }
      pane.segment = seg;
      if (!reuseFile) {
        await pane.player!.open(Media(url), play: _playing);
        await pane.player!.setRate(_speeds[_speedIdx]);
      }
      final offsetMs = t
          .difference(seg.start)
          .inMilliseconds
          .clamp(0, seg.durationMs)
          .toInt();
      await pane.player!.seek(Duration(milliseconds: offsetMs));
      if (!_playing) await pane.player!.pause();
      pane.loading = false;
      pane.error = null;
    } catch (_) {
      pane.loading = false;
      pane.error = 'load failed';
    }
    if (mounted) setState(() {});
  }

  /// Live-scrub, fired continuously while dragging the scrubber. Panes are NOT
  /// reopened here (that flashes black across segment boundaries): panes whose
  /// loaded segment covers `t` do a cheap in-segment keyframe seek, and the
  /// focused pane additionally shows a server-extracted filmstrip frame so it
  /// tracks the scrubber rock-solid even across segments. The real cross-segment
  /// resolve happens once on release ([_commitSeek]).
  void _liveSeek(DateTime t) {
    if (!_scrubbing) {
      setState(() => _scrubbing = true);
    }
    for (final cam in _activeCameras()) {
      final pane = _panes[cam.id];
      final seg = pane?.segment;
      if (pane?.player != null && seg != null && seg.covers(t)) {
        final offsetMs = t
            .difference(seg.start)
            .inMilliseconds
            .clamp(0, seg.durationMs)
            .toInt();
        pane!.player!.seek(Duration(milliseconds: offsetMs));
      }
    }
    // Filmstrip frame for the focused pane, throttled (~8/sec) to cap the
    // server-side extract load, superseded-request-safe via a token.
    final focusId = _maximizedCameraId ?? _selectedCameraId;
    if (focusId == null) return;
    final now = DateTime.now();
    if (now.difference(_lastScrubFetch) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastScrubFetch = now;
    _fetchScrubFrame(focusId, t, ++_scrubToken);
  }

  Future<void> _fetchScrubFrame(String camId, DateTime t, int token) async {
    final bytes = await widget.api.fetchFilmstripFrame(
      widget.session,
      camId,
      t,
      width: 480,
    );
    if (!mounted || token != _scrubToken || !_scrubbing) return;
    setState(() => _scrubFrames[camId] = bytes);
  }

  /// Playhead position is final (drag released, or a click-seek) — full
  /// cross-segment resolve + timeline reload, mirroring `pbJumpTo`.
  Future<void> _commitSeek(DateTime t) async {
    // Drag released: drop the filmstrip overlay and load the real video.
    if (_scrubbing || _scrubFrames.isNotEmpty) {
      _scrubToken++; // invalidate any in-flight filmstrip fetches
      setState(() {
        _scrubbing = false;
        _scrubFrames.clear();
      });
    }
    // Coverage is preloaded (static) — this only extends the cache if the
    // operator navigated past its horizon, so don't hold up the video resolve.
    unawaited(_syncCoverage());
    await _resolveAll(t, force: true);
  }

  Future<void> _onZoomChanged() async {
    unawaited(_syncCoverage());
    await _resolveAll(_timeline.playhead, force: true);
  }

  /// Step the timeline zoom (−/＋ buttons). +1 = zoom out (longer window).
  void _zoomBy(int dir) {
    if (_timeline.zoomStep(dir)) unawaited(_onZoomChanged());
  }

  /// Bookmark the current moment on the selected camera (opens the dialog).
  Future<void> _addBookmark() async {
    await showAddBookmarkDialog(
      context,
      api: widget.api,
      session: widget.session,
      camera: _selectedCamera,
      cameras: _cameras,
      at: _timeline.playhead,
    );
  }

  /// Hand the Shift+drag selection off to the Export tab as a pre-filled clip.
  void _exportSelection() {
    final ss = _timeline.selStartMs;
    final se = _timeline.selEndMs;
    final camId = _maximizedCameraId ?? _selectedCameraId;
    if (ss == null || se == null || camId == null) return;
    widget.onExportRange?.call(
      camId,
      DateTime.fromMillisecondsSinceEpoch(ss, isUtc: true),
      DateTime.fromMillisecondsSinceEpoch(se, isUtc: true),
    );
    _timeline.clearSelection();
  }

  Widget _buildExportSelectionBar() {
    final ss = _timeline.selStartMs!;
    final se = _timeline.selEndMs!;
    final s = ((se - ss) / 1000).round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final durLabel = h > 0
        ? '${h}h ${m}m'
        : (m > 0 ? '${m}m ${sec}s' : '${sec}s');
    return Container(
      color: const Color(0xFF2A2410),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.content_cut, size: 16, color: Color(0xFFE8A33D)),
          const SizedBox(width: 8),
          Text(
            'Selection: $durLabel',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const Spacer(),
          TextButton(
            onPressed: _timeline.clearSelection,
            child: const Text('Clear'),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: widget.onExportRange == null ? null : _exportSelection,
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Export selection'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE8A33D),
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  /// Shift the playhead by a signed duration (arrow keys / nudge buttons).
  Future<void> _shiftWindow(Duration by) async {
    final t = _timeline.playhead.add(by);
    _timeline.setPlayhead(t, now: DateTime.now().toUtc());
    await _commitSeek(_timeline.playhead);
  }

  /// Jump to the previous/next motion event on the selected camera.
  Future<void> _jumpMotion(bool next) async {
    final camId = _maximizedCameraId ?? _selectedCameraId;
    if (camId == null) return;
    final target = await _motion.jumpToMotion(
      cameraId: camId,
      fromMs: _timeline.playhead.millisecondsSinceEpoch,
      next: next,
    );
    if (target != null) await _seekToMs(target);
  }

  /// Nudge every active pane's player by ±1 frame (pauses first). Approximate
  /// (uses estimated-vf-fps), good enough for frame-by-frame review.
  Future<void> _frameStep(bool forward) async {
    if (_playing) _togglePlay();
    for (final cam in _activeCameras()) {
      final player = _panes[cam.id]?.player;
      if (player == null) continue;
      try {
        double fps = 30;
        final p = player.platform;
        if (p is NativePlayer) {
          final raw = await p.getProperty('estimated-vf-fps');
          final parsed = double.tryParse(raw);
          if (parsed != null && parsed > 0) fps = parsed;
        }
        final frameMs = (1000 / fps).round().clamp(1, 1000);
        final cur = player.state.position;
        var target = forward
            ? cur + Duration(milliseconds: frameMs)
            : cur - Duration(milliseconds: frameMs);
        if (target < Duration.zero) target = Duration.zero;
        await player.seek(target);
      } catch (_) {
        /* non-fatal per-pane */
      }
    }
  }

  // ── transport ─────────────────────────────────────────────────────────────

  void _togglePlay() {
    setState(() => _playing = !_playing);
    for (final pane in _panes.values) {
      if (pane.player == null) continue;
      if (_playing) {
        pane.player!.play();
      } else {
        pane.player!.pause();
      }
    }
    if (_playing) {
      _startTick();
    } else {
      _tickTimer?.cancel();
      _tickTimer = null;
    }
  }

  void _cycleSpeed() {
    setState(() => _speedIdx = (_speedIdx + 1) % _speeds.length);
    for (final pane in _panes.values) {
      pane.player?.setRate(_speeds[_speedIdx]);
    }
  }

  void _startTick() {
    _tickTimer?.cancel();
    _lastTickWall = DateTime.now();
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), _onTick);
  }

  void _onTick(Timer _) {
    if (!_playing) return;
    final wallNow = DateTime.now();
    final elapsedMs = wallNow.difference(_lastTickWall).inMilliseconds;
    _lastTickWall = wallNow;

    final advanceMs = (elapsedMs * _speeds[_speedIdx]).round();
    final nowUtc = DateTime.now().toUtc();
    var next = _timeline.playhead.add(Duration(milliseconds: advanceMs));
    if (next.isAfter(nowUtc)) next = nowUtc;
    _timeline.setPlayhead(next, now: nowUtc);

    if (!_resolvePending) {
      _resolvePending = true;
      _resolveAll(next).whenComplete(() => _resolvePending = false);
    }

    // Pause at the live edge — caught up to "now", nothing more to play.
    if (!next.isBefore(nowUtc.subtract(const Duration(milliseconds: 200)))) {
      _playing = false;
      _tickTimer?.cancel();
      _tickTimer = null;
      for (final pane in _panes.values) {
        pane.player?.pause();
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _jumpTo(DateTime t) async {
    final now = DateTime.now().toUtc();
    _timeline.setPlayhead(t.isAfter(now) ? now : t, now: now);
    await _commitSeek(_timeline.playhead);
  }

  Future<void> _jumpToLatest() async {
    final now = DateTime.now().toUtc();
    final spans = await widget.api.fetchTimeline(
      widget.session,
      _cameraIds,
      now.subtract(const Duration(hours: 24)),
      now.add(const Duration(minutes: 1)),
    );
    if (spans.isEmpty) {
      if (mounted) {
        setState(() => _statusMessage = 'No recorded footage found');
      }
      return;
    }
    final latestEnd = spans
        .map((s) => s.end)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final target = latestEnd.subtract(const Duration(milliseconds: 1500));
    await _jumpTo(target.isAfter(now) ? now : target);
  }

  Future<void> _jumpToFirst() async {
    final now = DateTime.now().toUtc();
    final spans = await widget.api.fetchTimeline(
      widget.session,
      _cameraIds,
      now.subtract(const Duration(days: 30)),
      now.add(const Duration(minutes: 1)),
    );
    if (spans.isEmpty) {
      if (mounted) {
        setState(() => _statusMessage = 'No recorded footage found');
      }
      return;
    }
    final earliestStart = spans
        .map((s) => s.start)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    await _jumpTo(earliestStart.add(const Duration(milliseconds: 1000)));
  }

  /// Pick an exact date + time to jump to (replaces the old free-text
  /// HH:MM:SS field). Seeds both pickers from the current playhead so refining
  /// while reviewing a past day stays on that day.
  Future<void> _pickGotoDateTime() async {
    final base = _timeline.playhead.toLocal();
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base.isAfter(now) ? now : base,
      firstDate: now.subtract(const Duration(days: 3650)),
      lastDate: now,
      initialEntryMode: DatePickerEntryMode.input,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (time == null || !mounted) return;
    final target = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    ).toUtc();
    await _jumpTo(target);
  }

  static const List<String> _monthAbbr = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Compact local label for the goto button, e.g. "Jul 11, 6:26:41 PM".
  String _fmtPlayheadLabel() {
    final d = _timeline.playhead.toLocal();
    final h24 = d.hour;
    final ampm = h24 >= 12 ? 'PM' : 'AM';
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final ss = d.second.toString().padLeft(2, '0');
    return '${_monthAbbr[d.month - 1]} ${d.day}, $h12:$mm:$ss $ampm';
  }

  void _selectCamera(String cameraId) {
    if (cameraId == _selectedCameraId) return;
    setState(() => _selectedCameraId = cameraId);
    // Instant repaint from the cache (empty on first select of this camera),
    // then preload / live-edge top-up in the background.
    _timeline.setSpans(_coverage[cameraId]?.spans ?? const []);
    unawaited(_syncCoverage());
    _scheduleMotionRefresh(); // redraw the selected motion track prominent
  }

  void _toggleMaximize(String cameraId) {
    setState(() {
      _maximizedCameraId = _maximizedCameraId == cameraId ? null : cameraId;
    });
    // Newly-active panes (e.g. the whole grid again after un-maximizing)
    // may not hold the right segment yet — force a resolve at the current
    // playhead for whichever set is now active.
    _resolveAll(_timeline.playhead, force: false);
  }

  // ── build ────────────────────────────────────────────────────────────────

  Camera? get _selectedCamera {
    final id = _selectedCameraId;
    if (id == null) return null;
    for (final c in _cameras) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Fractional-cell grid that scales to fit the available area (never crops /
  /// overflows), reproducing the applied view's exact layout — the same model
  /// as the live wall's `_viewGrid`. Maximized → the one camera fills the area;
  /// no view → an auto-grid of all cameras.
  Widget _buildGrid() {
    if (_maximizedCameraId != null) {
      Camera? cam;
      for (final c in _cameras) {
        if (c.id == _maximizedCameraId) {
          cam = c;
          break;
        }
      }
      if (cam == null) return const SizedBox.shrink();
      final maxCam = cam;
      return _PbTile(
        camera: maxCam,
        pane: _panes[maxCam.id]!,
        selected: true,
        maximized: true,
        onSelect: () => _selectCamera(maxCam.id),
        onMaximizeToggle: () => _toggleMaximize(maxCam.id),
        scrubFrame: _scrubbing ? _scrubFrames[maxCam.id] : null,
      );
    }

    final CustomLayout layout;
    final String? Function(int) camForCell;
    final view = widget.view;
    if (view != null) {
      layout = view.layout;
      camForCell = (i) => view.slots[i];
    } else {
      final n = _cameras.isEmpty ? 1 : _cameras.length;
      var cols = 1;
      while (cols * cols < n) {
        cols++;
      }
      final rows = (n + cols - 1) ~/ cols;
      layout = CustomLayout.unitGrid(cols, rows);
      camForCell = (i) => i < _cameras.length ? _cameras[i].id : null;
    }

    final byId = {for (final c in _cameras) c.id: c};
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        const g = 1.0;
        final children = <Widget>[];
        for (var i = 0; i < layout.cells.length; i++) {
          final cell = layout.cells[i];
          final camId = camForCell(i);
          final cam = camId == null ? null : byId[camId];
          children.add(
            Positioned(
              left: cell.x / layout.cols * w + g,
              top: cell.y / layout.rows * h + g,
              width: (cell.w / layout.cols * w - 2 * g).clamp(0.0, w),
              height: (cell.h / layout.rows * h - 2 * g).clamp(0.0, h),
              child: cam == null
                  ? const ColoredBox(color: Colors.black)
                  : _PbTile(
                      camera: cam,
                      pane: _panes[cam.id]!,
                      selected: cam.id == _selectedCameraId,
                      maximized: false,
                      onSelect: () => _selectCamera(cam.id),
                      onMaximizeToggle: () => _toggleMaximize(cam.id),
                      scrubFrame: _scrubbing ? _scrubFrames[cam.id] : null,
                    ),
            ),
          );
        }
        return Stack(children: children);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // No subheader here: Playback lives under the shared app header
          // (tabs + view row) owned by MainShell. Status ("Loading timeline…",
          // "No recorded footage found") floats as an unobtrusive overlay chip
          // instead of a whole bar.
          Expanded(
            child: Stack(
              children: [
                if (_entering)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white54),
                  )
                else if (_cameras.isEmpty)
                  const Center(
                    child: Text(
                      'No cameras to review.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                else
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: _buildGrid(),
                    ),
                  ),
                if (!_entering && _statusMessage != null)
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          _statusMessage!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _TransportBar(
            playing: _playing,
            speedLabel: '${_speeds[_speedIdx]}x',
            gotoLabel: _fmtPlayheadLabel(),
            onTogglePlay: _togglePlay,
            onCycleSpeed: _cycleSpeed,
            onJumpFirst: _jumpToFirst,
            onJumpLatest: _jumpToLatest,
            onPrevMotion: () => _jumpMotion(false),
            onNextMotion: () => _jumpMotion(true),
            onPickGoto: _pickGotoDateTime,
            onFrameBack: () => _frameStep(false),
            onFrameFwd: () => _frameStep(true),
            onNudge: _shiftWindow,
            onBookmark: _addBookmark,
            onZoomOut: () => _zoomBy(1),
            onZoomIn: () => _zoomBy(-1),
          ),
          if (_timeline.hasSelection) _buildExportSelectionBar(),
          // The single playback timeline: motion intensity + detection glyphs +
          // a thin recording-coverage line at the bottom, and the scrub surface
          // itself — drag = pan, click = seek, wheel = zoom, Shift+drag =
          // export range. (Replaces the old separate bottom scrubber bar.)
          MotionTimelineView(
            motion: _motion,
            timeline: _timeline,
            cameras: _cameras,
            selectedCameraName: _selectedCamera?.name,
            onLiveSeek: _liveSeek,
            onCommitSeek: _commitSeek,
            onZoomChanged: _onZoomChanged,
          ),
        ],
      ),
    );

    // Keyboard: number keys load a camera (GlobalHotkeysListener, autofocus so
    // it's the focused node); Space/arrows/,/./frame-step bubble up to the
    // PlaybackHotkeysListener wrapping it.
    Widget tree = scaffold;
    final hk = widget.hotkeys;
    final hasGlobal = hk != null;
    if (hasGlobal) {
      tree = GlobalHotkeysListener(
        store: hk,
        cameras: _cameras,
        autofocus: true,
        onGoToCamera: _selectCamera,
        child: tree,
      );
    }
    return PlaybackHotkeysListener(
      autofocus: !hasGlobal,
      isMaximized: _maximizedCameraId != null,
      onTogglePlay: _togglePlay,
      onShiftWindow: _shiftWindow,
      onPrevMotion: () => _jumpMotion(false),
      onNextMotion: () => _jumpMotion(true),
      onFrameStep: _frameStep,
      onExitMaximize: _maximizedCameraId != null
          ? () => _toggleMaximize(_maximizedCameraId!)
          : null,
      child: tree,
    );
  }
}

/// The transport bar. Layout: a left cluster (speed + coarse nudges), a
/// CENTERED playback cluster over the scrubber's midpoint (oldest · prev-motion
/// · frame-back · play · frame-fwd · next-motion · latest), and a right cluster
/// (go-to date/time · bookmark · zoom). The centering is achieved with equal
/// Expanded spacers flanking the fixed-width middle.
class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.playing,
    required this.speedLabel,
    required this.gotoLabel,
    required this.onTogglePlay,
    required this.onCycleSpeed,
    required this.onJumpFirst,
    required this.onJumpLatest,
    required this.onPrevMotion,
    required this.onNextMotion,
    required this.onPickGoto,
    required this.onFrameBack,
    required this.onFrameFwd,
    required this.onNudge,
    required this.onBookmark,
    required this.onZoomOut,
    required this.onZoomIn,
  });

  final bool playing;
  final String speedLabel;
  final String gotoLabel;
  final VoidCallback onTogglePlay;
  final VoidCallback onCycleSpeed;
  final VoidCallback onJumpFirst;
  final VoidCallback onJumpLatest;
  final VoidCallback onPrevMotion;
  final VoidCallback onNextMotion;
  final VoidCallback onPickGoto;
  final VoidCallback onFrameBack;
  final VoidCallback onFrameFwd;
  final void Function(Duration by) onNudge;
  final VoidCallback onBookmark;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;

  Widget _iconBtn(
    IconData icon,
    String tip,
    String hint,
    VoidCallback onPressed, {
    Color color = Colors.white70,
    double size = 22,
  }) {
    return ShiftHint(
      hint: hint,
      child: IconButton(
        tooltip: tip,
        iconSize: size,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: color),
        onPressed: onPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Transport controls follow the active tab's accent (cyan on Playback).
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      color: const Color(0xFF15181D),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          // ── left cluster: speed + coarse nudges ──────────────────────────
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                ShiftHint(
                  hint: 'Playback speed',
                  child: TextButton(
                    onPressed: onCycleSpeed,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      speedLabel,
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                for (final n in const [
                  (-3600, '−1h'),
                  (-600, '−10m'),
                  (600, '+10m'),
                  (3600, '+1h'),
                ])
                  ShiftHint(
                    hint: 'Jump ${n.$2}',
                    child: TextButton(
                      onPressed: () => onNudge(Duration(seconds: n.$1)),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        foregroundColor: Colors.white70,
                      ),
                      child: Text(n.$2, style: const TextStyle(fontSize: 11)),
                    ),
                  ),
              ],
            ),
          ),
          // ── centered playback cluster (over the scrubber midpoint) ────────
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _iconBtn(
                Icons.first_page,
                'Oldest footage',
                'Oldest footage',
                onJumpFirst,
              ),
              // Previous motion — the old client's "run to the mover" glyph,
              // mirrored to face back, tinted with the tab accent.
              ShiftHint(
                hint: 'Previous motion (↑)',
                child: IconButton(
                  tooltip: 'Previous motion',
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  icon: Transform.flip(
                    flipX: true,
                    child: Icon(Icons.directions_run, color: accent),
                  ),
                  onPressed: onPrevMotion,
                ),
              ),
              _iconBtn(
                Icons.navigate_before,
                'Frame back',
                'Step back one frame (Shift+,)',
                onFrameBack,
              ),
              ShiftHint(
                hint: playing ? 'Pause (Space)' : 'Play (Space)',
                child: IconButton(
                  tooltip: playing ? 'Pause' : 'Play',
                  iconSize: 30,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    playing ? Icons.pause_circle : Icons.play_circle,
                    color: accent,
                  ),
                  onPressed: onTogglePlay,
                ),
              ),
              _iconBtn(
                Icons.navigate_next,
                'Frame forward',
                'Step forward one frame (Shift+.)',
                onFrameFwd,
              ),
              _iconBtn(
                Icons.directions_run,
                'Next motion',
                'Next motion (↓)',
                onNextMotion,
                color: accent,
              ),
              _iconBtn(
                Icons.last_page,
                'Latest footage',
                'Latest footage',
                onJumpLatest,
              ),
            ],
          ),
          // ── right cluster: go-to date/time + bookmark + zoom ─────────────
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ShiftHint(
                  hint: 'Jump to a date & time',
                  child: OutlinedButton.icon(
                    onPressed: onPickGoto,
                    icon: const Icon(Icons.event, size: 15),
                    label: Text(
                      gotoLabel,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _iconBtn(
                  Icons.bookmark_add_outlined,
                  'Bookmark',
                  'Bookmark this moment',
                  onBookmark,
                  size: 20,
                ),
                _iconBtn(
                  Icons.zoom_out,
                  'Zoom out',
                  'Zoom out (longer span)',
                  onZoomOut,
                  size: 20,
                ),
                _iconBtn(
                  Icons.zoom_in,
                  'Zoom in',
                  'Zoom in (shorter span)',
                  onZoomIn,
                  size: 20,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PbTile extends StatelessWidget {
  const _PbTile({
    required this.camera,
    required this.pane,
    required this.selected,
    required this.maximized,
    required this.onSelect,
    required this.onMaximizeToggle,
    this.scrubFrame,
  });

  final Camera camera;
  final _PbPane pane;
  final bool selected;
  final bool maximized;
  final VoidCallback onSelect;
  final VoidCallback onMaximizeToggle;

  /// Filmstrip frame shown over the video while the scrubber is being dragged.
  final Uint8List? scrubFrame;

  @override
  Widget build(BuildContext context) {
    final hasFootage = pane.segment != null;
    // Selected-tile outline follows the active tab accent (cyan on Playback).
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onSelect,
      onDoubleTap: onMaximizeToggle,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          border: Border.all(
            color: selected ? accent : Colors.white12,
            width: selected ? 2 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (pane.controller != null)
              Video(
                controller: pane.controller!,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              )
            else
              Center(
                child: pane.error != null
                    ? Icon(
                        Icons.videocam_off,
                        color: Colors.red.shade300,
                        size: 24,
                      )
                    : (pane.loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const SizedBox.shrink()),
              ),
            if (!hasFootage && pane.controller != null)
              Container(color: Colors.black54),
            // Filmstrip scrub frame: covers the (frozen) video while dragging so
            // scrubbing is smooth and never flashes black.
            if (scrubFrame != null)
              Positioned.fill(
                child: Image.memory(
                  scrubFrame!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hasFootage ? Colors.amberAccent : Colors.white24,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      camera.name,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            if (!hasFootage)
              const Positioned(
                right: 6,
                top: 6,
                child: Text(
                  'no footage',
                  style: TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
