// Live performance HUD state machine: per-pane decode health, the F8
// aggregate footer, the status-bar perf alert, and the diagnostics
// stress-test benchmark.
//
// Ports apps/desktop/src/app.js's `hudState`/`hudTick`/`hudUpdateBadges`/
// `hudComputeAgg`/`hudCpuPct`/`hudRunBenchmark` (~app.js:2790-3100) from a
// single global HashMap<paneId, MpvHandle> polled via Tauri `invoke` into a
// Dart [ChangeNotifier] that owns a *registry* of live [Player]s, since each
// media_kit tile is an independent Player rather than one shared native pane
// map. The host-level half (CPU/RAM/GPU) reuses the existing
// `lib/src/rust/api/host.dart` FRB binding — same `hostStats()` call the
// wall screen already polls for its top-bar readout.
//
// Usage (see integration notes returned alongside this file):
//   - Own one `HudController` per wall session (e.g. in `_WallScreenState`).
//   - Each tile calls `controller.registerPane(paneId, player, cameraId: ...,
//     cameraName: ...)` once its Player is open, and
//     `controller.unregisterPane(paneId)` in dispose().
//   - Mount `HudFooter`, `StatusAlertBar`, `PaneHealthDot` (per tile) and
//     `DiagnosticsPanel` (from hud_widgets.dart) wherever the wall UI wants
//     them; they all just listen to this controller.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'package:crumb_desktop/src/rust/api/host.dart';
import 'pane_stats.dart';

/// Per-tile decode-health classification (app.js `hudUpdateBadges`'s
/// green/amber/red dot). `unknown` covers a pane not yet registered/sampled.
enum PaneHealth { unknown, ok, warn, bad }

/// One aggregate wall-level sample (app.js `hudComputeAgg` + CPU/host merge).
class HudAggregate {
  const HudAggregate({
    required this.streams,
    required this.decodeFps,
    required this.containerFps,
    required this.netMbps,
    required this.dropsPerSec,
    required this.cpuPercent,
    required this.host,
  });

  final int streams;
  final double decodeFps;
  final double containerFps;
  final double netMbps;
  final double dropsPerSec;
  final double? cpuPercent;
  final HostStats? host;
}

/// One ring-buffer point for the footer sparklines (app.js `hudPushTrend`).
class HudTrendPoint {
  const HudTrendPoint({
    required this.t,
    required this.cpu,
    required this.gpuDec,
    required this.drops,
    required this.decodeFps,
    required this.netMbps,
  });

  final DateTime t;
  final double cpu;
  final double? gpuDec;
  final double drops;
  final double decodeFps;
  final double netMbps;
}

/// Result of the ~12s full-res decode stress test (app.js `hudRunBenchmark`).
class BenchmarkResult {
  const BenchmarkResult({
    required this.streams,
    required this.peakDropsPerSec,
    required this.decodeRatio,
    required this.peakCpuPercent,
    required this.peakGpuDecPercent,
    required this.verdict,
    required this.healthy,
  });

  final int streams;
  final double peakDropsPerSec;

  /// Sustained decode-fps ÷ container-fps, averaged over the run. 1.0 means
  /// decode is fully keeping up with the source.
  final double decodeRatio;
  final double peakCpuPercent;
  final double? peakGpuDecPercent;
  final String verdict;

  /// false = "Overloaded" (peak drops ≥5/s); true covers both the clean and
  /// "minor drops" cases, mirroring app.js's two-tier ok/bad split for color.
  final bool healthy;
}

class HudController extends ChangeNotifier {
  static const _trendMax = 150; // ~2.5 min @ 1s cadence, matches app.js
  static const _busyIntervalMs = 1000;
  static const _idleIntervalMs = 2500;

  final Map<String, Player> _panes = {};
  final Map<String, String> _paneCameraId = {};
  final Map<String, String> _paneCameraName = {};
  final Map<String, ({int total, DateTime t})> _prevDrops = {};

  Map<String, PaneStats> _lastPaneStats = {};
  final Map<String, double> _dropsPerSecByPane = {};
  final Map<String, PaneHealth> _health = {};

  final List<HudTrendPoint> _trend = [];
  HudAggregate? _lastAggregate;
  HudAggregate? _lastLiveAggregate; // last sample with streams > 0

  double? _prevCpuTime;
  DateTime? _prevCpuSample;

