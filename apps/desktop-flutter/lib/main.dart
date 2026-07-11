// P0 de-risk spike — prove the three unproven-together pieces on ONE pane:
//   1. media_kit renders ONE live camera (mpv → Flutter external texture),
//   2. flutter_rust_bridge calls the real Windows-native Rust core (host_stats),
//   3. a NATIVE Flutter overlay composites over the video texture with real
//      hit-testing (the exact thing the Tauri Win32-airspace model made janky).
//
// If any of these feels janky on real hardware, STOP and flag it — that is the
// spike's whole job (revisit trigger in the rewrite decision).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/src/rust/api/host.dart';
import 'package:crumb_desktop/src/rust/frb_generated.dart';

/// The camera/stream to render. Injected at build/run time so no site-specific
/// address lands in the repo:
/// `flutter run --dart-define=STREAM_URL=rtsp://HOST:PORT/CAMERA`.
/// The committed default is a generic libmpv lavfi test pattern so the app is
/// runnable standalone; the real proof points STREAM_URL at a go2rtc restream.
const String kStreamUrl = String.fromEnvironment(
  'STREAM_URL',
  defaultValue: 'av://lavfi:testsrc=size=1280x720:rate=30',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit native surface + libmpv init.
  MediaKit.ensureInitialized();
  // flutter_rust_bridge — loads the cargokit-built rust_lib_crumb_desktop dylib.
  await RustLib.init();
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crumb Flutter spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LivePane(),
    );
  }
}

class LivePane extends StatefulWidget {
  const LivePane({super.key});

  @override
  State<LivePane> createState() => _LivePaneState();
}

