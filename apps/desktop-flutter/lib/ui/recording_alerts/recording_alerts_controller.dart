// Background poller + warning computation for the recording-health alert
// banner. Ported from apps/desktop/src/app.js's `computeRecordingWarnings` /
// `pollRecordingAlerts` (recording-at-risk alert) and `srvRenderHeartbeat`
// (recorder heartbeat staleness), which are otherwise identical logic
// re-implemented in Dart against the same two endpoints.
//
// Surfaces three families of warning, each computed from data the app is
// already fetching for other reasons (no new server work):
//   1. A physical recording disk running low/out of free space (real statvfs
//      free space — NOT a size-budget "full", which is normal eviction).
//   2. A recording policy whose size budget evicts footage before its
//      configured time retention ("under-provisioned").
//   3. A recording policy sitting >10% over its size budget (eviction can't
//      keep up — archive disk full, or eviction stuck).
//   4. The recorder's liveness heartbeat going stale or missing (no
//      corresponding warning existed as a *banner* item in the old client —
//      it was a Settings-only badge — but the feature ask here explicitly
//      wants it surfaced the same way).
//
// Poll cadence matches the old client's `startRecordingAlertPoll` (60s, not
// the 5-minute figure sometimes quoted for this feature — the actual
// `setInterval` in app.js is 60000ms).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/crumb_api.dart';
import '../../api/models.dart';
import '../../api/recording_alerts_api.dart';
import '../../api/recording_alerts_models.dart';

// A recorded disk below these thresholds is about to start dropping
// recordings. Mirrors app.js's DISK_FREE_WARN_PCT / DISK_FREE_CRIT_PCT /
// DISK_FREE_WARN_BYTES / DISK_FREE_CRIT_BYTES exactly.
const double _diskFreeWarnPct = 12;
const double _diskFreeCritPct = 4;
const int _diskFreeWarnBytes = 50 * 1000 * 1000 * 1000; // 50 GB (decimal, matches 1e9 in app.js)
const int _diskFreeCritBytes = 12 * 1000 * 1000 * 1000; // 12 GB

/// Recorder heartbeat age (seconds) beyond which it's considered stale enough
/// to warn about in the banner. Matches the "dead" threshold in
/// `srvRenderHeartbeat` (>= 60s).
const double _heartbeatStaleSecs = 60;

/// Polls `GET /status` + `GET /stats/policies` every 60s and exposes the
/// current list of recording-health warnings. Attach to a long-lived widget
/// (e.g. the wall screen) and call [start] once the session is established;
/// call [dispose] on sign-out / screen teardown.
class RecordingAlertsController extends ChangeNotifier {
  RecordingAlertsController({required this.api, required this.session});

  /// Adopt a refreshed session (in-place re-auth) so the next poll uses the live
  /// token instead of the dead one captured at construction. See #131.
  void updateSession(Session s) => session = s;

  final CrumbApi api;
  Session session;

  Timer? _timer;
  List<RecordingWarning> _warnings = const [];

  List<RecordingWarning> get warnings => _warnings;
  bool get hasCritical =>
      _warnings.any((w) => w.level == RecordingWarningLevel.crit);