  bool _on = false;
  bool _diagnosticsVisible = false;
  bool _benchmarkRunning = false;
  Timer? _timer;

  /// F8 footer on/off (persists only for the app session; wire to storage in
  /// the host screen if cross-launch persistence is wanted).
  bool get on => _on;

  bool get benchmarkRunning => _benchmarkRunning;

  Map<String, PaneStats> get lastPaneStats => Map.unmodifiable(_lastPaneStats);
  Map<String, PaneHealth> get health => Map.unmodifiable(_health);
  List<HudTrendPoint> get trend => List.unmodifiable(_trend);
  HudAggregate? get aggregate => _lastAggregate;
  HudAggregate? get lastLiveAggregate => _lastLiveAggregate;

  // ── Pane registry ─────────────────────────────────────────────────────────

  /// Register a live pane so the sampler picks it up on the next tick. Call
  /// once the tile's [Player] has been opened; `cameraId`/`cameraName` power
  /// the diagnostics table (matched against the full camera list so off-wall
  /// cameras show "not on wall" instead of just being absent).
  void registerPane(
    String paneId,
    Player player, {
    String? cameraId,
    String? cameraName,
  }) {
    _panes[paneId] = player;
    if (cameraId != null) _paneCameraId[paneId] = cameraId;
    if (cameraName != null) _paneCameraName[paneId] = cameraName;
    _ensureRunning();
  }

  void unregisterPane(String paneId) {
    _panes.remove(paneId);
    _paneCameraId.remove(paneId);
    _paneCameraName.remove(paneId);
    _prevDrops.remove(paneId);
    _lastPaneStats.remove(paneId);
    _dropsPerSecByPane.remove(paneId);
    _health.remove(paneId);
    if (_panes.isEmpty) stop();
  }

  String? cameraIdForPane(String paneId) => _paneCameraId[paneId];
  String? cameraNameForPane(String paneId) => _paneCameraName[paneId];

  // ── Visibility hooks driving adaptive cadence (app.js `hudShouldRun`) ──────

  /// Call from the diagnostics/settings screen's init/dispose so the sampler
  /// also runs while that panel is open (even with the F8 footer off).
  void setDiagnosticsVisible(bool visible) {
    _diagnosticsVisible = visible;
    _ensureRunning();
  }

  // ── F8 footer toggle ────────────────────────────────────────────────────

  void toggle([bool? value]) {
    _on = value ?? !_on;
    _ensureRunning();
    notifyListeners();
  }

  // ── Sampler lifecycle ───────────────────────────────────────────────────

  void _ensureRunning() {
    if (_panes.isEmpty) {
      stop();
      return;
    }
    if (_timer != null) return;
    _scheduleNext(0);
  }

