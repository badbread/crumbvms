// The live wall — the real P1 headline surface. A grid of live camera panes,
// each pulling its own go2rtc restream via media_kit/libmpv. Each tile
// self-manages its stream-URL fetch + player lifecycle so one camera's slow
// load or failure never blocks the others.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/src/rust/api/host.dart';

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

  List<Camera> get _shown =>
      widget.cameras.where((c) => c.enabled).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _statsTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollStats(),
    );
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
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;

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
    return Container(
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
    );
  }
}
