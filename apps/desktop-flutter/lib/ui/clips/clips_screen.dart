// Clips tab: grid browser of recorded motion/detection clips, with lazy
// thumbnails, time-cursor pagination, and an in-app player (digital zoom +
// auto zoom-to-detection-bbox, quality toggle, snapshot, bookmark, viewed
// tracking). Ported from the Tauri client's clipsEnter/clipsLoad/clipsPlay
// family (apps/desktop/src/app.js ~9420-10020) onto the Crumb server's
// GET /clips + GET/POST /clip(s) media/viewed routes (services/api/src/clips.rs).
//
// Lazy thumbnails: the old client hand-rolled an IntersectionObserver +
// concurrency gate over a manually-paged DOM. Flutter's GridView.builder
// already only builds items near the viewport (bounded by cacheExtent), which
// gives the same "don't fire a request stampede for the whole page" property
// for free; a small [_ConcurrencyGate] on top still caps simultaneous
// thumbnail HTTP loads (matches CLIPS_THUMB_CONCURRENCY = 6 in the old code)
// for a fast scroll that reveals many tiles at once.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:crumb_desktop/api/clips_api.dart';
import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';

enum ClipsDensity { compact, normal, large }

const _clipsPageSize = 200;
const _thumbConcurrency = 6;
const _clipZoomMax = 5.0;
const _clipLoadTimeout = Duration(milliseconds: 4500);
const _clipMaxRetries = 2;

const _rangeOptions = <int, String>{
  1: '1 hour',
  6: '6 hours',
  12: '12 hours',
  24: '24 hours',
  72: '3 days',
  168: '7 days',
  336: '14 days',
  720: '30 days',
};

const _kClipsHoursKey = 'crumb.clips.hours';
const _kClipsDensityKey = 'crumb.clips.density';

class ClipsScreen extends StatefulWidget {
  const ClipsScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    this.initialCameraId,
    this.hotkeys,
    this.onViewOnTimeline,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Start the list filtered to this camera (e.g. a number-key hotkey).
  final String? initialCameraId;

  /// Number-key hotkeys filter the list to the assigned camera.
  final HotkeyConfigStore? hotkeys;

  /// "View on timeline" from the clip player → open Playback at this moment.
  final void Function(String cameraId, DateTime at)? onViewOnTimeline;

  @override
  State<ClipsScreen> createState() => _ClipsScreenState();
}

class _ClipsScreenState extends State<ClipsScreen> {
  String? _cameraId; // null = all cameras
  String _type = 'all'; // "all" | "detection" | "motion"
  int _hours = 24;
  DateTime? _anchorEnd; // null = window ends "now"
  ClipsDensity _density = ClipsDensity.normal;

  bool _loading = false;
  String? _error;
  List<ClipDescriptor> _clips = const [];
  int _motionHighlightSeconds = 0;
  final Set<String> _viewedLocal = {}; // optimistic dimming ahead of the server ack

  DateTime? _windowStart;
  final List<DateTime> _pageEnds = [];
  int _pageIdx = 0;
  DateTime? _oldestShown;

  final _thumbGate = _ConcurrencyGate(_thumbConcurrency);

  ClipDescriptor? _playing;

  @override
  void initState() {
    super.initState();
    _cameraId = widget.initialCameraId;
    _restorePrefs();
    _load();
  }

