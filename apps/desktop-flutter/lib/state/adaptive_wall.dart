// Adaptive live-wall quality: the client-local decode-management brain for
// issue #382. Two interlocking stages keep a mis-set (all-main) wall from
// melting the client's video decoder — the cameras themselves are shielded by
// the go2rtc restream, so the only ceiling that bites is the LOCAL GPU/CPU
// decode load, which grows linearly with (main-tile count x resolution).
//
//   Stage 1 — soft guardrail (preventive, config time): when the user makes a
//   change that would over-subscribe the wall (wall default -> main, a
//   per-camera -> main), predict the resulting decode load and, if it would
//   cross the 75% ceiling, surface an advisory nudge BEFORE anything
//   saturates. Never blocks — the operator can proceed.
//
//   Stage 2 — adaptive backpressure (reactive, runtime): if saturation happens
//   anyway (proceeded, or conditions drift — a camera bumps resolution,
//   thermal throttle shrinks headroom), shed peripheral tiles to their sub
//   stream when smoothed decode util stays above 85% and restore them once it
//   falls back below 60%. Hysteresis (60/85 gap, shed-fast / restore-slow)
//   prevents flapping.
//
// The 75 < 85 relationship is enforced by construction here, so the predictive
// warning always fires before the reactive shedder engages.
//
// The signal is the SAME whole-GPU decode util the wall already samples
// (`HostStats.gpuDecUtil`, the "Decode NN%" status-bar readout), smoothed over
// a ~3s window so it rides keyframe bursts. Fallback: if `gpuDecUtil` is null
// (software decode / no counter) backpressure keys off CPU decode util; if
// neither is available, only the count-based guardrail runs — we never assume
// unmeasurable headroom.
//
// Everything here is CLIENT-LOCAL (a workstation and a laptop have different
// budgets). No server change. See docs/DECISIONS.md (2026-07-20).

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'client_options.dart';
import 'stream_prefs.dart';

/// One tile the wall has registered with the adaptive controller. Mutable and
/// re-synced from the tile's build so the controller always sees current
/// visibility / focus / measured resolution without re-plumbing telemetry.
class _AdaptiveTile {
  _AdaptiveTile({
    required this.cameraId,
    required this.wallOrder,
    required this.visible,
    required this.protectedTile,
    required this.canDowngrade,
    required this.measuredHeight,
  });

  String cameraId;

  /// Position in the wall (slot/reading order). Lower = added earlier / nearer
  /// the top-left. Drives shed order.
  int wallOrder;

  /// On-screen (not scrolled out of view). Off-screen tiles are shed first.
  bool visible;

  /// The focused / hovered / zoomed-to-main / maximized tile. NEVER shed.
  bool protectedTile;

  /// The camera actually has a sub stream to fall back to — a tile with no sub
  /// can't be shed to a lighter tier, so it's never chosen as a victim.
  bool canDowngrade;

  /// Last decoded pixel height (0 until a frame is measured). Feeds the
  /// cold-start resolution weighting.
  int measuredHeight;
}

/// What the user picked in the guardrail nudge.
enum GuardrailChoice {
  /// Cancel the change — keep the wall on sub.
  keepSub,

  /// Apply the change anyway (this once).
  proceed,

  /// Apply, and never warn again on this machine (persists a client-local flag).
  dontWarnOnThisMachine,
}

/// Result of a guardrail prediction — whether a projected main-tile load would
/// over-subscribe this machine's decoder, and the numbers behind that call so
/// the nudge can explain itself.
class GuardrailAssessment {
  const GuardrailAssessment({
    required this.overSubscribed,
    required this.projectedMainCount,
    required this.coldStart,
    this.projectedUtil,
    this.weightedLoad,
  });

  /// True when the prediction crosses the [AdaptiveWallController.guardrailCeiling].
  final bool overSubscribed;

  /// How many full-res main tiles the change would leave running.
  final int projectedMainCount;

  /// True when there were no main tiles / no measured signal to learn a
  /// per-main cost from, so the resolution-weighted count budget was used
  /// instead of the learned-util path.
  final bool coldStart;

  /// Learned path: predicted whole-GPU decode util (%), = cost-per-main x count.
  final double? projectedUtil;

