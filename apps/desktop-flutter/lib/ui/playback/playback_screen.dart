// Playback tab — recorded-footage review. Port of the playback-timeline-core
// slice of apps/desktop/src/app.js's `pb*` functions: segment resolve
// (`pbFetchSegment`/`pbResolveAllPanes`/`pbSeekAllPanes`), the tile grid
// mirroring the live wall (`pbBuildTileGrid`, tile maximize on double-click),
// the canvas timeline (`PlaybackTimeline`, see playback_timeline.dart) with
// drag-to-scrub/pan/wheel-zoom, the play/pause/speed transport, the
// time-goto field (`pbHandleTimeGoto`), and jump-to-latest/first
// (`pbJumpToLatest`/`pbJumpToFirst`).
//
// OUT of scope for this port (separate features, not part of
// playback-timeline-core): per-camera motion-intensity tracks, Frigate
// detection glyphs, export-range selection, bookmarks, prev/next-motion nav.
// The canvas still has room for those to be layered on later — see
// playback_timeline_painter.dart's header comment.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/playback_api.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/ui/bookmarks/add_bookmark_dialog.dart';
import 'package:crumb_desktop/ui/hints/shift_hints.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/hotkeys/playback_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_controller.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_view.dart';

import 'playback_timeline.dart';
import 'playback_timeline_controller.dart';

