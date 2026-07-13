// Live stall watchdog — detects a frozen/black live pane and reconnects it,
// with per-pane exponential backoff and a fleet-wide herd cap so a shared
// blip can't fire a reconnect storm. Ported from `liveStallWatchdog` /
// `tryReconnectPane` in apps/desktop/src/app.js (the Tauri client), which
// polled `invoke('live_pane_progress')` — a Rust command reading libmpv's
// `time-pos` for each natively-compositied pane — every ~3 s.
//
// There is no Rust IPC layer in the Flutter client: media_kit's [Player]
// lives in-process, so this polls the player's own state directly instead.
// The two JS stall signals map as follows:
//   - "time-pos < 0" (RTSP probe wedged: TCP up, no media, no time-pos ever)
//     → "no frame has been decoded yet this connection" (`player.state.width`
//       stays null/0 until the first frame decodes).
//   - "time-pos unchanged since last poll" (frozen decode on a live source)
//     → "player.state.position unchanged since last poll" (a live RTSP feed's
//       PTS-derived position climbs continuously as long as frames decode).
//
// Backoff/herd-cap tunables are numerically identical to app.js so the
// client's reconnect behavior (fast phase, slow "never give up" phase, herd
// cap) doesn't change just because the pane is now Flutter-native.

import 'dart:async';
import 'dart:math' as math;

import 'package:media_kit/media_kit.dart';

class StallWatchdogConfig {
  const StallWatchdogConfig({
    this.pollInterval = const Duration(seconds: 3),
    this.stallPollsToConfirm = 2, // ~6s of no progress = stalled
    this.noPosPollsToConfirm = 4, // ~12s with no decoded frame = wedged probe
    this.reconnectBaseMs = 1000,
    this.reconnectMaxMs = 15000,
    this.reconnectFastAttempts = 8,
    this.reconnectSlowMs = 60000, // after the fast phase: never give up
    this.positionEpsilon = const Duration(milliseconds: 50),
  });

  final Duration pollInterval;
  final int stallPollsToConfirm;
  final int noPosPollsToConfirm;
  final int reconnectBaseMs;
  final int reconnectMaxMs;
  final int reconnectFastAttempts;
  final int reconnectSlowMs;
  final Duration positionEpsilon;
}

/// Fleet-wide reconnect budget shared by every [PaneWatchdog] in the process,
/// mirroring app.js's per-tick `MAX_RELOADS_PER_TICK`: a shared blip (e.g. the
/// recorder host or an upstream switch hiccups) can't fire a reconnect storm
/// across every tile at once. Since each pane's poll timer free-runs
/// independently there's no single shared "tick" here — the budget resets on
/// a rolling wall-clock window instead, which is equivalent in effect.
class ReconnectHerdBudget {
  ReconnectHerdBudget._();
  static final ReconnectHerdBudget instance = ReconnectHerdBudget._();

  static const int maxPerWindow = 3; // MAX_RELOADS_PER_TICK
  static const int windowMs = 3000;

  int _windowKey = -1;
  int _used = 0;
  final math.Random _rng = math.Random();

  /// Returns true if a reconnect may proceed now (and consumes one slot in
  /// this window); false if the herd cap for this window is exhausted.
  bool tryConsume() {
    final key = DateTime.now().millisecondsSinceEpoch ~/ windowMs;
    if (key != _windowKey) {
      _windowKey = key;
      _used = 0;
    }
    if (_used >= maxPerWindow) return false;
    _used += 1;
    return true;
  }

  /// Jittered defer amount (ms) for a reconnect that lost the herd-cap race,
  /// matching app.js's `200 + random(1500)`.
  int deferJitterMs() => 200 + _rng.nextInt(1500);

  /// Jittered spacing (ms) added on top of the exponential backoff base, so a
  /// fleet-wide outage doesn't resync into a lockstep reconnect herd. Matches
  /// app.js's `random(1000)`.
  int backoffJitterMs() => _rng.nextInt(1000);
}

class _PaneState {
  int stallPolls = 0;
  int noPosPolls = 0;
  int attempts = 0;
  int nextAtMs = 0; // wall-clock ms; 0 = reconnect allowed now
  Duration? lastPosition;
  bool hasDecodedFrame = false;
}

/// Watches ONE live pane's [Player] for a frozen/black feed and reconnects it
/// automatically. Create one per live tile, call [start] once the player is
/// open, and [dispose] it with the tile.
class PaneWatchdog {
  PaneWatchdog({
    required this.player,
    required this.reconnect,
    this.onReconnectingChanged,
    this.config = const StallWatchdogConfig(),
    ReconnectHerdBudget? herdBudget,
  }) : _herdBudget = herdBudget ?? ReconnectHerdBudget.instance;