  /// Cold-start path: resolution-weighted 1080p-equivalent main load.
  final double? weightedLoad;
}

/// The two-stage adaptive wall brain. App-scoped (outlives any single wall
/// build) so both the live wall (which feeds it samples + a tile registry) and
/// the Settings panel (which asks it to predict a config change) share one
/// instance and one learned cost model.
class AdaptiveWallController extends ChangeNotifier {
  AdaptiveWallController({required this.options, required this.streamPrefs});

  final ClientOptionsStore options;
  final StreamPrefsStore streamPrefs;

  // ── Thresholds (client-local defaults; 75 < 85 by construction) ──
  /// Reactive shed line: smoothed util above this for [shedDwell] sheds a tile.
  static const double shedLine = 85.0;

  /// Reactive restore line: smoothed util below this for [restoreDwell]
  /// promotes a shed tile back.
  static const double restoreLine = 60.0;

  /// Preventive guardrail ceiling: a projected load above this warns at config
  /// time. Strictly below [shedLine] so the warning always precedes the shedder.
  static const double guardrailCeiling = 75.0;

  static const Duration shedDwell = Duration(seconds: 4);
  static const Duration shedCooldown = Duration(seconds: 3);
  static const Duration restoreDwell = Duration(seconds: 20);

  /// EMA time constant (seconds) for the ~3s smoothing window.
  static const double _smoothingTauSecs = 3.0;

  /// Cold-start budget in 1080p-equivalent main streams (a 4K main counts ~4x).
  /// Conservative per-machine default; a strong box that proceeds past the
  /// nudge is still caught by Stage 2.
  static const double coldStartMainBudget = 6.0;

  double? _smoothedGpu;
  double? _smoothedCpu;
  DateTime? _lastSampleAt;

  DateTime? _aboveSince; // continuous >shedLine start
  DateTime? _belowSince; // continuous <restoreLine start
  DateTime? _lastShedAt;

  final Map<String, _AdaptiveTile> _tiles = {};
  final Set<String> _shed = {}; // paneIds currently forced to sub

  /// The smoothed decode-util signal the stages key off: whole-GPU decode util
  /// when a counter exists, else CPU decode util, else null (no measurable
  /// headroom — only the count guardrail runs).
  double? get smoothedUtil => _smoothedGpu ?? _smoothedCpu;

  /// Whether a given wall pane is currently shed to sub by backpressure.
  bool isShed(String paneId) => _shed.contains(paneId);

  /// How many panes are currently auto-shed (for a status/debug readout).
  int get shedCount => _shed.length;

  // ── Signal intake ─────────────────────────────────────────────────────────

  /// Feed one host-stats sample (called from the wall's ~2s stats poll). Nulls
  /// are treated as "no reading" (the last known value is kept), NOT as zero —
  /// a missing counter must never look like free headroom. Cadence-independent:
  /// the EMA weight is derived from the real elapsed time between samples, and
  /// the state machine measures dwell against the wall clock, so a slower or
  /// jittery poll cadence doesn't change the 4s / 20s behavior.
  void pushSample({double? gpuDecUtil, double? cpuPercent, DateTime? at}) {
    final now = at ?? DateTime.now();
    final prev = _lastSampleAt;
    _lastSampleAt = now;
    final dt = prev == null
        ? null
        : now.difference(prev).inMilliseconds / 1000.0;
    final alpha = (dt == null || dt <= 0)
        ? 1.0
        : (1.0 - math.exp(-dt / _smoothingTauSecs));
    _smoothedGpu = _ema(_smoothedGpu, gpuDecUtil, alpha);
    _smoothedCpu = _ema(_smoothedCpu, cpuPercent, alpha);
    _evaluateBackpressure(now);
  }

  static double? _ema(double? prev, double? sample, double alpha) {
    if (sample == null) return prev; // no reading — keep last known, not 0
    if (prev == null) return sample;
    return prev + alpha * (sample - prev);
  }

  // ── Tile registry (re-synced from each tile's build; never notifies) ───────