  Future<void> _restorePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final h = prefs.getInt(_kClipsHoursKey);
      final d = prefs.getString(_kClipsDensityKey);
      if (!mounted) return;
      setState(() {
        if (h != null && _rangeOptions.containsKey(h)) _hours = h;
        if (d != null) {
          _density = ClipsDensity.values.firstWhere(
            (e) => e.name == d,
            orElse: () => _density,
          );
        }
      });
      _load();
    } catch (_) {
      /* prefs unavailable — in-memory only */
    }
  }

  Future<void> _persistPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kClipsHoursKey, _hours);
      await prefs.setString(_kClipsDensityKey, _density.name);
    } catch (_) {
      /* best-effort */
    }
  }

  List<String> get _cameraIds =>
      _cameraId != null ? [_cameraId!] : widget.cameras.map((c) => c.id).toList();

  bool get _hasOlder => _clips.length >= _clipsPageSize;
  bool get _hasNewer => _pageIdx > 0;

  Future<void> _load({String? nav}) async {
    if (_cameraIds.isEmpty) {
      setState(() {
        _clips = const [];
        _error = null;
      });
      return;
    }
    if (nav == 'older') {
      if (_oldestShown == null) return;
      final nextEnd = _oldestShown!.subtract(const Duration(milliseconds: 1));
      if (_pageIdx + 1 >= _pageEnds.length) _pageEnds.add(nextEnd);
      _pageIdx++;
    } else if (nav == 'newer') {
      if (_pageIdx <= 0) return;
      _pageIdx--;
    } else {
      final end0 = _anchorEnd ?? DateTime.now();
      _windowStart = end0.subtract(Duration(hours: _hours));
      _pageEnds
        ..clear()
        ..add(end0);
      _pageIdx = 0;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    _thumbGate.reset();
    try {
      final page = await widget.api.listClips(
        widget.session,
        cameraIds: _cameraIds,
        start: _windowStart!,
        end: _pageEnds[_pageIdx],
        type: _type,
        limit: _clipsPageSize,
      );
      if (!mounted) return;
      _oldestShown = page.clips.isNotEmpty ? page.clips.last.startTs : null;
      setState(() {
        _clips = page.clips;
        _motionHighlightSeconds = page.motionHighlightSeconds;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _openClip(ClipDescriptor c) {
    setState(() {
      _playing = c;
      _viewedLocal.add(c.id);
    });
    widget.api.markClipViewed(widget.session, c.id).catchError((_) {});
  }

  Future<void> _pickWhen() async {
    final now = DateTime.now();
    final base = _anchorEnd ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;
    setState(() {
      _anchorEnd = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
    _load();
  }

  void _cycleDensity() {
    const order = [ClipsDensity.compact, ClipsDensity.normal, ClipsDensity.large];
    final next = order[(order.indexOf(_density) + 1) % order.length];
    setState(() => _density = next);
    _persistPrefs();
  }

  double _tileExtent() {
    switch (_density) {
      case ClipsDensity.compact:
        return 160;
      case ClipsDensity.normal:
        return 220;
      case ClipsDensity.large:
        return 320;
    }
  }

  void _filterToCamera(String cameraId) {
    if (cameraId == _cameraId) return;
    setState(() => _cameraId = cameraId);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: const Color(0xFF17181C),
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Column(
                children: [
                  _buildFilterBar(context),
                  Expanded(child: _buildBody(context)),
                  _buildPager(context),
                ],
              ),
            ),
          ),
          if (_playing != null)
            _ClipPlayer(
              key: ValueKey(_playing!.id),
              api: widget.api,
              session: widget.session,
              clip: _playing!,
              motionHighlightSeconds: _motionHighlightSeconds,
              onClose: () => setState(() => _playing = null),
              onViewOnTimeline: widget.onViewOnTimeline == null
                  ? null
                  : () {
                      final c = _playing!;
                      setState(() => _playing = null);
                      widget.onViewOnTimeline!(c.cameraId, c.startTs);
                    },
            ),
        ],
      ),
    );

    // Number-key hotkeys filter the clips list to the assigned camera.
    final hk = widget.hotkeys;
    if (hk == null) return scaffold;
    return GlobalHotkeysListener(
      store: hk,
      cameras: widget.cameras,
      autofocus: true,
      onGoToCamera: _filterToCamera,
      child: scaffold,
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF1E2026),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          _TypeToggle(
            value: _type,
            onChanged: (v) {
              setState(() => _type = v);
              _load();
            },
          ),
          DropdownButton<String?>(
            value: _cameraId,
            dropdownColor: const Color(0xFF23252C),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem(value: null, child: Text('All cameras')),
              for (final cam in widget.cameras)
                DropdownMenuItem(value: cam.id, child: Text(cam.name)),
            ],
            onChanged: (v) {
              setState(() => _cameraId = v);
              _load();
            },
          ),
          DropdownButton<int>(
            value: _hours,
            dropdownColor: const Color(0xFF23252C),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            underline: const SizedBox.shrink(),
            items: [
              for (final e in _rangeOptions.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _hours = v);
              _persistPrefs();
              _load();
            },
          ),
          TextButton.icon(
            onPressed: _pickWhen,
            icon: const Icon(Icons.event, size: 16, color: Colors.white70),
            label: Text(
              _anchorEnd == null ? 'Jump to…' : _fmtDateTime(_anchorEnd!),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          if (_anchorEnd != null)
            TextButton(
              onPressed: () {
                setState(() => _anchorEnd = null);
                _load();
              },
              child: const Text('Now', style: TextStyle(fontSize: 12)),
            ),
          IconButton(
            tooltip: 'Tiles: ${_density.name}',
            onPressed: _cycleDensity,
            icon: const Icon(Icons.grid_view, color: Colors.white70, size: 18),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh, color: Colors.white70, size: 18),
          ),
          if (!_loading)
            Text(
              '${_clips.length} clip${_clips.length == 1 ? '' : 's'}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _clips.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          "Couldn't load clips: $_error",
          style: const TextStyle(color: Colors.redAccent),
        ),
      );
    }
    if (_clips.isEmpty) {
      return const Center(
        child: Text('No clips in this window.', style: TextStyle(color: Colors.white38)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _tileExtent(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.35,
      ),
      itemCount: _clips.length,
      itemBuilder: (context, i) {
        final c = _clips[i];
        return _ClipCard(
          key: ValueKey(c.id),
          clip: c,
          api: widget.api,
          session: widget.session,
          gate: _thumbGate,
          viewed: c.viewed || _viewedLocal.contains(c.id),
          onTap: () => _openClip(c),
        );
      },
    );
  }

  Widget _buildPager(BuildContext context) {
    if (!_hasOlder && !_hasNewer) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: _hasNewer ? () => _load(nav: 'newer') : null,
            child: const Text('◀ Newer'),
          ),
          const SizedBox(width: 16),
          Text('Page ${_pageIdx + 1}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(width: 16),
          TextButton(
            onPressed: _hasOlder ? () => _load(nav: 'older') : null,
            child: const Text('Older ▶'),
          ),
        ],
      ),
    );
  }
}

