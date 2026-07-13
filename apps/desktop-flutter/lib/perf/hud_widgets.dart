// Visual half of the performance HUD: the F8 aggregate footer with
// sparklines, the always-on per-tile decode-health dot, the status-bar
// perf-alert banner, an expandable diagnostics table, and the decode
// benchmark panel. All widgets are pure views over [HudController] — call
// `controller.registerPane`/`unregisterPane` from the tile widgets that own
// the actual media_kit [Player]s (see hud_controller.dart's doc comment).
//
// Ports app.js's `hudRenderFooter`/`hudSpark` (~2952-2980), the per-tile
// `.tsi-perf` badge driven by `hudUpdateBadges` (~2820), the status-bar
// `#status-alert` element driven by `updateStatusAlert` (~321), and
// `hudRenderDiag`/`hudRunBenchmark` (~2982-3100) to Flutter widgets.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/models.dart';
import 'hud_controller.dart';

const _ok = Color(0xFF3FB950);
const _warn = Color(0xFFE0A92C);
const _bad = Color(0xFFF0635C);

Color _healthColor(PaneHealth h) => switch (h) {
  PaneHealth.ok => _ok,
  PaneHealth.warn => _warn,
  PaneHealth.bad => _bad,
  PaneHealth.unknown => Colors.white38,
};

/// Always-on per-tile decode-health dot (green = hw decode keeping up, amber
/// = sw decode of a hi-res stream or fps lag, red = actively dropping
/// frames). Meant to sit in a tile's corner overlay; carries the numbers in
/// its tooltip so a glance at the dot plus a hover gives the full picture.
class PaneHealthDot extends StatelessWidget {
  const PaneHealthDot({
    super.key,
    required this.controller,
    required this.paneId,
    this.size = 9,
  });