  /// Register / refresh a wall tile. Safe to call from a tile's build: it only
  /// mutates the registry (guardrail predictions are pull-based) and never
  /// notifies — with ONE exception: if the operator focuses a tile that was
  /// shed, it is promoted back immediately (a deferred notify, so we never
  /// notify during a build).
  void syncTile(
    String paneId, {
    required String cameraId,
    required int wallOrder,
    required bool visible,
    required bool protectedTile,
    required bool canDowngrade,
    required int measuredHeight,
  }) {
    final t = _tiles[paneId];
    if (t == null) {
      _tiles[paneId] = _AdaptiveTile(
        cameraId: cameraId,
        wallOrder: wallOrder,
        visible: visible,
        protectedTile: protectedTile,
        canDowngrade: canDowngrade,
        measuredHeight: measuredHeight,
      );
    } else {
      t.cameraId = cameraId;
      t.wallOrder = wallOrder;
      t.visible = visible;
      t.protectedTile = protectedTile;
      t.canDowngrade = canDowngrade;
      t.measuredHeight = measuredHeight;
    }
    // Never leave the focused/hovered/zoomed tile shed — give it its configured
    // quality back the moment it becomes protected.
    if (protectedTile && _shed.remove(paneId)) {
      Future.microtask(notifyListeners);
    }
  }

  void dropTile(String paneId) {
    _tiles.remove(paneId);
    _shed.remove(paneId); // no notify — the tile is gone
  }

  // ── Cost model ─────────────────────────────────────────────────────────────

  bool _isConfiguredMain(String cameraId) =>
      streamPrefs.effectiveFor(cameraId) == StreamQuality.main;

  /// Main tiles ACTUALLY decoding main right now (configured main AND not shed)
  /// — the denominator for the learned per-main cost.
  int get _currentMainCount {
    var n = 0;
    for (final e in _tiles.entries) {
      if (_isConfiguredMain(e.value.cameraId) && !_shed.contains(e.key)) n++;
    }
    return n;
  }

  /// Learned decode cost of one main tile: smoothed util / current main count.
  /// Null when there's nothing to learn from (no mains, or no signal) — the
  /// guardrail then falls back to the cold-start weighted count.
  double? get _costPerMain {
    final u = smoothedUtil;
    final n = _currentMainCount;
    if (u == null || n <= 0) return null;
    return u / n;
  }

  /// Relative decode weight of a stream by pixel height, normalized so a 1080p
  /// main = 1.0 (decode cost scales roughly with pixel count, so a 4K main is
  /// ~4x). Clamped to a sane band. `0` height (unmeasured) counts as 1080p.
  double weightFor(int height) {
    if (height <= 0) return 1.0;
    final r = height / 1080.0;
    return (r * r).clamp(0.25, 4.0);
  }

  GuardrailAssessment _assess(int projectedMainCount, List<int> knownHeights) {
    final cpm = _costPerMain;
    if (cpm != null) {
      final util = cpm * projectedMainCount;
      return GuardrailAssessment(
        overSubscribed: util > guardrailCeiling,
        projectedMainCount: projectedMainCount,
        coldStart: false,
        projectedUtil: util,
      );
    }
    // Cold start: resolution-weighted count budget. We weight the mains whose
    // resolution we've actually measured; any we haven't count as one 1080p
    // main each. (Per-camera main-stream resolution from the server probe is
    // not surfaced to this client, so measured live pane height is the best
    // available resolution signal.)
    var load = 0.0;
    for (final h in knownHeights) {
      load += weightFor(h);
    }
    final unmeasured = projectedMainCount - knownHeights.length;
    if (unmeasured > 0) load += unmeasured;
    return GuardrailAssessment(
      overSubscribed: load > coldStartMainBudget,
      projectedMainCount: projectedMainCount,
      coldStart: true,
      weightedLoad: load,
    );
  }

  // ── Stage 1: guardrail predictions ─────────────────────────────────────────

  /// Predict the load if the wall default became [newDefault]. A tile follows
  /// the new default unless it has an explicit per-camera override.
  GuardrailAssessment assessWallDefault(StreamQuality newDefault) {
    final heights = <int>[];
    var count = 0;
    for (final t in _tiles.values) {
      final eff = streamPrefs.hasOverride(t.cameraId)
          ? streamPrefs.effectiveFor(t.cameraId)
          : newDefault;
      if (eff == StreamQuality.main) {
        count++;
        if (t.measuredHeight > 0) heights.add(t.measuredHeight);
      }
    }
    return _assess(count, heights);
  }