// ─── filter widgets ───────────────────────────────────────────────────────

class _TypeToggle extends StatelessWidget {
  const _TypeToggle({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(String v, String label) {
      final active = value == v;
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: active,
          onSelected: (_) => onChanged(v),
          labelStyle: TextStyle(
            fontSize: 12,
            color: active ? Colors.black : Colors.white70,
          ),
          selectedColor: Colors.cyanAccent,
          backgroundColor: const Color(0xFF2A2D35),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [seg('all', 'All'), seg('detection', 'Detection'), seg('motion', 'Motion')],
    );
  }
}

// ─── clip card + lazy thumbnail ────────────────────────────────────────────

/// Small process-wide LRU-ish thumbnail byte cache so revisiting a page (or
/// scrolling back up) doesn't re-fetch. Bounded so a long browsing session
/// doesn't grow unbounded.
final Map<String, Uint8List> _thumbCache = {};
final List<String> _thumbCacheOrder = [];
const _thumbCacheMax = 500;

void _cacheThumb(String id, Uint8List bytes) {
  if (!_thumbCache.containsKey(id)) {
    _thumbCacheOrder.add(id);
    if (_thumbCacheOrder.length > _thumbCacheMax) {
      final evict = _thumbCacheOrder.removeAt(0);
      _thumbCache.remove(evict);
    }
  }
  _thumbCache[id] = bytes;
}

/// Bounded-concurrency gate for thumbnail loads (mirrors clipsPumpThumbQueue's
/// CLIPS_THUMB_CONCURRENCY-in-flight cap). `reset()` releases any waiters
/// (called on a fresh page load so a stale page's queued loads don't linger).
class _ConcurrencyGate {
  _ConcurrencyGate(this.max);
  final int max;
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  void reset() {
    _active = 0;
    for (final c in _waiters) {
      if (!c.isCompleted) c.complete();
    }
    _waiters.clear();
  }