class PlaybackScreen extends StatefulWidget {
  const PlaybackScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.onClose,
    this.hotkeys,
  });

  final CrumbApi api;
  final Session session;

  /// Cameras to show on the playback grid — pass the same set as the live
  /// wall so slot/camera identity matches when the operator switches tabs
  /// (mirrors `pbGetWallCameraIds` reading the shared `state.slotMap`).
  final List<Camera> cameras;

  final VoidCallback onClose;

  /// Number-key hotkeys load the assigned camera's timeline here.
  final HotkeyConfigStore? hotkeys;

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

  bool _playing = false;
  int _speedIdx = 1; // 1x
  bool _entering = true;
  String? _statusMessage;

  List<RecordedSpan> _allSpans = const [];
  DateTime? _spansLoadedStart;
  DateTime? _spansLoadedEnd;
  bool _spanReloadPending = false;
  bool _resolvePending = false;

  Timer? _tickTimer;
  DateTime _lastTickWall = DateTime.now();

  /// Periodic (5s) reload so newly-recorded footage + fresh motion appear on
  /// the scrubber/strip even while sitting still. Ported from pbStartTick.
  Timer? _idleTimer;

  final TextEditingController _timeGotoController = TextEditingController();

  @override
  void initState() {
    super.initState();
    for (final c in _cameras) {
      _panes[c.id] = _PbPane();
    }
    _selectedCameraId = _cameras.isNotEmpty ? _cameras.first.id : null;
    // Rebuild (fresh playhead for the motion strip) + debounced motion refetch
    // whenever the scrubber window/playhead changes.
    _timeline.addListener(_onTimelineChanged);
    _enter();
    _idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _reloadSpans();
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
    _timeGotoController.dispose();
    _timeline.dispose();
    _motion.dispose();
    super.dispose();
  }

  // ── entry / spans ─────────────────────────────────────────────────────────

  List<RecordedSpan> _spansForSelected() => _allSpans
      .where((s) => s.cameraId == _selectedCameraId)
      .toList(growable: false);

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
    _allSpans = spans;

    DateTime target = now;
    if (spans.isNotEmpty) {
      final latestEnd = spans
          .map((s) => s.end)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final candidate = latestEnd.subtract(const Duration(milliseconds: 1500));
      target = candidate.isAfter(now) ? now : candidate;
    }
    _timeline.setPlayhead(target, now: now);
    _timeline.setSpans(_spansForSelected());

    await _reloadSpans();
    await _resolveAll(_timeline.playhead, force: true);
    if (!mounted) return;
    setState(() {
      _entering = false;
      _statusMessage = null;
    });
  }

  Future<void> _reloadSpans() async {
    final spanMs = _timeline.span.inMilliseconds;
    final marginMs = (spanMs * 0.5).round();
    final start = _timeline.windowStart.subtract(
      Duration(milliseconds: marginMs),
    );
    final end = _timeline.windowEnd.add(Duration(milliseconds: marginMs));
    final spans = await widget.api.fetchTimeline(
      widget.session,
      _cameraIds,
      start,
      end,
    );
    if (!mounted) return;
    _allSpans = spans;
    _spansLoadedStart = start;
    _spansLoadedEnd = end;
    _timeline.setSpans(_spansForSelected());
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

  /// Cheap in-segment seek only — no /play/ resolve. Fired by the timeline's
  /// debounced live-seek while dragging.
  void _liveSeek(DateTime t) {
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
  }

  /// Playhead position is final (drag released, or a click-seek) — full
  /// cross-segment resolve + timeline reload, mirroring `pbJumpTo`.
  Future<void> _commitSeek(DateTime t) async {
    await _reloadSpans();
    await _resolveAll(t, force: true);
  }

  Future<void> _onZoomChanged() async {
    await _reloadSpans();
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

    if (_spansLoadedStart == null ||
        _timeline.windowStart.isBefore(_spansLoadedStart!) ||
        _timeline.windowEnd.isAfter(_spansLoadedEnd!)) {
      if (!_spanReloadPending) {
        _spanReloadPending = true;
        _reloadSpans().whenComplete(() => _spanReloadPending = false);
      }
    }

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

  void _handleTimeGoto() {
    final val = _timeGotoController.text.trim(); // "HH:MM" or "HH:MM:SS"
    if (val.isEmpty) return;
    final parts = val.split(':');
    if (parts.length < 2) return;
    final hh = int.tryParse(parts[0]);
    final mm = int.tryParse(parts[1]);
    if (hh == null || mm == null) return;
    final ss = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
    // Apply the time-of-day to the day currently under the playhead (not
    // "today") so refining the time while reviewing a past day doesn't jump
    // back to today and get clamped to "now" (mirrors `pbHandleTimeGoto`).
    final base = _timeline.playhead.toLocal();
    final target = DateTime(base.year, base.month, base.day, hh, mm, ss)
        .toUtc();
    _jumpTo(target);
  }

  void _selectCamera(String cameraId) {
    if (cameraId == _selectedCameraId) return;
    setState(() => _selectedCameraId = cameraId);
    _timeline.setSpans(_spansForSelected());
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

  @override
  Widget build(BuildContext context) {
    final shown = _maximizedCameraId != null
        ? _cameras.where((c) => c.id == _maximizedCameraId).toList()
        : _cameras;
    final cols = shown.isEmpty ? 1 : math.sqrt(shown.length).ceil();

    final scaffold = Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          _TopBar(
            statusMessage: _statusMessage,
            onClose: widget.onClose,
          ),
          Expanded(
            child: _entering
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white54),
                  )
                : shown.isEmpty
                ? const Center(
                    child: Text(
                      'No cameras to review.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(2),
                    child: GridView.count(
                      crossAxisCount: cols,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                      childAspectRatio: 16 / 9,
                      children: [
                        for (final cam in shown)
                          _PbTile(
                            camera: cam,
                            pane: _panes[cam.id]!,
                            selected: cam.id == _selectedCameraId,
                            maximized: cam.id == _maximizedCameraId,
                            onSelect: () => _selectCamera(cam.id),
                            onMaximizeToggle: () => _toggleMaximize(cam.id),
                          ),
                      ],
                    ),
                  ),
          ),
          _TransportBar(
            playing: _playing,
            speedLabel: '${_speeds[_speedIdx]}x',
            timeGotoController: _timeGotoController,
            onTogglePlay: _togglePlay,
            onCycleSpeed: _cycleSpeed,
            onJumpFirst: _jumpToFirst,
            onJumpLatest: _jumpToLatest,
            onTimeGoto: _handleTimeGoto,
            onFrameBack: () => _frameStep(false),
            onFrameFwd: () => _frameStep(true),
            onNudge: _shiftWindow,
            onBookmark: _addBookmark,
            onZoomOut: () => _zoomBy(1),
            onZoomIn: () => _zoomBy(-1),
          ),
          // Motion-intensity histogram + detection glyphs + legend +
          // prev/next-motion transport, synced to the scrubber window.
          MotionTimelineView(
            controller: _motion,
            cameras: _cameras,
            playheadMs: _timeline.playhead.millisecondsSinceEpoch,
            onSeek: _seekToMs,
          ),
          PlaybackTimeline(
            controller: _timeline,
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

class _TopBar extends StatelessWidget {
  const _TopBar({required this.statusMessage, required this.onClose});

  final String? statusMessage;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF15181D),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.history, color: Colors.amberAccent, size: 18),
          const SizedBox(width: 8),
          const Text(
            'Playback',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (statusMessage != null) ...[
            const SizedBox(width: 16),
            Text(
              statusMessage!,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
          const Spacer(),
          InkWell(
            onTap: onClose,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, color: Colors.white70, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.playing,
    required this.speedLabel,
    required this.timeGotoController,
    required this.onTogglePlay,
    required this.onCycleSpeed,
    required this.onJumpFirst,
    required this.onJumpLatest,
    required this.onTimeGoto,
    required this.onFrameBack,
    required this.onFrameFwd,
    required this.onNudge,
    required this.onBookmark,
    required this.onZoomOut,
    required this.onZoomIn,
  });

  final bool playing;
  final String speedLabel;
  final TextEditingController timeGotoController;
  final VoidCallback onTogglePlay;
  final VoidCallback onCycleSpeed;
  final VoidCallback onJumpFirst;
  final VoidCallback onJumpLatest;
  final VoidCallback onTimeGoto;
  final VoidCallback onFrameBack;
  final VoidCallback onFrameFwd;
  final void Function(Duration by) onNudge;
  final VoidCallback onBookmark;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF15181D),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          ShiftHint(
            hint: 'Oldest footage',
            child: IconButton(
              tooltip: 'Oldest footage',
              icon: const Icon(Icons.first_page, color: Colors.white70),
              onPressed: onJumpFirst,
            ),
          ),
          ShiftHint(
            hint: 'Step back one frame (Shift+,)',
            child: IconButton(
              tooltip: 'Frame back',
              icon: const Icon(Icons.skip_previous, color: Colors.white70),
              onPressed: onFrameBack,
            ),
          ),
          ShiftHint(
            hint: playing ? 'Pause (Space)' : 'Play (Space)',
            child: IconButton(
              tooltip: playing ? 'Pause' : 'Play',
              icon: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: onTogglePlay,
            ),
          ),
          ShiftHint(
            hint: 'Step forward one frame (Shift+.)',
            child: IconButton(
              tooltip: 'Frame forward',
              icon: const Icon(Icons.skip_next, color: Colors.white70),
              onPressed: onFrameFwd,
            ),
          ),
          ShiftHint(
            hint: 'Latest footage',
            child: IconButton(
              tooltip: 'Latest footage',
              icon: const Icon(Icons.last_page, color: Colors.white70),
              onPressed: onJumpLatest,
            ),
          ),
          ShiftHint(
            hint: 'Playback speed',
            child: TextButton(
              onPressed: onCycleSpeed,
              child: Text(
                speedLabel,
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
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
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: TextField(
              controller: timeGotoController,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'HH:MM:SS',
                hintStyle: TextStyle(color: Colors.white38),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.cyanAccent),
                ),
              ),
              onSubmitted: (_) => onTimeGoto(),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(onPressed: onTimeGoto, child: const Text('Go')),
          const Spacer(),
          ShiftHint(
            hint: 'Bookmark this moment',
            child: IconButton(
              tooltip: 'Bookmark',
              icon: const Icon(
                Icons.bookmark_add_outlined,
                color: Colors.white70,
              ),
              onPressed: onBookmark,
            ),
          ),
          ShiftHint(
            hint: 'Zoom out (longer span)',
            child: IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.zoom_out, color: Colors.white70),
              onPressed: onZoomOut,
            ),
          ),
          ShiftHint(
            hint: 'Zoom in (shorter span)',
            child: IconButton(
              tooltip: 'Zoom in',
              icon: const Icon(Icons.zoom_in, color: Colors.white70),
              onPressed: onZoomIn,
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
  });

  final Camera camera;
  final _PbPane pane;
  final bool selected;
  final bool maximized;
  final VoidCallback onSelect;
  final VoidCallback onMaximizeToggle;

  @override
  Widget build(BuildContext context) {
    final hasFootage = pane.segment != null;
    return GestureDetector(
      onTap: onSelect,
      onDoubleTap: onMaximizeToggle,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          border: Border.all(
            color: selected ? Colors.amberAccent : Colors.white12,
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