  /// The pane's player. Read-only here — [reconnect] owns re-opening it.
  final Player player;

  /// Invoked to reconnect the pane (typically: refetch the stream URL, then
  /// re-open the player on it). Errors are swallowed here, same as app.js's
  /// `invoke('reload_pane', ...).catch(...)` — a reconnect that itself fails
  /// is simply retried on the next backoff tick.
  final Future<void> Function() reconnect;

  /// Fired with `true` when a reconnect attempt starts, `false` on recovery
  /// (position advancing again, or a fresh connection's first decoded
  /// frame). Drive a "Reconnecting…" badge from this.
  final void Function(bool reconnecting)? onReconnectingChanged;

  final StallWatchdogConfig config;
  final ReconnectHerdBudget _herdBudget;

  Timer? _timer;
  final _PaneState _st = _PaneState();
  bool _reconnectingBadge = false;
  bool _disposed = false;
  bool _paused = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(config.pollInterval, (_) => _poll());
  }

  /// Suspend polling without losing accumulated state (e.g. the tile's pane
  /// isn't currently visible — mirrors app.js bailing out of
  /// `liveStallWatchdog` while the Live view is hidden or a modal is open).
  set paused(bool value) => _paused = value;

  /// Call right after a fresh `player.open()` — initial load, or a reconnect
  /// this watchdog didn't itself initiate (e.g. an externally-triggered
  /// tab-return reconnect) — so stale position history from the old
  /// connection doesn't immediately read as "stalled" on the new one.
  void resetBaseline() {
    _st
      ..lastPosition = null
      ..hasDecodedFrame = false
      ..stallPolls = 0
      ..noPosPolls = 0;
  }

  void _setReconnecting(bool on) {
    if (_reconnectingBadge == on) return;
    _reconnectingBadge = on;
    onReconnectingChanged?.call(on);
  }

  void _poll() {
    if (_disposed || _paused) return;
    final state = player.state;
    final width = state.width;
    final pos = state.position;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (width == null || width <= 0) {
      // Never decoded a frame on this connection — either still probing
      // (normal, brief) or wedged (a half-open port that never produces
      // media, so the advance-based stall check below can NEVER catch it).
      // Confirm over N polls before forcing a reconnect so a normal connect
      // isn't cut off mid-handshake.
      _st.noPosPolls += 1;
      if (_st.noPosPolls >= config.noPosPollsToConfirm) {
        if (_tryReconnect(now)) _st.noPosPolls = 0;
      }
      return;
    }

    if (!_st.hasDecodedFrame) {
      // First good frame after probing/reconnecting → recovered.
      _st.hasDecodedFrame = true;
      if (_st.attempts > 0 || _st.stallPolls > 0) _setReconnecting(false);
      _st
        ..stallPolls = 0
        ..attempts = 0
        ..nextAtMs = 0
        ..noPosPolls = 0
        ..lastPosition = pos;
      return;
    }

    final prev = _st.lastPosition;
    _st.lastPosition = pos;
    if (prev == null) return;

    final advanced = (pos - prev).abs() >= config.positionEpsilon;
    if (advanced) {
      if (_st.attempts > 0 || _st.stallPolls > 0) _setReconnecting(false);
      _st
        ..stallPolls = 0
        ..attempts = 0
        ..nextAtMs = 0
        ..noPosPolls = 0;
      return;
    }

    // Stalled = had a valid position last poll and it didn't advance since.
    _st.stallPolls += 1;
    if (_st.stallPolls < config.stallPollsToConfirm) return;
    _tryReconnect(now);
  }

  /// Issues a reconnect if per-pane backoff has elapsed and the shared herd
  /// budget has room this window; otherwise defers with jitter. Returns true
  /// if a reconnect was actually issued.
  bool _tryReconnect(int nowMs) {
    if (_st.nextAtMs != 0 && nowMs < _st.nextAtMs) return false; // backoff not elapsed
    if (!_herdBudget.tryConsume()) {
      _st.nextAtMs = nowMs + _herdBudget.deferJitterMs();
      return false;
    }
    _setReconnecting(true);
    _st.attempts += 1;
    reconnect().catchError((_) {});
    final base = _st.attempts <= config.reconnectFastAttempts
        ? math.min(
            config.reconnectBaseMs * math.pow(2, _st.attempts - 1).toInt(),
            config.reconnectMaxMs,
          )
        : config.reconnectSlowMs;
    _st.nextAtMs = nowMs + base + _herdBudget.backoffJitterMs();
    // A reconnect was just issued: treat this as a fresh connection attempt
    // for stall tracking (don't immediately re-flag "no position" as another
    // failure before the new connection has had a chance to probe).
    _st
      ..stallPolls = 0
      ..hasDecodedFrame = false
      ..lastPosition = null;
    return true;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
