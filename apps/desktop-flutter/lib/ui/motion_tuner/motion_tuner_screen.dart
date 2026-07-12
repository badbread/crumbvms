// Server > Motion tuning: per-camera live activity heatmap over the sub
// stream, exclusion-mask painting, threshold slider, and the additive
// detector-source picker (pixel algorithm / Frigate / Home Assistant).
//
// Ports the old Tauri client's inline Motion Tuner (apps/desktop/src/app.js —
// `mtOpen`/`mtPoll`/`mtDrawGrid`/`mtRenderMeter`/`mtCellsToMask`/`mtSave`/
// `mtApplyThreshold`/`mtSyncMotionSource`/`mtApplyMotionConfig`, ~line 12279
// onward) against the real endpoints: `GET /cameras/{id}/motion-grid`
// (services/api/src/playback.rs) for the live heatmap + meter, admin-only
// `GET/PUT /config/cameras/{id}` (services/api/src/config_routes.rs) for the
// exclusion mask / authoring-grid size / detector toggles (see
// lib/api/motion_tuner_api.dart), and the EXISTING
// `ServerDashboardApi.updateCameraPolicy` (lib/api/server_dashboard_api.dart,
// `PUT /config/cameras/{id}/policy`) for the threshold + sensitivity — reused
// rather than re-implemented.
//
// Media: the live backdrop is the authenticated fMP4 proxy
// (`GET /live/{id}/stream.mp4?stream=sub`) played through media_kit/libmpv
// (same engine as the wall — mpv happily demuxes an http fMP4 stream, it
// doesn't need to be an in-DOM <video>/MSE element the way the old webview
// client required). The still `frame.jpg` snapshot is a polled FALLBACK shown
// only if the live stream doesn't produce a frame quickly. Both URLs carry a
// short-lived, single-camera scoped `?token=` media claim from
// [MediaTokenCache] — never the bearer JWT.
//
// NOTE (integration): this screen is admin-only (the config endpoints 403 for
// non-admin accounts) — gate its nav entry the same way AdminConsoleScreen is
// gated, and route in [MediaTokenCache] from the signed-in session (see
// lib/api/media_token_cache.dart) — construct one per session, don't build a
// fresh one here.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/media_token_cache.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/motion_tuner_api.dart';
import 'package:crumb_desktop/api/server_dashboard_api.dart';
import 'package:crumb_desktop/api/server_dashboard_models.dart';

/// Authoring-grid resolutions the operator can pick for painting exclusion
/// zones — mirrors the old client's `VALID_GRIDS` (app.js `mtOpen`).
const List<(int, int)> kMotionTunerGridSizes = [
  (8, 5),
  (16, 9),
  (24, 14),
  (32, 18),
  (48, 27),
];

/// Per-pixel-algorithm one-liner shown beside the picker (`MT_ALGO_NOTES`,
/// app.js).
const Map<String, String> kMotionAlgoNotes = {
  'census': 'illumination-invariant (default)',
  'framediff': 'most sensitive; trips on lighting',
  'mog2': 'multimodal background (trees/signs)',
  'opticalflow': 'true movement only',
  'ensemble': 'Census + MOG2 (most robust, ~2-3x CPU)',
};

const List<String> kMotionAlgorithms = [
  'census',
  'framediff',
  'mog2',
  'opticalflow',
  'ensemble',
];

/// Top-level screen: a camera picker + the tuner body for whichever camera is
/// selected. Give the body a fresh key per camera so switching cameras tears
/// down and rebuilds all polling/player state from scratch (mirrors the old
/// client's `mtOpen` resetting `mtState` wholesale on every open).
class MotionTunerScreen extends StatefulWidget {
  const MotionTunerScreen({
    super.key,
    required this.api,
    required this.session,
    required this.mediaTokenCache,
    required this.cameras,
    this.initialCameraId,
  });

  final CrumbApi api;
  final Session session;
  final MediaTokenCache mediaTokenCache;