  Future<void> run(Future<void> Function() task) async {
    if (_active >= max) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;
    try {
      await task();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        final next = _waiters.removeAt(0);
        if (!next.isCompleted) next.complete();
      }
    }
  }
}

class _ClipCard extends StatefulWidget {
  const _ClipCard({
    super.key,
    required this.clip,
    required this.api,
    required this.session,
    required this.gate,
    required this.viewed,
    required this.onTap,
  });

  final ClipDescriptor clip;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final bool viewed;
  final VoidCallback onTap;

  @override
  State<_ClipCard> createState() => _ClipCardState();
}

class _ClipCardState extends State<_ClipCard> {
  Uint8List? _bytes;
  bool _requested = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(covariant _ClipCard old) {
    super.didUpdateWidget(old);
    if (old.clip.id != widget.clip.id) {
      _bytes = null;
      _requested = false;
      _maybeLoad();
    }
  }

  void _maybeLoad() {
    final cached = _thumbCache[widget.clip.id];
    if (cached != null) {
      _bytes = cached;
      return;
    }
    if (_requested) return;
    _requested = true;
    widget.gate.run(_load);
  }

  Future<void> _load() async {
    if (_disposed) return;
    final url = await widget.api.mediaUrlForCamera(
      widget.session,
      widget.clip.cameraId,
      widget.clip.thumbnailUrl,
    );
    if (url == null || _disposed) return; // no JWT fallback — stays blank
    try {
      final resp = await http.get(Uri.parse(url));
      if (_disposed || resp.statusCode != 200) return;
      _cacheThumb(widget.clip.id, resp.bodyBytes);
      if (mounted) setState(() => _bytes = resp.bodyBytes);
    } catch (_) {
      // leave the black placeholder
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final dur = c.durationMs > 0 ? '${(c.durationMs / 1000).round()}s' : null;
    final badge = c.kind == 'motion' ? 'Motion' : (c.label.isEmpty ? 'Detection' : c.label);
    return InkWell(
      onTap: widget.onTap,
      child: Opacity(
        opacity: widget.viewed ? 0.55 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: Colors.black),
                    if (_bytes != null)
                      Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true),
                    Positioned(left: 4, top: 4, child: _Chip(badge)),
                    if (dur != null) Positioned(right: 4, bottom: 4, child: _Chip(dur)),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.cameraName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    _fmtDateTime(c.startTs),
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 10)),
    );
  }
}

// ─── in-app clip player ─────────────────────────────────────────────────

/// Full-screen clip player overlay: digital zoom/pan (wheel/drag/double-tap),
/// auto zoom-to-motion-bbox highlight, quality toggle (preview/full), a
/// load watchdog that retries a stalled clip, snapshot-to-PNG, and
/// bookmark-this-moment. Mirrors clipsPlay/clipsArmWatchdog/clipsApplyZoom in
/// the old client (app.js ~9730-10020).
class _ClipPlayer extends StatefulWidget {
  const _ClipPlayer({
    super.key,
    required this.api,
    required this.session,
    required this.clip,
    required this.motionHighlightSeconds,
    required this.onClose,
    this.onViewOnTimeline,
  });

  final CrumbApi api;
  final Session session;
  final ClipDescriptor clip;
  final int motionHighlightSeconds;
  final VoidCallback onClose;
  final VoidCallback? onViewOnTimeline;

  @override
  State<_ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<_ClipPlayer> {
  Player? _player;
  VideoController? _controller;
  String _quality = 'preview';
  int _loadAttempt = 0;
  Timer? _watchdog;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int?>? _widthSub;
  bool _highlighted = false;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  bool _userZoomed = false;
  Timer? _autoZoomTimer;
  Size _paneSize = const Size(640, 360);
  Offset? _dragStart;
  Offset? _dragStartOffset;

  bool _qualityBusy = false;
  String? _toastMsg;
  Timer? _toastTimer;
  String? _error;

  /// Key on the video pane's SizedBox so wheel-zoom can map a global pointer
  /// position to pane-local coordinates (mirrors `video.getBoundingClientRect()`
  /// in the old client's wheel handler).
  final GlobalKey _paneKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _open('preview', resetAttempt: true);
  }

