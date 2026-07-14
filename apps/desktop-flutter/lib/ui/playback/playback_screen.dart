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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/export_api.dart' show ExportApi;
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/playback_api.dart';
import 'package:crumb_desktop/api/views_api.dart' show CustomLayout;
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';
import 'package:crumb_desktop/ui/saved_views/saved_views_screen.dart'
    show AppliedView;
import 'package:crumb_desktop/ui/bookmarks/add_bookmark_dialog.dart';
import 'package:crumb_desktop/ui/hints/shift_hints.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/hotkeys/playback_hotkeys_listener.dart';
import 'package:crumb_desktop/services/audio_follow_controller.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_controller.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_view.dart';

import 'gapless_segment_pane_controller.dart';
import 'playback_prefs.dart';
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
    this.shortcuts,
    this.clientOptions,
    this.onExportRange,
    this.initialTime,
    this.autoPlay = false,
    this.initialMaximizedCameraId,
    this.onExitFocus,
    this.onMotionController,
    this.audio,
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

  /// Remapped action-shortcut bindings (Keyboard Shortcuts settings) for the
  /// key listeners. Null → the hardcoded defaults.
  final KeyboardShortcutsStore? shortcuts;

  /// Client options — `hotkeysEnabled` is the master shortcut off switch for
  /// the listeners here. Null → shortcuts on.
  final ClientOptionsStore? clientOptions;

  /// Export a Shift+drag-selected range (camera + start/end) — the host opens
  /// the Export tab pre-filled with this clip.
  final void Function(String cameraId, DateTime start, DateTime end)?
  onExportRange;

  /// Open the playhead at this moment on entry (e.g. Clips "View on timeline")
  /// instead of jumping to the latest footage.
  final DateTime? initialTime;

  /// Start playing at [initialTime] on entry instead of landing paused on that
  /// frame. Set by the Plates pop-up's "View on timeline" hand-off (which asks
  /// for playback at the plate moment); the other hand-offs (Clips, bookmarks)
  /// leave it false and open paused as before.
  final bool autoPlay;

  /// Set when this Playback is a clip-originated single-camera focus
  /// (Clips "View on timeline"): there is no grid behind the maximized pane,
  /// so the maximize-toggle (double-click / Esc) calls this to hand control
  /// back to the opener instead of un-maximizing into a 1-up grid.
  final VoidCallback? onExitFocus;

  /// Reports this screen's motion timeline controller to the host so it can
  /// render the camera-color legend + timeline hints inside the app's bottom
  /// status bar (rather than an extra strip here). Called `(controller, true)`
  /// on entry and `(controller, false)` on dispose; the host stores it on
  /// register and clears only on a matching unregister (a keyed remount inits
  /// the new controller before the old one disposes).
  final void Function(MotionTimelineController controller, bool active)?
  onMotionController;

  /// Shared play-on-focus audio controller (the same one the live wall and the
  /// global audio button use). Playback registers its panes here so the
  /// selected/maximized camera is audible when audio is on.
  final AudioFollowController? audio;

  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
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
  // Per-camera playback engine: media_kit player + segment bookkeeping +
  // next-segment prefetch, so segment boundaries cross via an mpv playlist
  // advance (warm decoder) instead of a fresh `loadfile` that flashed black.
  final Map<String, GaplessSegmentPaneController> _panes = {};

  late final PlaybackTimelineController _timeline =
      PlaybackTimelineController();

  // Motion-intensity + detection-glyph strip above the scrubber. Its window is
  // kept in sync with the scrubber; data (re)fetch is debounced.
  late final MotionTimelineController _motion = MotionTimelineController(
    api: widget.api,
    session: widget.session,
  );
  Timer? _motionDebounce;

  // Debounced write of the timeline zoom span to shared_preferences, so a
  // continuous wheel-zoom / repeated ±-button press persists only the settled
  // value instead of hammering the prefs channel on every step.
  Timer? _spanPersistDebounce;

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

  // ── jog/shuttle (spring-return velocity review) ───────────────────────────
  // While the shuttle thumb is deflected, the shuttle ticker owns the playhead
  // (the normal play tick is stopped so the two never fight): forward runs
  // REAL decode at the mapped rate through the gapless engine; reverse — which
  // mpv cannot decode — walks the playhead backward down the filmstrip scrub
  // path (_liveSeek). Release stops playback and commits the exact frame.
  bool _shuttling = false;
  double _shuttleVelocity = 0; // signed playback rate; 0 = dead zone (hold)
  double _shuttleAppliedRate = 0; // last forward rate pushed to the players
  Timer? _shuttleTimer;
  DateTime _lastShuttleWall = DateTime.now();

  /// Periodic (5s) reload so newly-recorded footage + fresh motion appear on
  /// the scrubber/strip even while sitting still. Ported from pbStartTick.
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    // Hand our motion controller to the host so it can render the legend +
    // hints in the app's bottom status bar (set here, cleared in dispose).
    widget.onMotionController?.call(_motion, true);
    for (final c in _cameras) {
      final pane = GaplessSegmentPaneController(
        api: widget.api,
        session: widget.session,
        cameraId: c.id,
      );
      // A pane's audio eligibility (hasAudio == currentSegment != null) is
      // false at register time because no segment has loaded yet, so the
      // controller's first reconcile mutes it and never revisits. Re-run
      // reconcile whenever a pane's segment (hence hasAudio) changes so the
      // active pane becomes audible once its footage actually loads.
      pane.addListener(_syncAudioReconcile);
      _panes[c.id] = pane;
    }
    _selectedCameraId = _cameras.isNotEmpty ? _cameras.first.id : null;
    // Carry a maximized live pane into playback (if it's one of our cameras).
    final maxId = widget.initialMaximizedCameraId;
    if (maxId != null && _cameras.any((c) => c.id == maxId)) {
      _maximizedCameraId = maxId;
      _selectedCameraId = maxId;
    }
    // Register panes with the shared audio-follow controller so the active
    // (maximized else selected) camera is audible when audio is on — and reset
    // the controller's target off any stale wall pane onto ours.
    final audio = widget.audio;
    if (audio != null) {
      for (final c in _cameras) {
        final pane = _panes[c.id]!;
        audio.registerPane(
          _audioPaneId(c.id),
          AudioPane.forPlayer(
            pane.player,
            hasAudio: () => pane.currentSegment != null,
          ),
        );
      }
      audio.setMaximized(
        _maximizedCameraId != null ? _audioPaneId(_maximizedCameraId!) : null,
        paneRecreated: false,
      );
      audio.setSelected(
        _selectedCameraId != null ? _audioPaneId(_selectedCameraId!) : null,
      );
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

  @override
  void didUpdateWidget(covariant PlaybackScreen old) {
    super.didUpdateWidget(old);
    // Fresh session after an in-place re-auth — hand the new token to the
    // long-lived pollers/panes that captured the session at construction, or
    // they keep resolving segments + motion with the dead token (stuck
    // "connection lost" and false "no footage"). Per-tick fetches read
    // `widget.session` directly and are already fresh.
    if (old.session.token != widget.session.token ||
        old.session.base != widget.session.base) {
      _motion.updateSession(widget.session);
      for (final pane in _panes.values) {
        pane.updateSession(widget.session);
      }
    }
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
    _shuttleTimer?.cancel();
    _idleTimer?.cancel();
    _motionDebounce?.cancel();
    _spanPersistDebounce?.cancel();
    _timeline.removeListener(_onTimelineChanged);
    // Drop the host's reference to our motion controller before disposing it,
    // so the status-bar legend never reads a disposed controller.
    widget.onMotionController?.call(_motion, false);
    // Unregister our panes from the shared audio controller and clear the
    // target so the live wall re-establishes its own audio on the way back.
    final audio = widget.audio;
    if (audio != null) {
      audio.setMaximized(null, paneRecreated: false);
      audio.setSelected(null);
      for (final c in _cameras) {
        audio.unregisterPane(_audioPaneId(c.id));
      }
    }
    for (final p in _panes.values) {
      p.removeListener(_syncAudioReconcile);
      p.dispose();
    }
    _timeline.dispose();
    _motion.dispose();
    super.dispose();
  }

  /// Nudge the shared audio controller to re-evaluate which pane is audible.
  /// Called when any pane's segment (and thus its `hasAudio`) changes:
  /// reconcile is idempotent and cheap, and only ever acts on the active
  /// pane, so calling it from every pane's listener is safe. This closes the
  /// gap where the active pane was muted at register time (no segment yet)
  /// and never revisited once its footage loaded.
  void _syncAudioReconcile() {
    unawaited(widget.audio?.reconcile() ?? Future<void>.value());
  }

  // ── entry / spans ─────────────────────────────────────────────────────────

  Future<void> _enter() async {
    // Restore the operator's last timeline zoom span (device preference) before
    // the first window is centered, so Playback reopens at the scale they left
    // rather than the controller's default. Done first (a fast local read)
    // ahead of the slower timeline fetch below. Out-of-range/unset values fall
    // back to the default (restoreSpanMs clamps; null skips).
    final storedSpanMs = await PlaybackPrefs.getSpanMs();
    if (!mounted) return;
    if (storedSpanMs != null) _timeline.restoreSpanMs(storedSpanMs);

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

    // Seed the coverage line immediately from the fast initial fetch (the
    // selected camera's spans) so the bottom recording line shows right away.
    // The wider static preload below then extends it across the whole
    // navigable range — but if that wide query is slow or fails it must never
    // blank this seed (guarded in _syncCoverage). Don't block tab entry on it.
    final seed = spans
        .where((s) => s.cameraId == _selectedCameraId)
        .toList(growable: false);
    if (seed.isNotEmpty) _timeline.setSpans(seed);

    unawaited(_syncCoverage());
    await _resolveAll(_timeline.playhead, force: true);
    if (!mounted) return;
    setState(() {
      _entering = false;
      _statusMessage = null;
    });
    // A hand-off that requested playback (the Plates pop-up's "View on
    // timeline") starts playing at the target moment rather than landing
    // paused. The resolve above just opened each pane paused ON the target
    // frame, so this resumes from there.
    if (widget.autoPlay) _startPlayback();
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
        // A slow or failed wide query returns []. Never blank a coverage line
        // that's already showing (e.g. the initial seed) — keep it and retry on
        // a later tick (we don't cache the empty, so the wide branch runs
        // again). A camera that genuinely has no footage has an empty seed too,
        // so this correctly still shows no line for it.
        if (spans.isEmpty &&
            camId == _selectedCameraId &&
            _timeline.spans.isNotEmpty) {
          return;
        }
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

  /// Per-pane resolve/advance fan-out. `force` (an explicit jump/seek/zoom
  /// commit) invalidates each pane's prefetch and reloads; otherwise this is
  /// the 10 Hz tick body — each pane prefetches its next segment ~1 s before
  /// the boundary and crosses it via an mpv playlist advance with a warm
  /// decoder (no black flash), falling back to a fresh load only for a real
  /// coverage gap or a lost prefetch race. See [GaplessSegmentPaneController].
  /// `playing` overrides the transport's play/pause state for freshly opened
  /// files (the forward shuttle decodes while `_playing` stays false).
  Future<void> _resolveAll(
    DateTime t, {
    bool force = false,
    bool? playing,
  }) async {
    final play = playing ?? _playing;
    final futures = <Future<void>>[];
    for (final cam in _activeCameras()) {
      final pane = _panes[cam.id]!;
      futures.add(
        force
            ? pane.resolveAt(t, forceReload: true, playing: play)
            : pane.onTick(t, playing: play),
      );
    }
    await Future.wait(futures);
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
      // Cheap in-segment seek; no-op if `t` left the loaded segment (the
      // cross-segment resolve happens once on release, in _commitSeek).
      unawaited(_panes[cam.id]?.seekWithinSegment(t) ?? Future.value());
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
    // Every span change (both the ±-buttons and the wheel-zoom in the timeline
    // view) funnels through here — the single choke point to persist the new
    // zoom scale as a device preference, debounced so a continuous gesture
    // writes only the settled value.
    _persistSpanDebounced();
    unawaited(_syncCoverage());
    await _resolveAll(_timeline.playhead, force: true);
  }

  /// Schedule a debounced write of the current timeline span to prefs.
  void _persistSpanDebounced() {
    final ms = _timeline.span.inMilliseconds;
    _spanPersistDebounce?.cancel();
    _spanPersistDebounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(PlaybackPrefs.setSpanMs(ms)),
    );
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

  static String _hms(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';

  static String _mmdd(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} ';

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
    // Show the ACTUAL start/end times (local), not just the length — so a
    // precise export window can be read straight off the bar.
    final startT = DateTime.fromMillisecondsSinceEpoch(ss, isUtc: true).toLocal();
    final endT = DateTime.fromMillisecondsSinceEpoch(se, isUtc: true).toLocal();
    final sameDay = startT.year == endT.year &&
        startT.month == endT.month &&
        startT.day == endT.day;
    final startLabel = '${_mmdd(startT)}${_hms(startT)}';
    final endLabel = sameDay ? _hms(endT) : '${_mmdd(endT)}${_hms(endT)}';
    return Container(
      color: const Color(0xFF2A2410),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.content_cut, size: 16, color: Color(0xFFE8A33D)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '$startLabel  →  $endLabel   ($durLabel)',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
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
    if (_shuttling) return; // the shuttle owns the transport until release
    setState(() => _playing = !_playing);
    for (final pane in _panes.values) {
      if (_playing) {
        pane.player.play();
      } else {
        pane.player.pause();
      }
    }
    if (_playing) {
      _startTick();
    } else {
      _tickTimer?.cancel();
      _tickTimer = null;
    }
  }

  /// Begin playback (idempotent) — used by the [PlaybackScreen.autoPlay]
  /// entry hand-off. No-op while shuttling or already playing.
  void _startPlayback() {
    if (_shuttling || _playing) return;
    setState(() => _playing = true);
    for (final pane in _panes.values) {
      pane.player.play();
    }
    _startTick();
  }

  void _setSpeed(int idx) {
    setState(() => _speedIdx = idx);
    for (final pane in _panes.values) {
      // `rate` is reasserted by the pane after any fallback fresh open (mpv
      // keeps `speed` across the gapless playlist advance, but not loadfile).
      pane.rate = _speeds[_speedIdx];
      pane.player.setRate(_speeds[_speedIdx]);
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
        pane.player.pause();
      }
      if (mounted) setState(() {});
    }
  }

  // ── jog/shuttle ───────────────────────────────────────────────────────────

  /// Drag update from the shuttle control. `velocity` is a signed playback
  /// rate (+2.0 = 2× forward, −0.5 = 0.5× backward, 0 = dead zone / hold).
  /// The first update takes the transport over: the normal play tick stops
  /// (so the two tickers never fight over the playhead) and the shuttle
  /// ticker starts. Actual rate/decode changes are applied on the 100 ms
  /// shuttle tick, which throttles mpv `setRate` spam from pointer-rate
  /// drag updates.
  void _onShuttleUpdate(double velocity) {
    if (!_shuttling) {
      _shuttling = true;
      _tickTimer?.cancel();
      _tickTimer = null;
      if (_playing) setState(() => _playing = false);
      _shuttleAppliedRate = 0;
      for (final pane in _panes.values) {
        pane.player.pause();
      }
      _lastShuttleWall = DateTime.now();
      _shuttleTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        _onShuttleTick,
      );
    }
    _shuttleVelocity = velocity;
  }

  /// Shuttle released — spring-return: stop (pause), restore the steady
  /// speed-pill rate so Play behaves normally afterwards, and resolve the
  /// exact frame under the playhead (also drops any reverse-scrub filmstrip).
  Future<void> _onShuttleEnd() async {
    if (!_shuttling) return;
    _shuttling = false;
    _shuttleVelocity = 0;
    _shuttleAppliedRate = 0;
    _shuttleTimer?.cancel();
    _shuttleTimer = null;
    for (final pane in _panes.values) {
      pane.player.pause();
      pane.rate = _speeds[_speedIdx];
      unawaited(pane.player.setRate(_speeds[_speedIdx]));
    }
    if (mounted) setState(() {});
    await _commitSeek(_timeline.playhead);
  }

  void _onShuttleTick(Timer _) {
    if (!_shuttling) return;
    final wallNow = DateTime.now();
    final elapsedMs = wallNow.difference(_lastShuttleWall).inMilliseconds;
    _lastShuttleWall = wallNow;
    if (elapsedMs <= 0) return;
    final v = _shuttleVelocity;

    final nowUtc = DateTime.now().toUtc();
    var next = _timeline.playhead;
    if (v != 0) {
      next = next.add(Duration(milliseconds: (elapsedMs * v).round()));
      // Never shuttle into the future…
      if (next.isAfter(nowUtc)) next = nowUtc;
      // …and never reverse past the start of known footage (mirrors
      // _jumpToFirst's earliest-span floor). No coverage loaded → leave
      // unclamped; the panes just show "no footage".
      if (v < 0 && _timeline.spans.isNotEmpty) {
        var earliestMs = _timeline.spans.first.startMs;
        for (final s in _timeline.spans) {
          if (s.startMs < earliestMs) earliestMs = s.startMs;
        }
        final earliest = DateTime.fromMillisecondsSinceEpoch(
          earliestMs,
          isUtc: true,
        );
        if (next.isBefore(earliest)) next = earliest;
      }
    }

    // Pinned at "now" while shuttling forward: hold with decoders paused
    // (same live-edge posture as _onTick) until the operator eases back.
    final atLiveEdge =
        v > 0 &&
        !next.isBefore(nowUtc.subtract(const Duration(milliseconds: 200)));

    if (v > 0 && !atLiveEdge) {
      _applyShuttleForwardRate(v);
    } else if (_shuttleAppliedRate > 0) {
      // Left the forward zone (dead zone, reverse, or live edge) — freeze
      // the real decode; reverse review is filmstrip-driven below.
      _shuttleAppliedRate = 0;
      for (final pane in _panes.values) {
        pane.player.pause();
      }
    }

    if (v == 0) return; // dead zone — hold position
    _timeline.setPlayhead(next, now: nowUtc);

    if (v > 0) {
      // Forward: same fan-out as the normal play tick — panes prefetch and
      // cross segment boundaries gaplessly at the shuttled rate.
      if (!atLiveEdge && !_resolvePending) {
        _resolvePending = true;
        _resolveAll(
          next,
          playing: true,
        ).whenComplete(() => _resolvePending = false);
      }
    } else {
      // Reverse: mpv can't decode backward — ride the filmstrip scrub path
      // (cheap in-segment keyframe seeks + server-extracted frames), which is
      // rock-solid in any direction. The real video resolves on release.
      _liveSeek(next);
    }
  }

  /// Push the forward shuttle rate to the players (throttled to real
  /// changes). On the first forward tick after reverse/hold, drop any
  /// filmstrip overlay and start the decoders.
  void _applyShuttleForwardRate(double v) {
    if ((v - _shuttleAppliedRate).abs() <= 0.01) return;
    final starting = _shuttleAppliedRate <= 0;
    _shuttleAppliedRate = v;
    if (starting && (_scrubbing || _scrubFrames.isNotEmpty)) {
      _scrubToken++; // invalidate in-flight filmstrip fetches
      setState(() {
        _scrubbing = false;
        _scrubFrames.clear();
      });
    }
    for (final pane in _panes.values) {
      // Keep pane.rate in sync so a fallback fresh open reasserts the
      // shuttled rate (same contract as _setSpeed); restored on release.
      pane.rate = v;
      unawaited(pane.player.setRate(v));
      if (starting) unawaited(pane.player.play());
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

  /// Audio-follow pane id for a playback camera (distinct from the wall's
  /// `wall:<id>` so the two screens don't clash in the shared controller).
  String _audioPaneId(String camId) => 'pb:$camId';

  void _selectCamera(String cameraId) {
    if (cameraId == _selectedCameraId) return;
    setState(() => _selectedCameraId = cameraId);
    widget.audio?.setSelected(_audioPaneId(cameraId));
    // Instant repaint from the cache (empty on first select of this camera),
    // then preload / live-edge top-up in the background.
    _timeline.setSpans(_coverage[cameraId]?.spans ?? const []);
    unawaited(_syncCoverage());
    _scheduleMotionRefresh(); // redraw the selected motion track prominent
  }

  void _toggleMaximize(String cameraId) {
    // Clip-originated single-camera focus: "restore" leaves the focus view
    // entirely (back to the Clips box that opened it) — there's no grid here.
    if (widget.onExitFocus != null) {
      widget.onExitFocus!();
      return;
    }
    setState(() {
      _maximizedCameraId = _maximizedCameraId == cameraId ? null : cameraId;
    });
    // Audio follows the maximized pane (or falls back to the selected one when
    // restored). The pane's Player persists across maximize, so not recreated.
    widget.audio?.setMaximized(
      _maximizedCameraId != null ? _audioPaneId(_maximizedCameraId!) : null,
      paneRecreated: false,
    );
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
        recordsElsewhere: _recordsElsewhere(maxCam.id),
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
                      recordsElsewhere: _recordsElsewhere(cam.id),
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

  /// Whether [camId] has any recording coverage loaded — i.e. it records at
  /// SOME time in the navigable range. Lets a no-footage pane distinguish a
  /// motion camera's normal gap ("records elsewhere") from a camera with no
  /// footage at all (worth flagging). Null when coverage isn't loaded for this
  /// camera (only the selected camera is fetched) → the tile stays neutral.
  bool? _recordsElsewhere(String camId) {
    final cov = _coverage[camId];
    if (cov == null) return null;
    return cov.spans.isNotEmpty;
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
            speeds: _speeds,
            speedIdx: _speedIdx,
            gotoLabel: _fmtPlayheadLabel(),
            onTogglePlay: _togglePlay,
            onSetSpeed: _setSpeed,
            onShuttle: _onShuttleUpdate,
            onShuttleEnd: _onShuttleEnd,
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
          // itself — drag = pan, click = seek, wheel = zoom, right-drag or
          // Shift+drag = export range (right-click menu → add clip to export
          // list). (Replaces the old separate bottom scrubber bar.)
          MotionTimelineView(
            motion: _motion,
            timeline: _timeline,
            cameras: _cameras,
            selectedCameraName: _selectedCamera?.name,
            onLiveSeek: _liveSeek,
            onCommitSeek: _commitSeek,
            onZoomChanged: _onZoomChanged,
            onExportSelection: _exportSelection,
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
        shortcuts: widget.shortcuts,
        options: widget.clientOptions,
        onGoToCamera: _selectCamera,
        child: tree,
      );
    }
    return PlaybackHotkeysListener(
      autofocus: !hasGlobal,
      shortcuts: widget.shortcuts,
      options: widget.clientOptions,
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
    required this.speeds,
    required this.speedIdx,
    required this.gotoLabel,
    required this.onTogglePlay,
    required this.onSetSpeed,
    required this.onShuttle,
    required this.onShuttleEnd,
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
  final List<double> speeds;
  final int speedIdx;
  final String gotoLabel;
  final VoidCallback onTogglePlay;
  final ValueChanged<int> onSetSpeed;

  /// Jog/shuttle drag: signed playback rate (0 = dead zone), then release.
  final ValueChanged<double> onShuttle;
  final VoidCallback onShuttleEnd;

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

  static String _fmtSpeed(double s) =>
      s == s.truncateToDouble() ? '${s.toInt()}×' : '$s×';

  /// The playback-speed control: a bordered accent pill showing the current
  /// rate with a speedometer icon, opening a menu to pick a rate directly.
  Widget _speedPill(Color accent) {
    return ShiftHint(
      hint: 'Playback speed',
      child: PopupMenuButton<int>(
        tooltip: 'Playback speed',
        initialValue: speedIdx,
        onSelected: onSetSpeed,
        position: PopupMenuPosition.under,
        itemBuilder: (context) => [
          for (var i = 0; i < speeds.length; i++)
            CheckedPopupMenuItem<int>(
              value: i,
              checked: i == speedIdx,
              child: Text(_fmtSpeed(speeds[i])),
            ),
        ],
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: accent.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.speed, size: 15, color: accent),
              const SizedBox(width: 5),
              Text(
                _fmtSpeed(speeds[speedIdx]),
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 16, color: accent),
            ],
          ),
        ),
      ),
    );
  }

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
          // ── left cluster: coarse nudges (far left) + speed (next to play) ──
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
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
                const Spacer(),
                // Jog/shuttle (broadcast-style): spring-return velocity
                // review — a transient tool, distinct from the speed pill's
                // steady rate — sitting just left of the play cluster.
                _ShuttleControl(
                  accent: accent,
                  onShuttle: onShuttle,
                  onShuttleEnd: onShuttleEnd,
                ),
                const SizedBox(width: 8),
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
          // ── right cluster: speed + go-to date/time + bookmark + zoom ─────
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Playback speed pill, just right of the center play cluster.
                _speedPill(accent),
                const SizedBox(width: 10),
                // Fixed width + left-aligned + tabular figures so the ticking
                // clock never resizes the button and jitters the speed pill.
                SizedBox(
                  width: 172,
                  child: ShiftHint(
                    hint: 'Jump to a date & time',
                    child: OutlinedButton.icon(
                      onPressed: onPickGoto,
                      icon: const Icon(Icons.event, size: 15),
                      label: Text(
                        gotoLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
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

/// Broadcast-style jog/shuttle: a horizontal track with a
/// spring-return center thumb. Drag the thumb right to play forward, left to
/// review backward; the further from center, the faster (0.25×–8×ᵉˣᵖ). A
/// small dead zone around center reads as "hold", and releasing springs the
/// thumb home and stops playback (the parent pauses + commits the frame).
///
/// Self-contained: owns only the thumb position; playback behavior lives in
/// the parent via [onShuttle] (signed rate on every drag update, 0 = dead
/// zone) and [onShuttleEnd] (release).
class _ShuttleControl extends StatefulWidget {
  const _ShuttleControl({
    required this.accent,
    required this.onShuttle,
    required this.onShuttleEnd,
  });

  final Color accent;

  /// Signed velocity in playback-rate units (+2.0 = 2× forward, −0.5 = 0.5×
  /// backward, 0 = dead zone / hold). Fired on every drag update.
  final ValueChanged<double> onShuttle;
  final VoidCallback onShuttleEnd;

  @override
  State<_ShuttleControl> createState() => _ShuttleControlState();
}

class _ShuttleControlState extends State<_ShuttleControl> {
  static const double _width = 148;
  static const double _height = 28;
  static const double _knob = 16;

  /// |deflection| below this fraction of full throw = dead zone (hold).
  static const double _deadZone = 0.12;
  static const double _minSpeed = 0.25;
  static const double _maxSpeed = 8;

  double _frac = 0; // thumb deflection, −1 (full left) .. 1 (full right)
  bool _dragging = false;

  /// Exponential drag→speed mapping: just past the dead zone = [_minSpeed],
  /// full deflection = [_maxSpeed]:
  ///   speed = 0.25 × 32^u,  u = (|frac| − 0.12) / (1 − 0.12)
  /// so speed doubles every fifth of the remaining throw (half throw ≈ 1.4×)
  /// and the low, precise speeds get most of the travel. Sign = direction.
  static double _velocityFor(double frac) {
    final a = frac.abs();
    if (a <= _deadZone) return 0;
    final u = (a - _deadZone) / (1 - _deadZone);
    final speed = _minSpeed * math.pow(_maxSpeed / _minSpeed, u).toDouble();
    return frac < 0 ? -speed : speed;
  }

  static String _fmtVelocity(double v) {
    final a = v.abs();
    final s = a >= 1 ? a.toStringAsFixed(1) : a.toStringAsFixed(2);
    return '${v < 0 ? '−' : ''}${s.endsWith('.0') ? a.toStringAsFixed(0) : s}×';
  }

  void _applyFromDx(double dx) {
    const half = (_width - _knob) / 2; // px of thumb travel each way
    final frac = ((dx - _width / 2) / half).clamp(-1.0, 1.0);
    setState(() => _frac = frac);
    widget.onShuttle(_velocityFor(frac));
  }

  void _onDragStart(DragStartDetails d) {
    _dragging = true;
    _applyFromDx(d.localPosition.dx);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_dragging) _applyFromDx(d.localPosition.dx);
  }

  void _onDragStop() {
    if (!_dragging) return;
    _dragging = false;
    setState(() => _frac = 0); // AnimatedAlign springs the thumb home
    widget.onShuttleEnd();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final v = _velocityFor(_frac);
    final active = _dragging && v != 0;
    return ShiftHint(
      hint: 'Shuttle — drag to review, release to stop',
      child: Tooltip(
        message:
            'Shuttle: drag right to play forward, left to review backward.\n'
            'Further = faster (0.25×–8×); release to stop.',
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: (_) => _onDragStop(),
          onHorizontalDragCancel: _onDragStop,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: SizedBox(
              width: _width,
              height: _height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Track groove.
                  Container(
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Colors.white24, width: 0.5),
                    ),
                  ),
                  // Speed ticks at half throw each way + the center notch.
                  for (final x in const [-0.5, 0.5])
                    Align(
                      alignment: Alignment(x, 0),
                      child: Container(
                        width: 1,
                        height: 8,
                        color: Colors.white24,
                      ),
                    ),
                  Container(width: 2, height: 12, color: Colors.white38),
                  // Transient speed readout, on the side away from the thumb.
                  if (active)
                    Align(
                      alignment: Alignment(_frac > 0 ? -0.7 : 0.7, 0),
                      child: Text(
                        _fmtVelocity(v),
                        style: TextStyle(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  // The spring-return thumb.
                  AnimatedAlign(
                    alignment: Alignment(_frac, 0),
                    duration: _dragging
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    curve: Curves.easeOutBack,
                    child: Container(
                      width: _knob,
                      height: _knob,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? accent : const Color(0xFF3A414B),
                        border: Border.all(
                          color: active ? accent : Colors.white38,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PbTile extends StatefulWidget {
  const _PbTile({
    required this.camera,
    required this.pane,
    required this.selected,
    required this.maximized,
    required this.onSelect,
    required this.onMaximizeToggle,
    this.recordsElsewhere,
    this.scrubFrame,
  });

  final Camera camera;
  final GaplessSegmentPaneController pane;
  final bool selected;
  final bool maximized;
  final VoidCallback onSelect;
  final VoidCallback onMaximizeToggle;

  /// Whether this camera has recording coverage at OTHER times (records
  /// elsewhere in range). Distinguishes a normal motion-camera gap (`true`) from
  /// a camera with no footage at all (`false`, worth flagging). Null = unknown
  /// (coverage not loaded for this camera) → a neutral message.
  final bool? recordsElsewhere;

  /// Filmstrip frame shown over the video while the scrubber is being dragged.
  final Uint8List? scrubFrame;

  @override
  State<_PbTile> createState() => _PbTileState();
}

class _PbTileState extends State<_PbTile> {
  // Per-pane digital zoom, ported from the live wall's _WallTile (see
  // wall_screen.dart): hover the pane + mouse wheel zooms IN PLACE, drag pans
  // when zoomed. Double-click still maximizes. Playback plays a single segment
  // stream, so there is no sub→main swap like the live wall's zoomToMain.
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  static const double _maxZoom = 8.0;

  void _zoomAt(Offset cursor, double factor, Size pane) {
    final newScale = (_scale * factor).clamp(1.0, _maxZoom);
    if (newScale == _scale) return;
    final newOffset = cursor - (cursor - _offset) * (newScale / _scale);
    setState(() {
      _scale = newScale;
      _offset = _clampOffset(newOffset, pane);
    });
  }

  Offset _clampOffset(Offset o, Size pane) {
    final minX = pane.width * (1 - _scale);
    final minY = pane.height * (1 - _scale);
    return Offset(
      o.dx.clamp(minX <= 0 ? minX : 0.0, 0.0),
      o.dy.clamp(minY <= 0 ? minY : 0.0, 0.0),
    );
  }

  void _panBy(Offset delta, Size pane) {
    if (_scale <= 1.0) return;
    setState(() => _offset = _clampOffset(_offset + delta, pane));
  }

  /// The overlay shown when a pane has no live segment: a load error, a spinner
  /// while resolving, or — once resolved with nothing here — a styled "no
  /// footage" placeholder that reads calmly for a motion gap but flags a camera
  /// with no footage at all.
  Widget _noFootageOverlay() {
    if (widget.pane.error != null) {
      return _placeholder(
        icon: Icons.videocam_off_rounded,
        iconColor: Colors.red.shade300,
        title: 'Playback error',
        subtitle: 'Could not load this segment',
        tint: Colors.red,
      );
    }
    if (!widget.pane.noFootage) {
      // Still resolving / opening a segment.
      return const ColoredBox(
        color: Colors.black54,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    // Resolved: genuinely no footage at this instant.
    if (widget.recordsElsewhere == false) {
      // No coverage anywhere in range — a live/always-record camera with no
      // footage is worth flagging (amber).
      return _placeholder(
        icon: Icons.warning_amber_rounded,
        iconColor: Colors.amber.shade400,
        title: 'No footage for this camera',
        subtitle: 'No recordings found in this time range',
        tint: Colors.amber,
      );
    }
    // Records at other times (motion-gated gap) or unknown → calm.
    return _placeholder(
      icon: Icons.motion_photos_off_rounded,
      iconColor: Colors.white38,
      title: widget.recordsElsewhere == true
          ? 'No motion during this time'
          : 'No footage at this time',
      subtitle: widget.recordsElsewhere == true
          ? 'This camera records on motion'
          : null,
      tint: Colors.blueGrey,
    );
  }

  Widget _placeholder({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required Color tint,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          radius: 1.1,
          colors: [
            tint.withValues(alpha: 0.16),
            Colors.black.withValues(alpha: 0.82),
          ],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            // A solid dark scrim pill behind the content so the message stays
            // legible over a bright scene (the radial gradient alone is near-
            // transparent at its centre and washed out on a light background).
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: iconColor, size: 34),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      shadows: [
                        Shadow(color: Colors.black, blurRadius: 4),
                      ],
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10.5,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The digital-zoom transform applied to the video (and the scrub frame so
  /// they stay aligned while zoomed).
  Matrix4 get _zoomTransform => Matrix4.identity()
    ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
    ..scaleByDouble(_scale, _scale, 1, 1);

  @override
  Widget build(BuildContext context) {
    final hasFootage = widget.pane.currentSegment != null;
    // Selected-tile outline follows the active tab accent (cyan on Playback).
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final paneSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onTap: widget.onSelect,
          onDoubleTap: widget.onMaximizeToggle,
          // Drag pans the image only while zoomed in (no-op at 1×).
          onPanUpdate: (d) => _panBy(d.delta, paneSize),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade900,
              border: Border.all(
                color: widget.selected ? accent : Colors.white12,
                width: widget.selected ? 2 : 1,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Hover the pane + mouse wheel → digital zoom IN PLACE, exactly
                // like the live wall tiles (#87-adjacent: playback panes had no
                // wheel-zoom, so hovering the video and scrolling did nothing).
                Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      final factor =
                          math.pow(1.0013, -e.scrollDelta.dy) as double;
                      _zoomAt(e.localPosition, factor, paneSize);
                    }
                  },
                  child: ClipRect(
                    child: Transform(
                      transform: _zoomTransform,
                      child: Video(
                        controller: widget.pane.videoController,
                        controls: NoVideoControls,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                if (!hasFootage) Positioned.fill(child: _noFootageOverlay()),
                // Filmstrip scrub frame: covers the (frozen) video while
                // dragging so scrubbing is smooth and never flashes black.
                // Zoomed with the same transform so it stays aligned.
                if (widget.scrubFrame != null)
                  Positioned.fill(
                    child: ClipRect(
                      child: Transform(
                        transform: _zoomTransform,
                        child: Image.memory(
                          widget.scrubFrame!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
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
                            color: hasFootage
                                ? Colors.amberAccent
                                : Colors.white24,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.camera.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
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
      },
    );
  }
}