  final HudController controller;
  final String paneId;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final health = controller.health[paneId] ?? PaneHealth.unknown;
        return Tooltip(
          message: controller.tooltipFor(paneId),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _healthColor(health),
              boxShadow: [
                BoxShadow(
                  color: _healthColor(health).withValues(alpha: 0.6),
                  blurRadius: 3,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Status-bar performance alert — renders nothing when healthy, a short
/// banner (drops/CPU/GPU-decode) only when something's wrong. Works even
/// when the F8 footer is hidden, matching `updateStatusAlert`'s
/// independence from `hudState.on`.
class StatusAlertBar extends StatelessWidget {
  const StatusAlertBar({super.key, required this.controller});

  final HudController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final text = controller.statusAlertText;
        if (text.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _bad.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}

/// F8 aggregate performance footer: streams/decode/drops/CPU/RAM/GPU/network
/// metric tiles plus three trailing sparklines (CPU, drops, GPU-decode).
/// Renders nothing while `controller.on` is false — mount it once, unrelated
/// to whether it's visible.
class HudFooter extends StatelessWidget {
  const HudFooter({super.key, required this.controller});

  final HudController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.on) return const SizedBox.shrink();
        final agg = controller.aggregate;
        final trend = controller.trend;
        return Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: Colors.black.withValues(alpha: 0.82),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _metric('Streams', '${agg?.streams ?? 0}'),
                _metric(
                  'Decode',
                  agg == null
                      ? '—'
                      : '${agg.decodeFps.round()}/${agg.containerFps.round()} fps',
                ),
                _metric(
                  'Drops',
                  agg == null ? '—' : '${agg.dropsPerSec.toStringAsFixed(1)}/s',
                  bad: (agg?.dropsPerSec ?? 0) >= 1,
                ),
                _metric(
                  'CPU',
                  agg?.cpuPercent == null
                      ? '—'
                      : '${agg!.cpuPercent!.round()}%',
                ),
                _metric(
                  'RAM',
                  agg?.host == null ? '—' : _fmtMb(agg!.host!.memMb),
                ),
                _metric(
                  'GPU',
                  agg?.host?.gpuUtil == null
                      ? '—'
                      : '${agg!.host!.gpuUtil!.round()}%',
                ),
                _metric(
                  'GPU decode',
                  agg?.host?.gpuDecUtil == null
                      ? '—'
                      : '${agg!.host!.gpuDecUtil!.round()}%',
                  bad: (agg?.host?.gpuDecUtil ?? 0) >= 90,
                ),
                _metric(
                  'Network',
                  agg == null ? '—' : '${agg.netMbps.round()} Mbps',
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'cpu · drops · gpu',
                      style: TextStyle(color: Colors.white54, fontSize: 9),
                    ),
                    Row(
                      children: [
                        _Sparkline(
                          values: trend.map((p) => p.cpu).toList(),
                          color: _ok,
                        ),
                        const SizedBox(width: 4),
                        _Sparkline(
                          values: trend.map((p) => p.drops).toList(),
                          color: _bad,
                        ),
                        const SizedBox(width: 4),
                        _Sparkline(
                          values: trend
                              .map((p) => p.gpuDec ?? 0)
                              .toList(),
                          color: _warn,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _fmtMb(double mb) =>
      mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)}GB' : '${mb.round()}MB';

  Widget _metric(String label, String value, {bool bad = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9)),
          Text(
            value,
            style: TextStyle(
              color: bad ? _bad : Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tiny inline trend line (app.js `hudSpark`'s SVG polyline, redrawn with
/// CustomPainter). Fixed 50x14 box; blank until there are ≥2 samples.
class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 50,
      height: 14,
      child: CustomPaint(painter: _SparklinePainter(values, color)),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.fold<double>(1, (m, v) => v > m ? v : m);
    final n = values.length;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final x = i / (n - 1) * (size.width - 2) + 1;
      final y = size.height - 1 - (values[i] / maxV) * (size.height - 2);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color;
}

/// Per-camera decode diagnostics table (Settings → Diagnostics). One row per
/// CONFIGURED camera (not just on-wall ones): cameras with no active pane
/// show "not on wall" since the desktop only decodes what's currently shown.
/// Calls `controller.setDiagnosticsVisible(true/false)` on mount/unmount so
/// the sampler keeps running at the busy cadence while this panel is open,
/// even with the F8 footer off (mirrors app.js's `srvState.section==='diag'`
/// check in `hudTick`).
class DiagnosticsPanel extends StatefulWidget {
  const DiagnosticsPanel({
    super.key,
    required this.controller,
    required this.cameras,
  });

  final HudController controller;

  /// Full configured camera list (not just enabled/on-wall), e.g. from
  /// `CrumbApi.listCameras`.
  final List<Camera> cameras;

  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<DiagnosticsPanel> {
  @override
  void initState() {
    super.initState();
    widget.controller.setDiagnosticsVisible(true);
  }

  @override
  void dispose() {
    widget.controller.setDiagnosticsVisible(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        // Index live panes by camera id.
        final byCamera = <String, String>{}; // cameraId -> paneId
        for (final paneId in c.lastPaneStats.keys) {
          final camId = c.cameraIdForPane(paneId);
          if (camId != null) byCamera[camId] = paneId;
        }
        final cams = widget.cameras.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        final live = c.lastLiveAggregate;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (live != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${live.streams} streams · ${live.decodeFps.round()} fps · '
                  '${live.dropsPerSec.toStringAsFixed(1)} drops/s',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            if (cams.isEmpty)
              const Text(
                'No cameras configured.',
                style: TextStyle(color: Colors.white54),
              )
            else
              Table(
                columnWidths: const {
                  0: FlexColumnWidth(2),
                  1: FlexColumnWidth(1),
                  2: FlexColumnWidth(1),
                  3: FlexColumnWidth(1),
                  4: FlexColumnWidth(1),
                  5: FlexColumnWidth(1),
                },
                children: [
                  _diagHeaderRow(),
                  for (final cam in cams)
                    _diagRow(c, cam, byCamera[cam.id]),
                ],
              ),
          ],
        );
      },
    );
  }

  TableRow _diagHeaderRow() {
    TextStyle style = const TextStyle(
      color: Colors.white54,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    Widget h(String s) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(s, style: style),
    );
    return TableRow(
      children: [
        h('Camera'),
        h('Res'),
        h('FPS'),
        h('Drops/s'),
        h('Decode'),
        h('Mbps'),
      ],
    );
  }

  TableRow _diagRow(HudController c, Camera cam, String? paneId) {
    TextStyle cell = const TextStyle(color: Colors.white, fontSize: 12);
    TextStyle dim = const TextStyle(color: Colors.white38, fontSize: 12);
    Widget cellText(String s, {bool bad = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        s,
        style: bad ? cell.copyWith(color: _bad) : cell,
      ),
    );

    if (paneId == null) {
      return TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(cam.name, style: dim),
          ),
          Text('—', style: dim),
          Text('—', style: dim),
          Text('—', style: dim),
          Text('not on wall', style: dim),
          Text('—', style: dim),
        ],
      );
    }

    final s = c.lastPaneStats[paneId];
    if (s == null) {
      return TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(cam.name, style: cell),
          ),
          Text('—', style: cell),
          Text('—', style: cell),
          Text('—', style: cell),
          Text('—', style: cell),
          Text('—', style: cell),
        ],
      );
    }
    final dps = c.dropsPerSecFor(paneId);
    final hw = s.isHardwareDecoded ? s.hwdec : 'CPU';
    final fpsLag = s.containerFps > 0 && s.decodeFps < s.containerFps * 0.7;
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(cam.name, style: cell),
        ),
        cellText(s.height > 0 ? '${s.height}p' : '—'),
        cellText(
          '${s.decodeFps.toStringAsFixed(0)}/${s.containerFps.toStringAsFixed(0)}',
          bad: fpsLag,
        ),
        cellText(dps.toStringAsFixed(1), bad: dps >= 1),
        cellText(hw, bad: hw == 'CPU'),
        cellText(s.videoMegabits.toStringAsFixed(1)),
      ],
    );
  }
}