  String _clipRelUrl(String quality, {int? retry}) {
    final id = Uri.encodeComponent(widget.clip.id);
    final r = retry != null ? '&_r=$retry' : '';
    return '/clip/$id/clip.mp4?q=$quality$r';
  }

  Future<void> _open(String quality, {bool resetAttempt = false, int? retry}) async {
    if (resetAttempt) _loadAttempt = 0;
    final url = await widget.api.mediaUrlForCamera(
      widget.session,
      widget.clip.cameraId,
      _clipRelUrl(quality, retry: retry),
    );
    if (!mounted) return;
    if (url == null) {
      setState(() => _error = 'Could not authorize this clip.');
      return;
    }
    var player = _player;
    if (player == null) {
      player = Player();
      final p = player.platform;
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
      _playingSub = player.stream.playing.listen((playing) {
        if (playing) _watchdog?.cancel();
      });
      _widthSub = player.stream.width.listen((w) {
        if (w != null && w > 0 && !_highlighted) {
          _highlighted = true;
          _maybeHighlight();
        }
      });
      final controller = VideoController(player);
      setState(() {
        _player = player;
        _controller = controller;
      });
    }
    await player.open(Media(url));
    await player.play();
    _armWatchdog();
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_clipLoadTimeout, () {
      if (!mounted) return;
      final st = _player?.state;
      final playing = st != null && st.playing && st.position > Duration.zero;
      if (playing) return;
      _retryLoad();
    });
  }

  Future<void> _retryLoad() async {
    _watchdog?.cancel();
    if (_loadAttempt >= _clipMaxRetries) {
      _toast('Clip is slow to load — try reopening it');
      return;
    }
    _loadAttempt++;
    _toast('Retrying clip…');
    final at = _player?.state.position ?? Duration.zero;
    final url = await widget.api.mediaUrlForCamera(
      widget.session,
      widget.clip.cameraId,
      _clipRelUrl(_quality, retry: _loadAttempt),
    );
    if (url == null || !mounted) return;
    await _player?.open(Media(url));
    if (at > Duration.zero) {
      try {
        await _player?.seek(at);
      } catch (_) {}
    }
    await _player?.play();
    _armWatchdog();
  }

  void _maybeHighlight() {
    if (widget.motionHighlightSeconds <= 0) return;
    if (widget.clip.kind != 'motion') return;
    final bb = widget.clip.motionBbox;
    if (bb == null) return;
    if (_userZoomed) return;
    if (!_zoomToBbox(bb, animate: true)) return;
    _autoZoomTimer = Timer(Duration(seconds: widget.motionHighlightSeconds), () {
      if (!mounted || _userZoomed) return;
      _applyZoom(1.0, Offset.zero);
    });
  }

  void _applyZoom(double s, Offset offset) {
    s = s.clamp(1.0, _clipZoomMax);
    final maxX = (s - 1) * _paneSize.width / 2;
    final maxY = (s - 1) * _paneSize.height / 2;
    final clamped = Offset(
      offset.dx.clamp(-maxX, maxX),
      offset.dy.clamp(-maxY, maxY),
    );
    if (!mounted) return;
    setState(() {
      _scale = s;
      _offset = clamped;
    });
  }

  bool _zoomToBbox(List<double> bb, {bool animate = false}) {
    if (bb.length != 4) return false;
    final bx = bb[0], by = bb[1], bw = bb[2], bh = bb[3];
    final region = math.max(bw, bh);
    if (!(region > 0) || region > 0.7) return false;
    final s = math.min(4.0, math.max(1.4, 0.9 / region));
    final cx = bx + bw / 2, cy = by + bh / 2;
    // The bbox is in VIDEO-frame fractions, but the video is drawn
    // BoxFit.contain inside the pane — so it's letterboxed when the video's
    // aspect differs from the pane's. Map the bbox centre through the actual
    // fitted display rect, otherwise the zoom lands off to the side.
    final pw = _paneSize.width, ph = _paneSize.height;
    final vw = (_player?.state.width ?? 0).toDouble();
    final vh = (_player?.state.height ?? 0).toDouble();
    var dispW = pw, dispH = ph, ox = 0.0, oy = 0.0;
    if (vw > 0 && vh > 0 && pw > 0 && ph > 0) {
      final videoAspect = vw / vh, paneAspect = pw / ph;
      if (videoAspect > paneAspect) {
        dispW = pw;
        dispH = pw / videoAspect;
      } else {
        dispH = ph;
        dispW = ph * videoAspect;
      }
      ox = (pw - dispW) / 2;
      oy = (ph - dispH) / 2;
    }
    final pointX = ox + cx * dispW;
    final pointY = oy + cy * dispH;
    // Center-scaled transform: offset moves the target point to the pane centre.
    _applyZoom(s, Offset(-s * (pointX - pw / 2), -s * (pointY - ph / 2)));
    return true;
  }

  void _resetZoom() {
    _autoZoomTimer?.cancel();
    _userZoomed = false;
    _applyZoom(1.0, Offset.zero);
  }

  void _takeOverZoom() {
    _autoZoomTimer?.cancel();
    _userZoomed = true;
  }

  Future<void> _toggleQuality() async {
    if (_qualityBusy || _player == null) return;
    final next = _quality == 'preview' ? 'full' : 'preview';
    final at = _player!.state.position;
    final wasPlaying = _player!.state.playing;
    setState(() {
      _quality = next;
      _qualityBusy = true;
    });
    final url = await widget.api.mediaUrlForCamera(
      widget.session,
      widget.clip.cameraId,
      _clipRelUrl(next),
    );
    if (url == null || !mounted) {
      if (mounted) setState(() => _qualityBusy = false);
      return;
    }
    await _player!.open(Media(url));
    try {
      await _player!.seek(at);
    } catch (_) {}
    if (wasPlaying) {
      await _player!.play();
    } else {
      await _player!.pause();
    }
    if (mounted) setState(() => _qualityBusy = false);
  }

  Future<void> _snapshot() async {
    final bytes = await _player?.screenshot(format: 'image/png');
    if (bytes == null) {
      _toast('Snapshot unavailable — video not ready');
      return;
    }
    final cam = widget.clip.cameraName.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    try {
      final loc = await getSaveLocation(
        suggestedName: 'crumb_${cam.isEmpty ? "clip" : cam}_$stamp.png',
      );
      if (loc == null) return; // user cancelled
      final file = XFile.fromData(bytes, mimeType: 'image/png', name: 'snapshot.png');
      await file.saveTo(loc.path);
      _toast('Snapshot saved');
    } catch (_) {
      _toast('Snapshot failed');
    }
  }

  Future<void> _bookmark() async {
    final label = widget.clip.kind == 'motion'
        ? 'Motion'
        : (widget.clip.label.isEmpty ? 'Detection' : widget.clip.label);
    final desc = await showDialog<String>(
      context: context,
      builder: (ctx) => _BookmarkDialog(initial: label),
    );
    if (desc == null || !mounted) return; // cancelled
    try {
      await widget.api.createBookmark(
        widget.session,
        cameraId: widget.clip.cameraId,
        ts: widget.clip.startTs,
        description: desc,
      );
      _toast('Bookmark saved');
    } catch (_) {
      _toast('Bookmark failed');
    }
  }

  void _toast(String msg) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toastMsg = msg);
    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _toastMsg = null);
    });
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _autoZoomTimer?.cancel();
    _toastTimer?.cancel();
    _playingSub?.cancel();
    _widthSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final label = c.kind == 'motion' ? 'Motion' : (c.label.isEmpty ? 'Detection' : c.label);
    return Positioned.fill(
      // FocusScope (not plain Focus) so this overlay traps keyboard focus over
      // the clips screen's own autofocused hotkey listener — otherwise Esc can
      // be swallowed by the ancestor and never close the player.
      child: FocusScope(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            widget.onClose();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Material(
          color: Colors.black.withValues(alpha: 0.92),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _paneSize = Size(constraints.maxWidth, constraints.maxHeight * 0.82);
            return Stack(
              children: [
                Positioned.fill(child: _buildPlayerColumn(context, c, label)),
                if (_toastMsg != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 48,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _toastMsg!,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      ),
    );
  }

  Widget _buildPlayerColumn(BuildContext context, ClipDescriptor c, String label) {
    return Column(
              children: [
                // Title bar.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$label — ${c.cameraName}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _qualityBusy ? null : _toggleQuality,
                        icon: Icon(
                          Icons.high_quality,
                          size: 16,
                          color: _quality == 'full' ? Colors.cyanAccent : Colors.white70,
                        ),
                        label: Text(
                          _quality == 'full' ? 'Full' : 'Preview',
                          style: TextStyle(
                            fontSize: 12,
                            color: _quality == 'full' ? Colors.cyanAccent : Colors.white70,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Snapshot',
                        onPressed: _snapshot,
                        icon: const Icon(Icons.camera_alt_outlined, color: Colors.white70, size: 20),
                      ),
                      IconButton(
                        tooltip: 'Bookmark',
                        onPressed: _bookmark,
                        icon: const Icon(Icons.bookmark_add_outlined, color: Colors.white70, size: 20),
                      ),
                      if (widget.onViewOnTimeline != null)
                        IconButton(
                          tooltip: 'View on timeline',
                          onPressed: widget.onViewOnTimeline,
                          icon: const Icon(
                            Icons.timeline,
                            color: Colors.white70,
                            size: 20,
                          ),
                        ),
                      IconButton(
                        tooltip: 'Close (Esc)',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, color: Colors.white70, size: 22),
                      ),
                    ],
                  ),
                ),
                // Video pane with zoom/pan gestures.
                Expanded(
                  child: Center(
                    child: SizedBox(
                      key: _paneKey,
                      width: _paneSize.width,
                      height: _paneSize.height,
                      child: _error != null
                          ? Center(
                              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                            )
                          : _controller == null
                              ? const Center(child: CircularProgressIndicator())
                              : Listener(
                                  onPointerSignal: (e) {
                                    if (e is PointerScrollEvent) {
                                      _takeOverZoom();
                                      final factor = e.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15;
                                      final ns = (_scale * factor).clamp(1.0, _clipZoomMax);
                                      if (ns == 1.0) {
                                        _resetZoom();
                                        return;
                                      }
                                      final box =
                                          _paneKey.currentContext?.findRenderObject() as RenderBox?;
                                      final local = box?.globalToLocal(e.position) ??
                                          Offset(_paneSize.width / 2, _paneSize.height / 2);
                                      final px = local.dx - _paneSize.width / 2;
                                      final py = local.dy - _paneSize.height / 2;
                                      final k = ns / _scale;
                                      _applyZoom(
                                        ns,
                                        Offset(px - (px - _offset.dx) * k, py - (py - _offset.dy) * k),
                                      );
                                    }
                                  },
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onDoubleTap: _resetZoom,
                                    onPanStart: (d) {
                                      if (_scale <= 1.0) return;
                                      _dragStart = d.globalPosition;
                                      _dragStartOffset = _offset;
                                    },
                                    onPanUpdate: (d) {
                                      if (_scale <= 1.0 || _dragStart == null) return;
                                      _takeOverZoom();
                                      final delta = d.globalPosition - _dragStart!;
                                      _applyZoom(_scale, _dragStartOffset! + delta);
                                    },
                                    child: ClipRect(
                                      child: Transform(
                                        transform: Matrix4.identity()
                                          ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                                          ..scaleByDouble(_scale, _scale, 1, 1),
                                        alignment: Alignment.center,
                                        child: Video(
                                          controller: _controller!,
                                          controls: NoVideoControls,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
    );
  }
}

class _BookmarkDialog extends StatefulWidget {
  const _BookmarkDialog({required this.initial});
  final String initial;

  @override
  State<_BookmarkDialog> createState() => _BookmarkDialogState();
}

class _BookmarkDialogState extends State<_BookmarkDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add bookmark'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Description'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ─── small helpers ──────────────────────────────────────────────────────

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _fmtDateTime(DateTime t) {
  final local = t.toLocal();
  final h24 = local.hour;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  final mm = local.minute.toString().padLeft(2, '0');
  return '${_months[local.month - 1]} ${local.day}, $h12:$mm $ampm';
}
