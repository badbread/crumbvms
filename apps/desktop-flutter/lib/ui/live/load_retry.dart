// Retry-with-backoff for a live pane whose INITIAL stream load failed.
//
// The stall watchdog (pane_watchdog.dart) only exists once a Player has been
// adopted, so a tile whose first `GET /cameras/:id/streams` failed (server
// restarting, timeout, 5xx) had no recovery path at all and stayed on its
// "load failed" icon until it was remounted. [LoadRetry] fills that gap: it
// re-runs the tile's load on the same schedule the watchdog uses (1 s doubling
// to 15 s over the fast phase, then 60 s forever) and draws on the shared
// [ReconnectHerdBudget] so a fleet of failed tiles does not hammer a
// recovering server in lockstep.

import 'dart:async';
import 'dart:math' as math;

import 'pane_watchdog.dart';

class LoadRetry {
  LoadRetry({
    this.config = const StallWatchdogConfig(),
    ReconnectHerdBudget? herdBudget,
  }) : _herdBudget = herdBudget ?? ReconnectHerdBudget.instance;

  final StallWatchdogConfig config;
  final ReconnectHerdBudget _herdBudget;

  Timer? _timer;
  int _attempts = 0;
  bool _disposed = false;

  /// Number of retries scheduled since the last [reset].
  int get attempts => _attempts;

  /// True while a retry is waiting to fire.
  bool get pending => _timer != null;

  /// Base delay (before jitter) for the [attempt]th retry, 1-based: the
  /// watchdog's exponential fast phase, then a flat slow phase.
  static Duration baseDelay(int attempt, StallWatchdogConfig config) {
    final ms = attempt <= config.reconnectFastAttempts
        ? math.min(
            config.reconnectBaseMs * math.pow(2, attempt - 1).toInt(),
            config.reconnectMaxMs,
          )
        : config.reconnectSlowMs;
    return Duration(milliseconds: ms);
  }

  /// Arm the next retry (replacing one already waiting). [retry] runs when the
  /// delay elapses and the herd budget has room.
  void schedule(void Function() retry) {
    if (_disposed) return;
    _timer?.cancel();
    _attempts += 1;
    final delay =
        baseDelay(_attempts, config) +
        Duration(milliseconds: _herdBudget.backoffJitterMs());
    _arm(delay, retry);
  }

  void _arm(Duration delay, void Function() retry) {
    _timer = Timer(delay, () {
      _timer = null;
      if (_disposed) return;
      if (!_herdBudget.tryConsume()) {
        // Lost the fleet-wide race: wait a short jittered beat, no escalation.
        _arm(Duration(milliseconds: _herdBudget.deferJitterMs()), retry);
        return;
      }
      retry();
    });
  }

  /// A load succeeded: forget the failure streak.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _attempts = 0;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