/// Decode stress-test panel: "how many full-res streams can this box take."
/// The caller supplies the hooks that actually re-point wall tiles at their
/// main stream (see [HudController.runBenchmark]'s doc comment) — this
/// widget just drives the button, status line, and result card.
class BenchmarkPanel extends StatefulWidget {
  const BenchmarkPanel({
    super.key,
    required this.controller,
    required this.switchToFullRes,
    required this.restore,
  });

  final HudController controller;
  final Future<void> Function() switchToFullRes;
  final Future<void> Function() restore;

  @override
  State<BenchmarkPanel> createState() => _BenchmarkPanelState();
}

class _BenchmarkPanelState extends State<BenchmarkPanel> {
  String _status = '';
  BenchmarkResult? _result;

  Future<void> _run() async {
    setState(() {
      _status = '';
      _result = null;
    });
    try {
      final result = await widget.controller.runBenchmark(
        switchToFullRes: widget.switchToFullRes,
        restore: widget.restore,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (mounted) setState(() => _result = result);
    } on StateError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final running = widget.controller.benchmarkRunning;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: running ? null : _run,
              child: Text(running ? 'Running…' : 'Run decode benchmark'),
            ),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _status,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            if (_result != null) ...[
              const SizedBox(height: 10),
              _report(_result!),
            ],
          ],
        );
      },
    );
  }

  Widget _report(BenchmarkResult r) {
    final color = r.healthy ? _ok : _bad;
    Widget kv(String k, String v, {Color? c}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            child: Text(k, style: const TextStyle(color: Colors.white54)),
          ),
          Text(
            v,
            style: TextStyle(color: c ?? Colors.white, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(r.verdict, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          kv('Streams', '${r.streams}× full-res'),
          kv(
            'Peak drops',
            '${r.peakDropsPerSec.toStringAsFixed(1)}/s',
            c: r.peakDropsPerSec >= 1 ? _bad : null,
          ),
          kv('Decode ratio', '${(r.decodeRatio * 100).round()}%'),
          kv('Peak CPU', '${r.peakCpuPercent.round()}%'),
          kv(
            'Peak GPU decode',
            r.peakGpuDecPercent == null ? '—' : '${r.peakGpuDecPercent!.round()}%',
          ),
        ],
      ),
    );
  }
}
