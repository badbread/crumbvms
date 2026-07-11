// The live wall — the real P1 headline surface. A grid of live camera panes,
// each pulling its own go2rtc restream via media_kit/libmpv. Each tile
// self-manages its stream-URL fetch + player lifecycle so one camera's slow
// load or failure never blocks the others.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:flutter/gestures.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/src/rust/api/host.dart';
import 'package:crumb_desktop/ui/live_status/live_status_badges.dart';
import 'package:crumb_desktop/ui/live_status/live_status_controller.dart';

class WallScreen extends StatefulWidget {
  const WallScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.onLogout,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;
  final VoidCallback onLogout;

  @override
  State<WallScreen> createState() => _WallScreenState();
}

class _WallScreenState extends State<WallScreen> {
  Timer? _statsTimer;
  HostStats? _stats;
  double? _cpuPercent;
  double? _lastCpuTime;
  DateTime? _lastSample;

  Camera? _maximized;

  late final LiveStatusController _liveStatus;

  List<Camera> get _shown =>
      widget.cameras.where((c) => c.enabled).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _statsTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollStats(),
    );
    _liveStatus = LiveStatusController(api: widget.api, session: widget.session)
      ..cameraIds = _shown.map((c) => c.id).toList()
      ..start();
  }

  Future<void> _pollStats() async {
    final s = await hostStats();
    if (!mounted) return;
    final now = DateTime.now();
    double? cpuPct;
    if (_lastCpuTime != null && _lastSample != null) {
      final dt = now.difference(_lastSample!).inMilliseconds / 1000.0;
      if (dt > 0) {
        cpuPct = ((s.cpuTimeSecs - _lastCpuTime!) / dt) / s.numCpus * 100.0;
      }
    }
    setState(() {
      _stats = s;
      _cpuPercent = cpuPct;
      _lastCpuTime = s.cpuTimeSecs;
      _lastSample = now;
    });
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _liveStatus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cams = _shown;
    final cols = cams.isEmpty ? 1 : math.sqrt(cams.length).ceil();
    final s = _stats;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (cams.isEmpty)
            const Center(
              child: Text(
                'No enabled cameras visible to this account.',
                style: TextStyle(color: Colors.white70),
              ),
            )
          else
            Positioned.fill(
              child: GridView.count(
                crossAxisCount: cols,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
                childAspectRatio: 16 / 9,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final cam in cams)
                    _WallTile(
                      key: ValueKey(cam.id),
                      api: widget.api,
                      session: widget.session,
                      camera: cam,
                      liveStatus: _liveStatus,
                      onTap: () => setState(() => _maximized = cam),
                    ),
                ],
              ),
            ),

          // Top bar: camera count + host stats (FRB) + logout.
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${cams.length} cameras',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.cyanAccent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'CPU ${_cpuPercent?.toStringAsFixed(0) ?? "—"}%  '
                      'GPU ${s?.gpuUtil?.toStringAsFixed(0) ?? "—"}%  '
                      'NVDEC ${s?.gpuDecUtil?.toStringAsFixed(0) ?? "—"}%  '
                      'RSS ${s?.memMb.toStringAsFixed(0) ?? "—"}MB',
                    ),
                    const SizedBox(width: 12),
                    InkWell(
                      onTap: widget.onLogout,
                      child: const Icon(
                        Icons.logout,
                        size: 16,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Connection-lost banner: status polling has failed 3x in a row, so
          // the REC/motion/detection badges below may be stale. Positioned is
          // the DIRECT Stack child; the ListenableBuilder that rebuilds the
          // banner on poll ticks sits INSIDE it (a Positioned must never be
          // nested under a non-Stack parent, or the whole Stack fails to build).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ListenableBuilder(
              listenable: _liveStatus,
              builder: (context, _) =>
                  ConnLostBanner(show: _liveStatus.connectionLost),
            ),
          ),

          // Maximized single-camera view (main stream + zoom/pan), on top.
          if (_maximized != null)
            _MaximizedPane(
              key: ValueKey('max-${_maximized!.id}'),
              api: widget.api,
              session: widget.session,
              camera: _maximized!,
              onClose: () => setState(() => _maximized = null),
            ),
        ],
      ),
    );
  }
}