  /// Cameras eligible for tuning (typically the full viewer-visible list).
  final List<Camera> cameras;

  /// Pre-select a camera (e.g. deep-linked from a camera's context menu —
  /// mirrors the old client's `srv-motion-tuner-btn` wiring).
  final String? initialCameraId;

  @override
  State<MotionTunerScreen> createState() => _MotionTunerScreenState();
}

class _MotionTunerScreenState extends State<MotionTunerScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    final cams = widget.cameras;
    _selectedId =
        widget.initialCameraId ?? (cams.isNotEmpty ? cams.first.id : null);
  }

  @override
  Widget build(BuildContext context) {
    final cams = widget.cameras;
    final selected = cams.where((c) => c.id == _selectedId).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Motion tuning'),
        actions: [
          if (cams.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: DropdownButton<String>(
                  value: _selectedId,
                  dropdownColor: Theme.of(context).colorScheme.surface,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final c in cams)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) => setState(() => _selectedId = v),
                ),
              ),
            ),
        ],
      ),
      body: cams.isEmpty
          ? const Center(child: Text('No cameras available to tune.'))
          : selected == null
          ? const Center(child: CircularProgressIndicator())
          : _MotionTunerBody(
              key: ValueKey('mt-${selected.id}'),
              api: widget.api,
              session: widget.session,
              mediaTokenCache: widget.mediaTokenCache,
              camera: selected,
            ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _MotionTunerBody extends StatefulWidget {
  const _MotionTunerBody({
    super.key,
    required this.api,
    required this.session,
    required this.mediaTokenCache,
    required this.camera,
  });

  final CrumbApi api;
  final Session session;
  final MediaTokenCache mediaTokenCache;
  final Camera camera;

  @override
  State<_MotionTunerBody> createState() => _MotionTunerBodyState();
}

class _DragState {
  _DragState({
    required this.ax,
    required this.ay,
    required this.cx,
    required this.cy,
    required this.erase,
  });
  int ax, ay, cx, cy;
  final bool erase;
}

class _MotionTunerBodyState extends State<_MotionTunerBody> {
  bool _loading = true;
  String? _loadError;
  CameraMotionConfig? _config;

  // Exclusion-authoring grid (operator-adjustable).
  int _cols = 16;
  int _rows = 9;
  final Set<String> _excluded = {};

  // Heatmap grid (recorder-fixed resolution — independent of the authoring
  // grid; set by each poll).
  MotionGridSnapshot? _grid;
  Timer? _pollTimer;

  // Live video backdrop.
  Player? _player;
  VideoController? _controller;
  bool _videoOk = false;
  Timer? _videoWatchdog;
  StreamSubscription<int?>? _widthSub;
  double? _stageAspect;

  // Still-frame fallback.
  Timer? _snapshotTimer;
  String? _snapshotUrl;

  // Threshold + sensitivity (persisted via the existing policy patch).
  double _thresholdPct = 0.30; // % of frame, 0.05..5
  String _sensitivity = 'dynamic'; // "dynamic" | "manual"

  // Detector sources.
  bool _pixelEnabled = true;
  bool _frigateEnabled = false;
  bool _haEnabled = false;
  String _algorithm = 'census';

  // Drag/paint state.
  _DragState? _drag;
  final GlobalKey _stageKey = GlobalKey();

  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _snapshotTimer?.cancel();
    _videoWatchdog?.cancel();
    _widthSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final cfg = await widget.api.fetchCameraMotionConfig(
        widget.session,
        widget.camera.id,
      );
      var gc = cfg.motionGridCols ?? 16;
      var gr = cfg.motionGridRows ?? 9;
      if (!kMotionTunerGridSizes.contains((gc, gr))) {
        gc = 16;
        gr = 9;
      }
      _cols = gc;
      _rows = gr;
      _rectsToCells(cfg.motionMask);
      _thresholdPct = ((cfg.motionThreshold ?? 0.0030) * 100)
          .clamp(0.05, 5)
          .toDouble();
      _sensitivity = cfg.motionSensitivity;
      _pixelEnabled = cfg.motionPixelEnabled;
      _frigateEnabled = cfg.motionFrigateEnabled;
      _haEnabled = cfg.motionHaEnabled;
      _algorithm = cfg.motionAlgorithm;
      if (!mounted) return;
      setState(() {
        _config = cfg;
        _loading = false;
      });
      _startVideo(cfg);
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => _poll(),
      );
      unawaited(_poll());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Failed to load: $e';
      });
    }
  }

  Future<void> _poll() async {
    try {
      final g = await widget.api.fetchMotionGrid(
        widget.session,
        widget.camera.id,
      );
      if (!mounted || g == null || g.cols <= 0 || g.rows <= 0) return;
      setState(() => _grid = g);
    } catch (_) {
      /* transient — ignore, next tick retries */
    }
  }

  Future<void> _startVideo(CameraMotionConfig cfg) async {
    if (!cfg.hasSub) {
      _startSnapshotFallback();
      return;
    }
    final url = await widget.mediaTokenCache.mediaUrl(
      widget.camera.id,
      '/live/${Uri.encodeComponent(widget.camera.id)}/stream.mp4?stream=sub',
    );
    if (!mounted) return;
    if (url == null) {
      _startSnapshotFallback();
      return;
    }
    final player = Player();
    final controller = VideoController(player);
    final p = player.platform;
    if (p is NativePlayer) {
      for (final kv in const [
        ['hwdec', 'auto'],
        ['cache', 'yes'],
        ['demuxer-readahead-secs', '2.0'],
        ['demuxer-max-bytes', '32MiB'],
        ['demuxer-max-back-bytes', '1MiB'],
        ['network-timeout', '10'],
        ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
        ['mute', 'yes'],
      ]) {
        try {
          await p.setProperty(kv[0], kv[1]);
        } catch (_) {
          /* non-fatal */
        }
      }
    }
    _widthSub = player.stream.width.listen((w) {
      final h = player.state.height;
      if (w != null && w > 0 && h != null && h > 0 && mounted) {
        setState(() {
          _videoOk = true;
          _stageAspect = w / h;
        });
        _videoWatchdog?.cancel();
        _snapshotTimer?.cancel();
      }
    });
    try {
      await player.open(Media(url));
    } catch (_) {
      _startSnapshotFallback();
      return;
    }
    if (!mounted) {
      player.dispose();
      return;
    }
    setState(() {
      _player = player;
      _controller = controller;
    });
    // If the live stream produces no frame within ~6s, fall back to the still
    // frame (mirrors the old client's `mtState.videoWatchdog`).
    _videoWatchdog = Timer(const Duration(seconds: 6), () {
      if (!_videoOk && mounted) _startSnapshotFallback();
    });
  }

  void _startSnapshotFallback() {
    _refreshSnapshot();
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _refreshSnapshot(),
    );
  }

  Future<void> _refreshSnapshot() async {
    if (_videoOk) return;
    final base = await widget.mediaTokenCache.mediaUrl(
      widget.camera.id,
      '/cameras/${Uri.encodeComponent(widget.camera.id)}/frame.jpg',
    );
    if (!mounted || base == null || _videoOk) return;
    setState(() => _snapshotUrl = '$base&t=${DateTime.now().millisecondsSinceEpoch}');
  }

  // ── Exclusion mask <-> normalized rects (mtRectsToCells / mtCellsToMask) ──

  String _cellKey(int gx, int gy) => '$gx,$gy';

  void _rectsToCells(List<MaskRect> rects) {
    _excluded.clear();
    for (var gy = 0; gy < _rows; gy++) {
      for (var gx = 0; gx < _cols; gx++) {
        final cxN = (gx + 0.5) / _cols;
        final cyN = (gy + 0.5) / _rows;
        for (final r in rects) {
          if (cxN >= r[0] &&
              cxN < r[0] + r[2] &&
              cyN >= r[1] &&
              cyN < r[1] + r[3]) {
            _excluded.add(_cellKey(gx, gy));
            break;
          }
        }
      }
    }
  }

  List<MaskRect> _cellsToMask() {
    final rects = <MaskRect>[];
    for (var gy = 0; gy < _rows; gy++) {
      var runStart = -1;
      for (var gx = 0; gx <= _cols; gx++) {
        final on = gx < _cols && _excluded.contains(_cellKey(gx, gy));
        if (on && runStart < 0) {
          runStart = gx;
        } else if (!on && runStart >= 0) {
          final w = gx - runStart;
          rects.add([
            runStart / _cols,
            gy / _rows,
            w / _cols,
            1 / _rows,
          ]);
          runStart = -1;
        }
      }
    }
    return rects;
  }

  Future<void> _setGridDims(int cols, int rows) async {
    if (cols == _cols && rows == _rows) return;
    final rects = _cellsToMask(); // area at the OLD resolution
    setState(() {
      _cols = cols;
      _rows = rows;
      _rectsToCells(rects); // re-paint at the NEW resolution
    });
    // Persist the operator's chosen authoring-grid size (UI preference; the
    // recorder ignores it) — mirrors `mtPersistGrid`.
    try {
      final patch = MotionConfigPatch()
        ..motionGridCols(cols)
        ..motionGridRows(rows);
      await widget.api.updateCameraMotionConfig(
        widget.session,
        widget.camera.id,
        patch,
      );
    } catch (_) {
      /* non-fatal: grid still applies this session */
    }
  }

  Future<void> _saveMask() async {
    setState(() => _status = null);
    final mask = _cellsToMask();
    try {
      final patch = MotionConfigPatch()..motionMask(mask);
      final updated = await widget.api.updateCameraMotionConfig(
        widget.session,
        widget.camera.id,
        patch,
      );
      if (!mounted) return;
      setState(() {
        _config = updated;
        _status =
            'Motion mask saved (${mask.length} zone${mask.length == 1 ? '' : 's'})';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Save failed: $e');
    }
  }

  void _clearMask() {
    setState(() => _excluded.clear());
  }

  Future<void> _applyThreshold() async {
    try {
      final patch = PolicyPatch()
        ..motionSensitivity(_sensitivity)
        ..motionThreshold(_thresholdPct / 100);
      await widget.api.updateCameraPolicy(
        widget.session,
        widget.camera.id,
        patch,
      );
      if (!mounted) return;
      setState(() {
        _status = _sensitivity == 'dynamic'
            ? 'Motion sensitivity set to Auto (dynamic)'
            : 'Min object size set to ${_thresholdPct.toStringAsFixed(2)}% of frame';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Threshold save failed: $e');
    }
  }

  Future<void> _applyMotionConfig() async {
    try {
      final patch = MotionConfigPatch()
        ..motionPixelEnabled(_pixelEnabled)
        ..motionFrigateEnabled(_frigateEnabled)
        ..motionHaEnabled(_haEnabled)
        ..motionAlgorithm(_algorithm);
      final updated = await widget.api.updateCameraMotionConfig(
        widget.session,
        widget.camera.id,
        patch,
      );
      if (!mounted) return;
      setState(() {
        _config = updated;
        _status = 'Motion sources updated';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Save failed: $e');
    }
  }

  // ── Painting ────────────────────────────────────────────────────────────

  (int, int)? _cellFromLocal(Offset local, Size stageSize) {
    if (stageSize.width <= 0 || stageSize.height <= 0) return null;
    final gx = ((local.dx / stageSize.width) * _cols)
        .floor()
        .clamp(0, _cols - 1)
        .toInt();
    final gy = ((local.dy / stageSize.height) * _rows)
        .floor()
        .clamp(0, _rows - 1)
        .toInt();
    return (gx, gy);
  }

  Size? _stageSize() {
    final ctx = _stageKey.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    return box?.size;
  }

  void _onPointerDown(PointerDownEvent e) {
    final size = _stageSize();
    final cell = size == null ? null : _cellFromLocal(e.localPosition, size);
    if (cell == null) return;
    final erase = (e.buttons & kSecondaryMouseButton) != 0;
    setState(
      () => _drag = _DragState(
        ax: cell.$1,
        ay: cell.$2,
        cx: cell.$1,
        cy: cell.$2,
        erase: erase,
      ),
    );
  }

  void _onPointerMove(PointerMoveEvent e) {
    final drag = _drag;
    if (drag == null) return;
    final size = _stageSize();
    final cell = size == null ? null : _cellFromLocal(e.localPosition, size);
    if (cell == null) return;
    setState(() {
      drag.cx = cell.$1;
      drag.cy = cell.$2;
    });
  }

  void _onPointerUp(PointerEvent e) {
    final drag = _drag;
    if (drag == null) return;
    final x0 = math.min(drag.ax, drag.cx), x1 = math.max(drag.ax, drag.cx);
    final y0 = math.min(drag.ay, drag.cy), y1 = math.max(drag.ay, drag.cy);
    setState(() {
      if (x0 == x1 && y0 == y1) {
        final k = _cellKey(x0, y0);
        if (drag.erase) {
          _excluded.remove(k);
        } else if (_excluded.contains(k)) {
          _excluded.remove(k);
        } else {
          _excluded.add(k);
        }
      } else {
        for (var gy = y0; gy <= y1; gy++) {
          for (var gx = x0; gx <= x1; gx++) {
            final k = _cellKey(gx, gy);
            if (drag.erase) {
              _excluded.remove(k);
            } else {
              _excluded.add(k);
            }
          }
        }
      }
      _drag = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Text(_loadError!, style: const TextStyle(color: Colors.red)),
      );
    }
    final cfg = _config!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            cfg.name,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (_status != null)
            Text(_status!, style: const TextStyle(color: Colors.greenAccent)),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 8),

          // ── Live stage: video/snapshot backdrop + heatmap/exclusion overlay ──
          Center(
            child: ConstrainedBox(
              // Cap the stage to ~half the window height so the whole tuner
              // (stage + the controls below) fits the popup instead of the
              // full-width 16:9 stage eating the screen and forcing a scroll.
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.5,
              ),
              child: AspectRatio(
                aspectRatio: _stageAspect ?? (16 / 9),
                child: Container(
                  key: _stageKey,
                color: Colors.black,
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerUp,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_videoOk && _controller != null)
                        Video(
                          controller: _controller!,
                          controls: NoVideoControls,
                          fit: BoxFit.fill,
                        )
                      else if (_snapshotUrl != null)
                        Image.network(
                          _snapshotUrl!,
                          key: ValueKey(_snapshotUrl),
                          fit: BoxFit.fill,
                          errorBuilder: (_, __, ___) => const SizedBox(),
                        )
                      else
                        const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      CustomPaint(
                        painter: _MotionPainter(
                          grid: _grid,
                          cols: _cols,
                          rows: _rows,
                          excluded: _excluded,
                          drag: _drag,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Left-drag: exclude an area from motion. Right-drag: erase. '
            'Green = live motion (recorder detector). Red = excluded.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 12),

          // ── Live meter ──────────────────────────────────────────────────
          _MotionMeter(grid: _grid, sensitivity: _sensitivity, thresholdPct: _thresholdPct),
          const SizedBox(height: 20),

          // ── Threshold / sensitivity ────────────────────────────────────
          Text(
            'Sensitivity',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Row(
            children: [
              Checkbox(
                value: _sensitivity == 'dynamic',
                onChanged: !_pixelEnabled
                    ? null
                    : (v) {
                        setState(
                          () => _sensitivity = (v ?? true) ? 'dynamic' : 'manual',
                        );
                        unawaited(_applyThreshold());
                      },
              ),
              const Text('Auto (dynamic)'),
              const SizedBox(width: 16),
              Expanded(
                child: Slider(
                  value: _thresholdPct.clamp(0.05, 5).toDouble(),
                  min: 0.05,
                  max: 5,
                  divisions: 495,
                  label: '${_thresholdPct.toStringAsFixed(2)}%',
                  onChanged: (_sensitivity == 'dynamic' || !_pixelEnabled)
                      ? null
                      : (v) => setState(() {
                          _thresholdPct = v;
                          _sensitivity = 'manual';
                        }),
                  onChangeEnd: (_sensitivity == 'dynamic' || !_pixelEnabled)
                      ? null
                      : (_) => _applyThreshold(),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text('${_thresholdPct.toStringAsFixed(2)}%'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Exclusion authoring grid size ──────────────────────────────
          Row(
            children: [
              Text('Grid size', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 12),
              DropdownButton<(int, int)>(
                value: (_cols, _rows),
                items: [
                  for (final g in kMotionTunerGridSizes)
                    DropdownMenuItem(
                      value: g,
                      child: Text('${g.$1}×${g.$2}'),
                    ),
                ],
                onChanged: !_pixelEnabled
                    ? null
                    : (g) {
                        if (g != null) unawaited(_setGridDims(g.$1, g.$2));
                      },
              ),
              const Spacer(),
              TextButton(
                onPressed: !_pixelEnabled ? null : _clearMask,
                child: const Text('Clear'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: !_pixelEnabled ? null : _saveMask,
                child: const Text('Save exclusion mask'),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── Detector sources (additive: union of enabled sources) ──────
          Text('Motion sources', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'A camera records on the union of every enabled source.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pixel analysis'),
            subtitle: Text(kMotionAlgoNotes[_algorithm] ?? ''),
            value: _pixelEnabled,
            onChanged: (v) {
              setState(() => _pixelEnabled = v ?? true);
              unawaited(_applyMotionConfig());
            },
          ),
          if (_pixelEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 32, bottom: 8),
              child: DropdownButton<String>(
                value: _algorithm,
                items: [
                  for (final a in kMotionAlgorithms)
                    DropdownMenuItem(value: a, child: Text(a)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _algorithm = v);
                  unawaited(_applyMotionConfig());
                },
              ),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Frigate detections'),
            value: _frigateEnabled,
            onChanged: (v) {
              setState(() => _frigateEnabled = v ?? false);
              unawaited(_applyMotionConfig());
            },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Home Assistant'),
            value: _haEnabled,
            onChanged: (v) {
              setState(() => _haEnabled = v ?? false);
              unawaited(_applyMotionConfig());
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Live motion meter: fill = the recorder's current largest-blob score, mark
/// = the effective floor it triggers on — the SAME quantities the recorder
/// uses, per `mtRenderMeter` (app.js).
class _MotionMeter extends StatelessWidget {
  const _MotionMeter({
    required this.grid,
    required this.sensitivity,
    required this.thresholdPct,
  });

  final MotionGridSnapshot? grid;
  final String sensitivity;
  final double thresholdPct;

  @override
  Widget build(BuildContext context) {
    final g = grid;
    if (g == null) {
      return const Text(
        'waiting for recorder…',
        style: TextStyle(color: Colors.white54),
      );
    }
    final scorePct = g.score * 100;
    final floorPct = sensitivity == 'dynamic' ? g.threshold * 100 : thresholdPct;
    final fullScale = math.max(1.0, floorPct * 4.5);
    final over = scorePct >= floorPct;
    final fillFrac = (scorePct / fullScale).clamp(0.0, 1.0).toDouble();
    final markFrac = (floorPct / fullScale).clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 14,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              FractionallySizedBox(
                widthFactor: fillFrac,
                child: Container(
                  decoration: BoxDecoration(
                    color: over ? Colors.redAccent : Colors.cyanAccent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Align(
                alignment: Alignment(markFrac * 2 - 1, 0),
                child: Container(width: 2, color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'motion ${scorePct.toStringAsFixed(2)}%  ·  floor '
          '${floorPct.toStringAsFixed(2)}%'
          '${sensitivity == 'dynamic' ? ' (auto)' : ''}',
          style: TextStyle(
            fontSize: 12,
            color: over ? Colors.redAccent : Colors.white54,
          ),
        ),
      ],
    );
  }
}

/// Draws the heatmap (recorder's fixed grid), the exclusion cells + grid
/// lines (operator's authoring grid), and the in-progress drag preview.
/// Mirrors `mtDrawGrid` (app.js).
class _MotionPainter extends CustomPainter {
  _MotionPainter({
    required this.grid,
    required this.cols,
    required this.rows,
    required this.excluded,
    required this.drag,
  });

  final MotionGridSnapshot? grid;
  final int cols;
  final int rows;
  final Set<String> excluded;
  final _DragState? drag;

  @override
  void paint(Canvas canvas, Size size) {
    final g = grid;
    if (g != null && g.cols > 0 && g.rows > 0) {
      final hcw = size.width / g.cols;
      final hch = size.height / g.rows;
      for (var gy = 0; gy < g.rows; gy++) {
        for (var gx = 0; gx < g.cols; gx++) {
          final intensity = g.cellAt(gx, gy);
          if (intensity > 0.5) {
            final a = (0.5 + (intensity / 100) * 0.5).clamp(0.0, 1.0).toDouble();
            final paint = Paint()..color = Color.fromRGBO(40, 210, 90, a);
            canvas.drawRect(
              Rect.fromLTWH(gx * hcw, gy * hch, hcw, hch),
              paint,
            );
          }
        }
      }
    }

    if (cols > 0 && rows > 0) {
      final cw = size.width / cols;
      final ch = size.height / rows;
      final fill = Paint()..color = const Color.fromRGBO(239, 68, 68, 0.32);
      final stroke = Paint()
        ..color = const Color.fromRGBO(239, 68, 68, 0.8)
        ..strokeWidth = 1;
      for (var gy = 0; gy < rows; gy++) {
        for (var gx = 0; gx < cols; gx++) {
          if (excluded.contains('$gx,$gy')) {
            final x = gx * cw, y = gy * ch;
            canvas.drawRect(Rect.fromLTWH(x, y, cw, ch), fill);
            canvas.drawLine(Offset(x, y + ch), Offset(x + cw, y), stroke);
          }
        }
      }

      final gridLine = Paint()
        ..color = const Color.fromRGBO(255, 255, 255, 0.12)
        ..strokeWidth = 1;
      for (var gx = 1; gx < cols; gx++) {
        canvas.drawLine(
          Offset(gx * cw, 0),
          Offset(gx * cw, size.height),
          gridLine,
        );
      }
      for (var gy = 1; gy < rows; gy++) {
        canvas.drawLine(
          Offset(0, gy * ch),
          Offset(size.width, gy * ch),
          gridLine,
        );
      }

      final d = drag;
      if (d != null) {
        final x0 = math.min(d.ax, d.cx) * cw;
        final y0 = math.min(d.ay, d.cy) * ch;
        final x1 = (math.max(d.ax, d.cx) + 1) * cw;
        final y1 = (math.max(d.ay, d.cy) + 1) * ch;
        final rect = Rect.fromLTRB(x0, y0, x1, y1);
        if (d.erase) {
          canvas.drawRect(
            rect,
            Paint()..color = const Color.fromRGBO(245, 158, 11, 0.20),
          );
        }
        canvas.drawRect(
          rect,
          Paint()
            ..color = d.erase
                ? const Color.fromRGBO(245, 158, 11, 0.95)
                : const Color.fromRGBO(255, 255, 255, 0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  // `excluded` is mutated in place and re-passed by reference each build, so
  // reference/value equality can't detect a paint-relevant change here —
  // always repaint. Cheap: this canvas is small and already redrawn on every
  // 400ms poll tick.
  @override
  bool shouldRepaint(covariant _MotionPainter oldDelegate) => true;
}