class _LivePaneState extends State<LivePane> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  Timer? _statsTimer;
  HostStats? _stats;
  double? _cpuPercent; // derived from cpu_time_secs deltas
  double? _lastCpuTime;
  DateTime? _lastSample;

  // Draggable PTZ-control stub position (fraction of the pane, 0..1). Dragging
  // this over live video is the airspace stress test: a native widget must
  // receive the drag directly, with no HWND mouse-forwarding shim.
  Offset _ptz = const Offset(0.5, 0.78);
  bool _firstFrame = false;

  // ── Digital zoom/pan state ──────────────────────────────────────────────
  // Transform applied to the VIDEO texture only (overlays stay in screen space).
  // Digital zoom upscales the same decoded frame — identical to mpv `video-zoom`
  // — but done Flutter-native: GPU-composited, no per-wheel-tick FFI round-trip,
  // sub-pixel smooth, and works the same for live + playback. Model:
  //   screen = _scale * content + _offset   (content box == the pane).
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  static const double _maxZoom = 8.0;

  /// Zoom about `cursor` (pane px) by `factor`, keeping the point under the
  /// cursor fixed — the surveillance zoom-to-cursor behaviour.
  void _zoomAt(Offset cursor, double factor, Size pane) {
    final newScale = (_scale * factor).clamp(1.0, _maxZoom);
    if (newScale == _scale) return;
    final newOffset = cursor - (cursor - _offset) * (newScale / _scale);
    setState(() {
      _scale = newScale;
      _offset = _clampOffset(newOffset, pane);
    });
  }

  /// Keep the scaled video covering the viewport (no letterbox gap from panning).
  Offset _clampOffset(Offset o, Size pane) {
    final minX = pane.width * (1 - _scale);
    final minY = pane.height * (1 - _scale);
    return Offset(
      o.dx.clamp(minX <= 0 ? minX : 0.0, 0.0),
      o.dy.clamp(minY <= 0 ? minY : 0.0, 0.0),
    );
  }

  void _panBy(Offset delta, Size pane) {
    if (_scale <= 1.0) return; // nothing to pan at 1x
    setState(() => _offset = _clampOffset(_offset + delta, pane));
  }

  void _resetZoom() => setState(() {
        _scale = 1.0;
        _offset = Offset.zero;
      });

  @override
  void initState() {
    super.initState();
    _startVideo();
    _statsTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
    // Note when the first video frame lands (time-to-first-frame is one of the
    // jank metrics we report).
    _player.stream.width.listen((w) {
      if (w != null && w > 0 && !_firstFrame && mounted) {
        setState(() => _firstFrame = true);
      }
    });
  }

  Future<void> _startVideo() async {
    // Force RTSP-over-TCP for reliability on a high-bitrate MAIN stream — the
    // same call the Tauri `configure_mpv` makes. Best-effort: setProperty is on
    // the native backend and is a no-op on platforms without it.
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('rtsp-transport', 'tcp');
      }
    } catch (_) {/* non-fatal for the spike */}
    await _player.open(Media(kStreamUrl));
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
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final pane = Size(w, h);
          return Stack(
            children: [
              // ── (1) live video texture + (2) digital zoom/pan ─────────────
              // Wheel → zoom-to-cursor, drag → pan (when zoomed), double-tap →
              // reset. The gesture layer spans the pane but sits BELOW the
              // overlays, so dragging the PTZ stub still moves the stub, not the
              // video. The Transform scales only the texture; overlays are
              // screen-space siblings above it (a zoomed pane must not zoom its
              // own HUD).
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      // ~1.13x per wheel notch; sign selects in/out.
                      final factor = math.pow(1.0013, -e.scrollDelta.dy) as double;
                      _zoomAt(e.localPosition, factor, pane);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: _resetZoom,
                    onPanUpdate: (d) => _panBy(d.delta, pane),
                    child: ClipRect(
                      child: Transform(
                        transform: Matrix4.identity()
                          ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                          ..scaleByDouble(_scale, _scale, 1, 1),
                        child: Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ── (3a) native overlay: camera name + FRB-sourced host stats ──
              Positioned(
                top: 16,
                left: 16,
                child: _StatsOverlay(
                  streamUrl: kStreamUrl,
                  firstFrame: _firstFrame,
                  stats: _stats,
                  cpuPercent: _cpuPercent,
                  zoom: _scale,
                ),
              ),

              // ── (3b) native overlay: draggable PTZ-control stub ───────────
              Positioned(
                left: _ptz.dx * w - 44,
                top: _ptz.dy * h - 44,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      _ptz = Offset(
                        (_ptz.dx + d.delta.dx / w).clamp(0.05, 0.95),
                        (_ptz.dy + d.delta.dy / h).clamp(0.05, 0.95),
                      );
                    });
                  },
                  child: const _PtzStub(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Semi-transparent HUD card: proves a native, text-rendering Flutter widget
/// composites cleanly over the video texture and is fed live data across the
/// Rust FFI boundary once per second.
class _StatsOverlay extends StatelessWidget {
  const _StatsOverlay({
    required this.streamUrl,
    required this.firstFrame,
    required this.stats,
    required this.cpuPercent,
    required this.zoom,
  });

  final String streamUrl;
  final bool firstFrame;
  final HostStats? stats;
  final double? cpuPercent;
  final double zoom;

  String get _cam => Uri.tryParse(streamUrl)?.pathSegments.lastOrNull ?? '?';

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final gpu = s?.gpuUtil == null
        ? 'GPU  —  (no NVIDIA)'
        : 'GPU  ${s!.gpuUtil!.toStringAsFixed(0)}%   '
            'NVDEC ${s.gpuDecUtil?.toStringAsFixed(0) ?? "—"}%   '
            'VRAM ${s.gpuMemMb?.toStringAsFixed(0) ?? "—"} MB';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  firstFrame ? Icons.videocam : Icons.hourglass_top,
                  size: 16,
                  color: firstFrame ? Colors.greenAccent : Colors.amber,
                ),
                const SizedBox(width: 6),
                Text(
                  '$_cam   ${firstFrame ? "LIVE" : "connecting…"}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (zoom > 1.01) ...[
                  const SizedBox(width: 10),
                  Text('${zoom.toStringAsFixed(1)}×',
                      style: const TextStyle(
                          color: Colors.cyanAccent,
                          fontWeight: FontWeight.w700)),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(s == null
                ? 'host_stats: (waiting for first FRB poll)'
                : 'CPU  ${cpuPercent?.toStringAsFixed(0) ?? "—"}%   '
                    'RSS ${s.memMb.toStringAsFixed(0)} MB   '
                    '${s.numCpus} cores'),
            const SizedBox(height: 2),
            Text(gpu),
            if (s?.gpuName != null) ...[
              const SizedBox(height: 2),
              Text(s!.gpuName!,
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

/// A stand-in for the on-video PTZ wheel — the surface Jason called janky in the
/// airspace model. Here it is just a native circular control; the point is that
/// it drags smoothly ON TOP of live video with no mouse-forwarding shim.
class _PtzStub extends StatelessWidget {
  const _PtzStub();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(color: Colors.white70, width: 1.5),
      ),
      child: const Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.keyboard_arrow_up, color: Colors.white, size: 22),
          Align(
            alignment: Alignment.bottomCenter,
            child: Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 22),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.keyboard_arrow_left, color: Colors.white, size: 22),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Icon(Icons.keyboard_arrow_right, color: Colors.white, size: 22),
          ),
          Icon(Icons.open_with, color: Colors.white54, size: 16),
        ],
      ),
    );
  }
}
