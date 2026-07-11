// P1 perf gate — the one remaining unknown after P0: does N-up media_kit hold
// up? Each tile is its OWN libmpv instance + external texture (unlike the old
// Tauri native-HWND panes). This harness brings up an N-up grid with the tuned
// mpv options ported from apps/desktop/src-tauri's `configure_mpv`, and reports
// client cost (CPU/GPU/NVDEC/RSS/VRAM via the FRB host_stats) plus how long the
// whole wall took to reach first frame.
//
// Enable with --dart-define=GRID=<n> (e.g. 16). To keep production-NVR load
// minimal, point STREAM_URL at ONE substream: go2rtc shares a single upstream
// camera connection across all N consumers, so this measures CLIENT per-instance
// overhead (the actual unknown) without N concurrent pulls on the live system.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/src/rust/api/host.dart';

class PerfGridApp extends StatelessWidget {
  const PerfGridApp({super.key, required this.count, required this.url});
  final int count;
  final String url;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crumb Flutter perf grid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: PerfGrid(count: count, url: url),
    );
  }
}

class PerfGrid extends StatefulWidget {
  const PerfGrid({super.key, required this.count, required this.url});
  final int count;
  final String url;

  @override
  State<PerfGrid> createState() => _PerfGridState();
}

class _PerfGridState extends State<PerfGrid> {
  final List<Player> _players = [];
  final List<VideoController> _controllers = [];
  final List<bool> _firstFrame = [];

  final Stopwatch _bringUp = Stopwatch();
  Duration? _wallReady; // when the LAST pane reached first frame

  Timer? _statsTimer;
  HostStats? _stats;
  double? _cpuPercent;
  double? _lastCpuTime;
  DateTime? _lastSample;

  int get _liveCount => _firstFrame.where((f) => f).length;

  @override
  void initState() {
    super.initState();
    _bringUp.start();
    for (var i = 0; i < widget.count; i++) {
      final player = Player();
      final controller = VideoController(player);
      _players.add(player);
      _controllers.add(controller);
      _firstFrame.add(false);
      final idx = i;
      player.stream.width.listen((w) {
        if (w != null && w > 0 && !_firstFrame[idx] && mounted) {
          setState(() {
            _firstFrame[idx] = true;
            if (_liveCount >= widget.count && _wallReady == null) {
              _wallReady = _bringUp.elapsed;
            }
          });
        }
      });
      _startPane(player);
    }
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollStats(),
    );
  }

  Future<void> _startPane(Player player) async {
    // Tuned mpv options ported from src-tauri `configure_mpv`. Set before
    // open() (rtsp-transport must precede loadfile). NativePlayer exposes the
    // raw mpv property API.
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
    await player.open(Media(widget.url));
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
    for (final p in _players) {
      p.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cols = math.sqrt(widget.count).ceil();
    final s = _stats;
    final gpu = s?.gpuUtil == null
        ? 'GPU —'
        : 'GPU ${s!.gpuUtil!.toStringAsFixed(0)}%  '
              'NVDEC ${s.gpuDecUtil?.toStringAsFixed(0) ?? "—"}%  '
              'VRAM ${s.gpuMemMb?.toStringAsFixed(0) ?? "—"}MB';
    final ready = _wallReady == null
        ? 'bringing up…'
        : 'wall ready ${(_wallReady!.inMilliseconds / 1000).toStringAsFixed(1)}s';
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GridView.count(
              crossAxisCount: cols,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
              childAspectRatio: 16 / 9,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < widget.count; i++)
                  Container(
                    color: Colors.grey.shade900,
                    child: Video(
                      controller: _controllers[i],
                      controls: NoVideoControls,
                      fit: BoxFit.cover,
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
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
                    Text(
                      '${widget.count}-up   $_liveCount/${widget.count} live'
                      '   $ready',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.cyanAccent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'CPU ${_cpuPercent?.toStringAsFixed(0) ?? "—"}%   '
                      'RSS ${s?.memMb.toStringAsFixed(0) ?? "—"}MB   '
                      '${s?.numCpus ?? "—"} cores',
                    ),
                    const SizedBox(height: 2),
                    Text(gpu),
                    if (s?.gpuName != null)
                      Text(
                        s!.gpuName!,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