/// One live camera pane: fetches its own stream URL then plays it. Independent
/// load/error state so a slow or dead camera doesn't stall the wall.
class _WallTile extends StatefulWidget {
  const _WallTile({
    super.key,
    required this.api,
    required this.session,
    required this.camera,
    required this.liveStatus,
    required this.onTap,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final LiveStatusController liveStatus;
  final VoidCallback onTap;

  @override
  State<_WallTile> createState() => _WallTileState();
}

class _WallTileState extends State<_WallTile> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  bool _firstFrame = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      final url = streams.preferredForWall;
      if (url == null) {
        setState(() => _error = 'no stream');
        return;
      }
      final player = Player();
      final controller = VideoController(player);
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
          ['mute', 'yes'],
        ]) {
          try {
            await p.setProperty(kv[0], kv[1]);
          } catch (_) {
            /* non-fatal */
          }
        }
      }
      player.stream.width.listen((w) {
        if (w != null && w > 0 && !_firstFrame && mounted) {
          setState(() => _firstFrame = true);
        }
      });
      await player.open(Media(url));
      if (!mounted) {
        player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'load failed');
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        color: Colors.grey.shade900,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_controller != null)
              Video(
                controller: _controller!,
                controls: NoVideoControls,
                fit: BoxFit.cover,
              )
            else
              Center(
                child: _error != null
                    ? Icon(
                        Icons.videocam_off,
                        color: Colors.red.shade300,
                        size: 28,
                      )
                    : const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),

            // REC/motion/detection badges (top-left), driven by the shared
            // LiveStatusController poll — only this row rebuilds on a tick.
            Positioned(
              left: 6,
              top: 6,
              child: ListenableBuilder(
                listenable: widget.liveStatus,
                builder: (context, _) {
                  final status = widget.liveStatus.cameraFor(widget.camera.id);
                  return LiveStatusBadgeRow(
                    recording: status?.recording ?? false,
                    recentMotion: status?.recentMotion ?? false,
                    detectionKeys: widget.liveStatus.detectionKeysFor(
                      widget.camera.id,
                    ),
                  );
                },
              ),
            ),

            // Camera-name label (bottom-left), with a live/offline dot.
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                        color: _error != null
                            ? Colors.red
                            : (_firstFrame ? Colors.greenAccent : Colors.amber),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.camera.name,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maximized single-camera view: plays the MAIN stream (higher res than the wall
/// sub) with Flutter-native digital zoom/pan (wheel = zoom-to-cursor, drag = pan,
/// double-tap = reset) — the same model proven in the P0 spike. Fills the wall.
class _MaximizedPane extends StatefulWidget {
  const _MaximizedPane({
    super.key,
    required this.api,
    required this.session,
    required this.camera,
    required this.onClose,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final VoidCallback onClose;

  @override
  State<_MaximizedPane> createState() => _MaximizedPaneState();
}

class _MaximizedPaneState extends State<_MaximizedPane> {
  Player? _player;
  VideoController? _controller;
  String? _error;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  static const double _maxZoom = 8.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      // Prefer MAIN for the maximized view; fall back to sub.
      final url = streams.rtspMain ?? streams.preferredForWall;
      if (url == null) {
        setState(() => _error = 'no stream');
        return;
      }
      final player = Player();
      final controller = VideoController(player);
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
      await player.open(Media(url));
      if (!mounted) {
        player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'load failed');
    }
  }

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

  void _resetZoom() => setState(() {
    _scale = 1.0;
    _offset = Offset.zero;
  });

  // ── PTZ optical zoom via the mouse wheel ────────────────────────────────
  // The wheel is discrete but ONVIF zoom is continuous (move → stop), so each
  // notch starts a zoom in the wheel's direction and a debounced timer sends
  // stop shortly after scrolling settles — smooth optical zoom while spinning.
  Timer? _ptzZoomStop;

  void _ptzWheelZoom(double scrollDy) {
    const v = 0.5;
    final zoom = scrollDy < 0 ? v : -v; // wheel up = zoom in
    widget.api
        .ptzMove(widget.session, widget.camera.id, zoom: zoom)
        .catchError((_) {});
    _ptzZoomStop?.cancel();
    _ptzZoomStop = Timer(const Duration(milliseconds: 220), () {
      widget.api.ptzStop(widget.session, widget.camera.id).catchError((_) {});
    });
  }

  @override
  void dispose() {
    _ptzZoomStop?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pane = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: [
                Positioned.fill(
                  child: _controller == null
                      ? Center(
                          child: _error != null
                              ? Icon(
                                  Icons.videocam_off,
                                  color: Colors.red.shade300,
                                  size: 40,
                                )
                              : const CircularProgressIndicator(),
                        )
                      : Listener(
                          onPointerSignal: (e) {
                            if (e is PointerScrollEvent) {
                              if (widget.camera.ptz) {
                                // PTZ camera → drive OPTICAL zoom, not digital.
                                _ptzWheelZoom(e.scrollDelta.dy);
                              } else {
                                final factor =
                                    math.pow(1.0013, -e.scrollDelta.dy)
                                        as double;
                                _zoomAt(e.localPosition, factor, pane);
                              }
                            }
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onDoubleTap: _resetZoom,
                            onPanUpdate: (d) => _panBy(d.delta, pane),
                            child: ClipRect(
                              child: Transform(
                                transform: Matrix4.identity()
                                  ..translateByDouble(
                                    _offset.dx,
                                    _offset.dy,
                                    0,
                                    1,
                                  )
                                  ..scaleByDouble(_scale, _scale, 1, 1),
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

                // Close (back to wall) + camera name + zoom level.
                Positioned(
                  top: 12,
                  left: 12,
                  child: Row(
                    children: [
                      Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          color: Colors.white,
                          onPressed: widget.onClose,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Text(
                              widget.camera.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_scale > 1.01) ...[
                              const SizedBox(width: 10),
                              Text(
                                '${_scale.toStringAsFixed(1)}×',
                                style: const TextStyle(
                                  color: Colors.cyanAccent,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // PTZ controls (only for PTZ-capable cameras), bottom-right.
                if (widget.camera.ptz)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _PtzControls(
                      api: widget.api,
                      session: widget.session,
                      camera: widget.camera,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// On-video PTZ controls for a PTZ-capable camera in the maximized view.
/// Continuous-velocity model: press-and-hold a direction to move, release to
/// stop (matching the ONVIF continuous-move API). Home recenters. Errors (e.g.
/// ONVIF not reachable) surface as a brief caption rather than a crash.
class _PtzControls extends StatefulWidget {
  const _PtzControls({
    required this.api,
    required this.session,
    required this.camera,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;

  @override
  State<_PtzControls> createState() => _PtzControlsState();
}

class _PtzControlsState extends State<_PtzControls> {
  static const double _v = 0.6; // pan/tilt/zoom velocity
  String? _error;

  Future<void> _move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    try {
      await widget.api.ptzMove(
        widget.session,
        widget.camera.id,
        pan: pan,
        tilt: tilt,
        zoom: zoom,
      );
      if (mounted && _error != null) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'PTZ unavailable');
    }
  }

  Future<void> _stop() async {
    try {
      await widget.api.ptzStop(widget.session, widget.camera.id);
    } catch (_) {
      /* ignore stop errors */
    }
  }

  Future<void> _home() async {
    try {
      await widget.api.ptzHome(widget.session, widget.camera.id);
    } catch (_) {
      if (mounted) setState(() => _error = 'PTZ unavailable');
    }
  }

  /// A press-and-hold button: down → start motion, up/cancel → stop.
  Widget _hold(
    IconData icon, {
    double pan = 0,
    double tilt = 0,
    double zoom = 0,
  }) {
    return Listener(
      onPointerDown: (_) => _move(pan: pan, tilt: tilt, zoom: zoom),
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: Container(
        margin: const EdgeInsets.all(2),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _tap(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 2),
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red.shade300, fontSize: 11),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Zoom column
              Column(
                children: [
                  _hold(Icons.zoom_in, zoom: _v),
                  _hold(Icons.zoom_out, zoom: -_v),
                ],
              ),
              const SizedBox(width: 8),
              // Pan/tilt D-pad
              Column(
                children: [
                  _hold(Icons.keyboard_arrow_up, tilt: _v),
                  Row(
                    children: [
                      _hold(Icons.keyboard_arrow_left, pan: -_v),
                      _tap(Icons.home, _home),
                      _hold(Icons.keyboard_arrow_right, pan: _v),
                    ],
                  ),
                  _hold(Icons.keyboard_arrow_down, tilt: -_v),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