  void _scheduleNext(int delayMs) {
    _timer = Timer(Duration(milliseconds: delayMs), _tick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  bool get _busy =>
      _on ||
      _diagnosticsVisible ||
      (_lastAggregate?.dropsPerSec ?? 0) >= 1;

  Future<void> _tick() async {
    _timer = null;
    if (_benchmarkRunning) return; // benchmark drives its own sampling loop
    if (_panes.isEmpty) return;

    await _sampleOnce();
    notifyListeners();

    if (_panes.isNotEmpty) {
      _scheduleNext(_busy ? _busyIntervalMs : _idleIntervalMs);
    }
  }

  /// One sample across every registered pane + host stats. Shared by the
  /// normal tick and the benchmark loop (app.js's `sampleOnce` closure).
  Future<void> _sampleOnce() async {
    final entries = _panes.entries.toList(growable: false);
    final samples = await Future.wait(
      entries.map((e) => PaneStats.sample(e.value)),
    );
    final panes = <String, PaneStats>{
      for (var i = 0; i < entries.length; i++) entries[i].key: samples[i],
    };
    _lastPaneStats = panes;
    _updateHealthAndDrops(panes);

    HostStats? host;
    try {
      host = await hostStats();
    } catch (_) {
      host = null;
    }
    final cpuPct = _cpuPercentFromDelta(host);

    final agg = _computeAggregate(panes, host, cpuPct);
    _lastAggregate = agg;
    if (agg.streams > 0) _lastLiveAggregate = agg;
    _pushTrend(agg);
  }

  void _updateHealthAndDrops(Map<String, PaneStats> panes) {
    final now = DateTime.now();
    for (final entry in panes.entries) {
      final paneId = entry.key;
      final s = entry.value;
      final total = s.dropCount + s.decDropCount;
      final prev = _prevDrops[paneId];
      double dps = 0;
      if (prev != null) {
        final dt = now.difference(prev.t).inMilliseconds / 1000.0;
        if (dt > 0) dps = math.max(0, (total - prev.total) / dt);
      }
      _prevDrops[paneId] = (total: total, t: now);
      _dropsPerSecByPane[paneId] = dps;

      PaneHealth cls;
      if (dps >= 1) {
        cls = PaneHealth.bad;
      } else if (!s.isHardwareDecoded && s.height >= 1080) {
        cls = PaneHealth.warn;
      } else if (s.containerFps > 0 &&
          s.decodeFps > 0 &&
          s.decodeFps < s.containerFps * 0.7) {
        cls = PaneHealth.warn;
      } else {
        cls = PaneHealth.ok;
      }
      _health[paneId] = cls;
    }
  }

  double get _totalDropsPerSec =>
      _dropsPerSecByPane.values.fold(0.0, (a, b) => a + b);

  HudAggregate _computeAggregate(
    Map<String, PaneStats> panes,
    HostStats? host,
    double? cpuPct,
  ) {
    var streams = 0;
    double decFps = 0, cFps = 0, netBits = 0;
    for (final s in panes.values) {
      if (s.hasSignal) streams++;
      decFps += s.decodeFps;
      cFps += s.containerFps;
      netBits += s.videoBitrate;
    }
    return HudAggregate(
      streams: streams,
      decodeFps: decFps,
      containerFps: cFps,
      netMbps: netBits / 1e6,
      dropsPerSec: _totalDropsPerSec,
      cpuPercent: cpuPct,
      host: host,
    );
  }

  double? _cpuPercentFromDelta(HostStats? host) {
    if (host == null) return null;
    final now = DateTime.now();
    final prevTime = _prevCpuTime;
    final prevSample = _prevCpuSample;
    _prevCpuTime = host.cpuTimeSecs;
    _prevCpuSample = now;
    if (prevTime == null || prevSample == null) return null;
    final dWall = now.difference(prevSample).inMilliseconds / 1000.0;
    if (dWall <= 0) return null;
    final dCpu = host.cpuTimeSecs - prevTime;
    final pct = (dCpu / dWall) * 100.0 / (host.numCpus == 0 ? 1 : host.numCpus);
    return pct.clamp(0.0, 100.0).toDouble();
  }

  void _pushTrend(HudAggregate agg) {
    _trend.add(
      HudTrendPoint(
        t: DateTime.now(),
        cpu: agg.cpuPercent ?? 0,
        gpuDec: agg.host?.gpuDecUtil,
        drops: agg.dropsPerSec,
        decodeFps: agg.decodeFps,
        netMbps: agg.netMbps,
      ),
    );
    if (_trend.length > _trendMax) _trend.removeAt(0);
  }

  // ── Status-bar perf alert (app.js `updateStatusAlert`) ─────────────────────

  /// Empty string when healthy; otherwise a short "⚠ 2.1 drops/s · CPU 91%"
  /// style summary for a status-bar banner. Reflects the LAST sample, updates
  /// even while the F8 footer is off.
  String get statusAlertText {
    final agg = _lastAggregate;
    if (agg == null) return '';
    final parts = <String>[];
    if (agg.dropsPerSec >= 1) {
      parts.add('⚠ ${agg.dropsPerSec.toStringAsFixed(1)} drops/s');
    }
    final cpu = agg.cpuPercent;
    if (cpu != null && cpu >= 85) parts.add('CPU ${cpu.round()}%');
    final gdec = agg.host?.gpuDecUtil;
    if (gdec != null && gdec >= 90) parts.add('GPU decode ${gdec.round()}%');
    return parts.join(' · ');
  }

  /// Tooltip text for one tile's health dot (app.js `hudUpdateBadges`'s
  /// `dot.title`).
  String tooltipFor(String paneId) {
    final s = _lastPaneStats[paneId];
    if (s == null) return 'no signal';
    final res = s.height > 0 ? '${s.height}p' : '—';
    final hwLabel = s.isHardwareDecoded ? s.hwdec : 'CPU decode';
    final dps = _dropsPerSecByPane[paneId] ?? 0;
    final buf = StringBuffer(
      '$res · ${s.decodeFps.toStringAsFixed(0)}/'
      '${s.containerFps.toStringAsFixed(0)} fps · $hwLabel',
    );
    if (s.videoMegabits > 0) {
      buf.write(' · ${s.videoMegabits.toStringAsFixed(1)} Mbps');
    }
    if (dps >= 1) buf.write(' · ${dps.toStringAsFixed(0)} drops/s');
    return buf.toString();
  }

  double dropsPerSecFor(String paneId) => _dropsPerSecByPane[paneId] ?? 0;

  // ── Benchmark: "how many full-res streams can this box take" ───────────────
  //
  // app.js `hudRunBenchmark`: switch every wall tile to its full-res MAIN
  // stream for ~12s and report the sustained decode load. Since tile stream
  // selection lives in the host screen (not this file — see class doc), the
  // caller supplies `switchToFullRes`/`restore` hooks that do that swap; this
  // method only owns sampling + verdict math.

  /// Runs the stress test. `switchToFullRes` should re-point every visible
  /// tile at its main stream (e.g. toggle a "benchmark mode" flag the host
  /// screen's tile widgets read) and return once that's kicked off;
  /// `restore` undoes it. Both may safely be no-ops if the host screen has no
  /// sub/main distinction. Throws if a benchmark is already running.
  Future<BenchmarkResult?> runBenchmark({
    required Future<void> Function() switchToFullRes,
    required Future<void> Function() restore,
    void Function(String status)? onStatus,
    int warmupMs = 4500,
    int sampleSeconds = 12,
  }) async {
    if (_benchmarkRunning) {
      throw StateError('a benchmark is already running');
    }
    if (_panes.isEmpty) return null;

    _benchmarkRunning = true;
    stop(); // suspend the normal adaptive-cadence tick loop
    notifyListeners();

    final samples = <HudAggregate>[];
    try {
      await switchToFullRes();
      onStatus?.call('Switching the wall to full-res main streams…');
      await Future.delayed(Duration(milliseconds: warmupMs));
      for (var i = 0; i < sampleSeconds; i++) {
        await Future.delayed(const Duration(seconds: 1));
        await _sampleOnce();
        notifyListeners();
        final agg = _lastAggregate;
        if (agg != null) samples.add(agg);
        onStatus?.call('Measuring full-res load… ${i + 1}/$sampleSeconds');
      }
    } finally {
      await restore();
      _benchmarkRunning = false;
      _ensureRunning();
      notifyListeners();
    }

    if (samples.isEmpty) {
      onStatus?.call('No samples captured.');
      return null;
    }

    double avg(Iterable<double> xs) => xs.isEmpty
        ? 0
        : xs.reduce((a, b) => a + b) / xs.length;
    double peak(Iterable<double> xs) =>
        xs.isEmpty ? 0 : xs.reduce(math.max);

    final streams = samples.last.streams;
    final peakDrops = peak(samples.map((s) => s.dropsPerSec));
    final avgDec = avg(samples.map((s) => s.decodeFps));
    final avgTgt = avg(samples.map((s) => s.containerFps));
    final ratio = avgTgt > 0 ? avgDec / avgTgt : 1.0;
    final peakCpu = peak(samples.map((s) => s.cpuPercent ?? 0));
    final gpuVals = samples
        .map((s) => s.host?.gpuDecUtil)
        .whereType<double>()
        .toList(growable: false);
    final peakGpu = gpuVals.isEmpty ? null : gpuVals.reduce(math.max);

    String verdict;
    bool healthy;
    if (peakDrops < 1 && ratio > 0.95) {
      verdict = 'Sustained cleanly';
      healthy = true;
    } else if (peakDrops < 5) {
      verdict = 'Minor drops under load';
      healthy = true;
    } else {
      verdict = 'Overloaded — dropping frames';
      healthy = false;
    }
    onStatus?.call('');

    return BenchmarkResult(
      streams: streams,
      peakDropsPerSec: peakDrops,
      decodeRatio: ratio,
      peakCpuPercent: peakCpu,
      peakGpuDecPercent: peakGpu,
      verdict: verdict,
      healthy: healthy,
    );
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