  /// Predict the load if [cameraId] were switched to its main stream (the
  /// current configured mains, plus this camera if it isn't already one).
  GuardrailAssessment assessCameraMain(String cameraId) {
    final heights = <int>[];
    var count = 0;
    var includesTarget = false;
    for (final t in _tiles.values) {
      final isTarget = t.cameraId == cameraId;
      if (isTarget) includesTarget = true;
      if (isTarget || _isConfiguredMain(t.cameraId)) {
        count++;
        if (t.measuredHeight > 0) heights.add(t.measuredHeight);
      }
    }
    if (!includesTarget) count++; // camera isn't on the wall right now
    return _assess(count, heights);
  }

  // ── Stage 2: reactive backpressure state machine ───────────────────────────

  void _evaluateBackpressure(DateTime now) {
    if (!options.adaptiveWallBackpressure) {
      // Feature off — release anything we shed and reset the timers.
      _aboveSince = null;
      _belowSince = null;
      if (_shed.isNotEmpty) {
        _shed.clear();
        notifyListeners();
      }
      return;
    }

    final u = smoothedUtil;
    if (u == null) {
      // No measurable signal at all → only the count guardrail can help; the
      // reactive shedder can't act on headroom it can't see.
      _aboveSince = null;
      _belowSince = null;
      return;
    }

    var changed = false;

    if (u > shedLine) {
      _belowSince = null;
      _aboveSince ??= now;
      final dwellOk = now.difference(_aboveSince!) >= shedDwell;
      final cooldownOk =
          _lastShedAt == null || now.difference(_lastShedAt!) >= shedCooldown;
      if (dwellOk && cooldownOk) {
        final victim = _nextShedVictim();
        if (victim != null) {
          _shed.add(victim);
          _lastShedAt = now;
          changed = true;
        }
      }
    } else if (u < restoreLine) {
      _aboveSince = null;
      _belowSince ??= now;
      if (now.difference(_belowSince!) >= restoreDwell) {
        final promote = _nextRestoreCandidate();
        if (promote != null) {
          _shed.remove(promote);
          changed = true;
        }
        // Require another full quiet window before the next promote; if util
        // climbs back over restoreLine before then, the timer resets (above),
        // so we stop restoring the moment load rises.
        _belowSince = null;
      }
    } else {
      // Hysteresis band (restoreLine..shedLine): hold — neither shed nor restore.
      _aboveSince = null;
      _belowSince = null;
    }

    if (changed) notifyListeners();
  }

  /// The next tile to shed: off-screen tiles first, then lowest wall-order
  /// first, never a protected (focused/hovered/zoomed/maximized) or
  /// already-shed tile, and only tiles that (a) are configured to main and
  /// (b) actually have a sub to fall back to.
  String? _nextShedVictim() {
    final candidates = _tiles.entries
        .where(
          (e) =>
              !_shed.contains(e.key) &&
              !e.value.protectedTile &&
              e.value.canDowngrade &&
              _isConfiguredMain(e.value.cameraId),
        )
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final va = a.value.visible ? 1 : 0; // off-screen (0) first
      final vb = b.value.visible ? 1 : 0;
      if (va != vb) return va - vb;
      return a.value.wallOrder.compareTo(b.value.wallOrder); // lowest order first
    });
    return candidates.first.key;
  }

  /// The next shed tile to promote back: the reverse of the shed order, so the
  /// most-protected tiles (on-screen, highest wall-order) regain full quality
  /// first. Also drops any stale ids left by removed tiles.
  String? _nextRestoreCandidate() {
    final entries = <MapEntry<String, _AdaptiveTile>>[];
    for (final p in _shed) {
      final t = _tiles[p];
      if (t != null) entries.add(MapEntry(p, t));
    }
    if (entries.isEmpty) {
      // Only stale ids remain — clean one out so the shed set drains.
      return _shed.isNotEmpty ? _shed.first : null;
    }
    entries.sort((a, b) {
      final va = a.value.visible ? 0 : 1; // on-screen (0) restored first
      final vb = b.value.visible ? 0 : 1;
      if (va != vb) return va - vb;
      return b.value.wallOrder.compareTo(a.value.wallOrder); // highest order first
    });
    return entries.first.key;
  }
}