  /// Start polling immediately, then every 60s. Safe to call multiple times
  /// (restarts the timer).
  void start() {
    _timer?.cancel();
    unawaited(_poll());
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => unawaited(_poll()));
  }

  /// Stop polling and clear the current warnings (mirrors
  /// `stopRecordingAlertPoll` clearing the banner on sign-out).
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_warnings.isNotEmpty) {
      _warnings = const [];
      notifyListeners();
    }
  }

  Future<void> _poll() async {
    try {
      // Both admin-only; getPolicyStats returns null (not a throw) on 403 so
      // a non-admin session still gets heartbeat/disk warnings from /status
      // where those fields are populated. If /status itself withholds
      // storages/heartbeat too (non-admin), computeWarnings naturally yields
      // nothing from those either — no error state, just an empty banner.
      final status = await api.getRecordingStatus(session);
      final policyStats = await api.getPolicyStats(session);
      final next = computeRecordingWarnings(
        storages: status.storages,
        policies: policyStats?.policies ?? const [],
        recorderHeartbeat: status.recorderHeartbeat,
      );
      _warnings = next;
      notifyListeners();
    } catch (_) {
      // Transient network error — keep showing the last computed state,
      // exactly like pollRecordingAlerts' empty catch block.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Pure computation, ported from `computeRecordingWarnings` +
/// `srvRenderHeartbeat`'s staleness check. Exposed as a top-level function so
/// it's independently testable.
List<RecordingWarning> computeRecordingWarnings({
  required List<RecordingStorageStatus> storages,
  required List<PolicyStat> policies,
  DateTime? recorderHeartbeat,
}) {
  final out = <RecordingWarning>[];

  // 1) Physical disk running out (dedupe by path -> one per physical disk).
  //    Real free space (statvfs), not the size-budget — a budget-full disk
  //    with plenty of physical space is normal eviction, not an alert.
  final seen = <String>{};
  for (final vol in storages) {
    final key = vol.path.isNotEmpty ? vol.path : (vol.name.isNotEmpty ? vol.name : vol.id);
    if (key.isEmpty || !seen.add(key)) continue;
    final total = vol.totalBytes ?? vol.fsTotalBytes;
    final free = vol.freeBytes;
    if (total == null || free == null || total <= 0) continue;
    final pct = (free / total) * 100;
    final nm = vol.name.isNotEmpty ? vol.name : 'Disk';
    if (pct < _diskFreeCritPct || free < _diskFreeCritBytes) {
      out.add(
        RecordingWarning(
          level: RecordingWarningLevel.crit,
          text:
              'Disk "$nm" is ${(100 - pct).toStringAsFixed(0)}% full — only '
              '${_fmtBytes(free)} free. Recording stops when it fills.',
        ),
      );
    } else if (pct < _diskFreeWarnPct || free < _diskFreeWarnBytes) {
      out.add(
        RecordingWarning(
          level: RecordingWarningLevel.warn,
          text:
              'Disk "$nm" is low — ${_fmtBytes(free)} free '
              '(${pct.toStringAsFixed(0)}%). Free space soon or recordings will drop.',
        ),
      );
    }
  }

  // 2) Under-provisioned policy: the size budget evicts footage BEFORE the
  //    configured time retention (binding == 'size') -> recording the
  //    operator expects to keep is being dropped early.
  for (final p in policies) {
    if (p.bindingLimit == 'size') {
      final held = _fmtRetention(p.sizeBoundRetentionHours);
      final target = _fmtRetention(p.liveRetentionHoursCap.toDouble());
      out.add(
        RecordingWarning(
          level: RecordingWarningLevel.warn,
          text:
              '"${p.label}" only holds ~$held of its $target target — older '
              'footage is dropped early. Raise its size budget or add storage.',
        ),
      );
    }
  }

  // 3) Over budget AND not catching up: a capped policy whose live usage is
  //    well OVER its cap means eviction can't keep it under control (archive
  //    disk full, or eviction stuck). 10% margin never trips on normal
  //    operation.
  for (final p in policies) {
    final cap = p.liveMaxBytes ?? 0;
    final used = p.liveUsedBytes;
    if (cap > 0 && used > cap * 1.10) {
      final overPct = ((used / cap - 1) * 100).toStringAsFixed(0);
      out.add(
        RecordingWarning(
          level: RecordingWarningLevel.warn,
          text:
              '"${p.label}" is $overPct% over its size budget '
              '(${_fmtBytes(used)} / ${_fmtBytes(cap)}). Eviction is catching '
              'up — if it persists, the archive disk may be full or eviction is stuck.',
        ),
      );
    }
  }

  // 4) Recorder heartbeat staleness (srvRenderHeartbeat's "dead" state,
  //    surfaced here as a banner item rather than only a Settings badge).
  if (recorderHeartbeat == null) {
    // No heartbeat ever recorded is ambiguous for non-admin sessions (the
    // field is silently withheld, not populated as null-meaning-dead) — only
    // warn when we also have admin-scoped storage data, i.e. we know this is
    // a real "recorder never reported" state rather than a viewer session.
    if (storages.isNotEmpty) {
      out.add(
        RecordingWarning(
          level: RecordingWarningLevel.crit,
          text: 'Recorder has never reported a heartbeat — recording is likely not running.',
        ),
      );
    }
  } else {
    final ageSecs = DateTime.now().toUtc().difference(recorderHeartbeat.toUtc()).inSeconds.toDouble();
    if (ageSecs >= _heartbeatStaleSecs) {
      final label = ageSecs < 3600
          ? '${(ageSecs / 60).round()}m ago'
          : '${(ageSecs / 3600).toStringAsFixed(1)}h ago';
      out.add(
        RecordingWarning(
          level: RecordingWarningLevel.crit,
          text: 'Recorder heartbeat is stale ($label) — recording may not be running.',
        ),
      );
    }
  }

  return out;
}

String _fmtBytes(num? bytes) {
  if (bytes == null) return '—';
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
  final mb = bytes / (1024 * 1024);
  return '${mb.round()} MB';
}

String _fmtRetention(double? hours) {
  if (hours == null || hours <= 0) return '—';
  if (hours < 48) return '${hours.round()} h';
  return '${(hours / 24).toStringAsFixed(1)} d';
}
