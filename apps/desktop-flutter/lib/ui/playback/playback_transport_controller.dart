// Playback transport controller — play/pause, speed cycling, frame-step, and
// the synced playhead tick that drives every registered pane in lockstep.
//
// Ported from apps/desktop's pbState/pbTick/pbTogglePlay/pbCycleSpeed/
// pbFrameStep (apps/desktop/src/app.js ~L6820-7660, PB_SPEEDS at L6820). The
// old client drove *Tauri-managed* native mpv panes over
// `invoke('set_pane_paused'|'set_pane_speed'|'frame_step_pane', ...)`
// (apps/desktop/src-tauri/src/lib.rs ~L1209-1230); this app's panes ARE
// media_kit `Player` instances living directly in the Flutter widget tree, so
// this controller talks to them in-process instead of over an IPC boundary —
// no Rust/FRB involved.
//
// This controller is intentionally agnostic to segment resolution / pane
// lifecycle (that's owned by the playback grid — a separate feature slice).
// Whoever loads a segment into a slot's Player calls [registerPane]; whoever
// tears a slot down calls [unregisterPane]. Registered slots are exactly the
// set every transport op applies to, mirroring the old client's
// `pbActiveSlots()` (just the maximized slot when one tile is maximized, else
// every visible slot).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Speed multipliers cycled by [PlaybackTransportController.cycleSpeed] —
/// matches the old client's `const SPEEDS = [0.5, 1, 2, 4, 8]` (app.js:6820).
const List<double> kPlaybackSpeeds = <double>[0.5, 1, 2, 4, 8];

/// Drives play/pause, speed, frame-step, and the shared playhead clock for
/// every registered playback pane (one media_kit [Player] per visible tile).
class PlaybackTransportController extends ChangeNotifier {
  PlaybackTransportController({DateTime? initialPlayhead})
    : _playheadMs = (initialPlayhead ?? DateTime.now()).millisecondsSinceEpoch;

  /// Old client ran this work inside a throttled requestAnimationFrame loop;
  /// there's no canvas timeline repaint to throttle independently here, so a
  /// plain periodic timer at the same effective cadence is the natural
  /// Flutter equivalent (pbStartTick, app.js:7498).
  static const Duration _tickInterval = Duration(milliseconds: 250);

  final Map<int, Player> _panes = <int, Player>{};

  bool _playing = false;
  int _speedIndex = 1; // kPlaybackSpeeds[1] == 1x, matches the old default.
  int _playheadMs;
  Timer? _timer;
  DateTime? _lastTickWall;

  /// Fired after the playhead advances during playback — e.g. so segment
  /// resolution can re-resolve/prefetch panes whose segment the playhead is
  /// about to leave (pbResolveAllPanes / pbPrefetchNextSegment in the old
  /// client, app.js:7465-7486). NOT fired for external seeks/scrubs — those
  /// should call [setPlayhead] directly and drive their own re-resolve.
  void Function(DateTime playhead)? onPlayheadAdvance;

  /// Fired once when playback reaches the live edge ("now") and this
  /// controller auto-pauses (pbTick's live-edge stop, app.js:7488-7493).
  VoidCallback? onReachedLiveEdge;

  bool get playing => _playing;
  double get speed => kPlaybackSpeeds[_speedIndex];
  DateTime get playhead => DateTime.fromMillisecondsSinceEpoch(_playheadMs);
  Iterable<int> get registeredSlots => _panes.keys;

  /// Register (or replace) the Player backing [slot]. Immediately applies the
  /// controller's current paused/speed state to it so a pane that loads
  /// mid-playback joins in sync instead of starting paused / at 1x.
  void registerPane(int slot, Player player) {
    _panes[slot] = player;
    unawaited(_applyPausedTo(player));
    unawaited(_applySpeedTo(player));
  }

  /// Unregister a slot (its pane emptied or was torn down). Does NOT dispose
  /// the player — the caller (grid/segment-resolution code) owns that.
  void unregisterPane(int slot) {
    _panes.remove(slot);
  }

  // ── Transport ops ──────────────────────────────────────────────────────

  /// pbTogglePlay (app.js:7615).
  void togglePlay() => setPlaying(!_playing);

  void setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    notifyListeners();
    unawaited(_applyPausedToAll());
  }

  /// pbCycleSpeed (app.js:7649).
  void cycleSpeed() {
    _speedIndex = (_speedIndex + 1) % kPlaybackSpeeds.length;
    notifyListeners();
    unawaited(_applySpeedToAll());
  }

  /// pbFrameStep (app.js:7627). Pauses first (stepping while playing makes no
  /// sense — matches the old client), then steps every registered pane by
  /// exactly 1 frame.
  ///
  /// Uses libmpv's native `frame-step` / `frame-back-step` commands through
  /// the media_kit [NativePlayer] command channel — the same commands the old
  /// client invoked via a Tauri Rust command (src-tauri/src/lib.rs:1219).
  /// These are frame-exact in BOTH directions. Do not "simplify" this back to
  /// a `position ± 1000/fps` seek: mpv resolves backward seeks to the nearest
  /// KEYFRAME, so a seek-based back-step repeatedly snapped to the same
  /// keyframe and appeared dead (the frame-step-stuck bug). The fps-seek
  /// remains only as the fallback for a non-native platform (never the case
  /// on desktop).
  ///
  /// NOTE: this controller is segment-agnostic (see the class doc), so its
  /// step dead-ends at the loaded file's edges. The playback screen's actual
  /// transport uses `GaplessSegmentPaneController.frameStep`, which
  /// additionally crosses segment boundaries and reports the landed frame
  /// time for playhead sync.
  Future<void> frameStep(bool forward) async {
    if (_playing) {
      _playing = false;
      notifyListeners();
      await _applyPausedToAll();
    }
    if (_panes.isEmpty) return;
    final ops = _panes.values.map((p) => _stepOnePane(p, forward));
    await Future.wait(ops);
  }

  Future<void> _stepOnePane(Player player, bool forward) async {
    try {
      final p = player.platform;
      if (p is NativePlayer) {
        // Frame-exact native step (pauses the pane itself — matches the
        // transport pause above).
        await p.command([forward ? 'frame-step' : 'frame-back-step']);
        return;
      }
      // Non-native fallback: approximate a frame by the decoder's estimated
      // fps (assume 30 when unknown) and seek. Backward seeks may snap to a
      // keyframe here — acceptable for a platform that has no native step.
      const frameMs = 1000 ~/ 30;
      final current = player.state.position;
      var target = forward
          ? current + const Duration(milliseconds: frameMs)
          : current - const Duration(milliseconds: frameMs);
      if (target < Duration.zero) target = Duration.zero;
      await player.seek(target);
    } catch (_) {
      // Non-fatal — mirrors the old client's per-slot .catch(warn) in
      // pbFrameStep (app.js:7641-7643).
    }
  }

  // ── Playhead / tick ────────────────────────────────────────────────────

  /// Jump the shared playhead clock to an absolute time — e.g. driven by a
  /// timeline seek/scrub owned elsewhere. Does NOT itself seek any pane;
  /// pane seeking on a jump is owned by whatever resolves segments for the
  /// new time (mirrors the old client's separation between pbState.playheadMs
  /// and pbResolveAllPanes).
  void setPlayhead(DateTime t) {
    _playheadMs = t.millisecondsSinceEpoch;
    notifyListeners();
  }

  /// pbStartTick (app.js:7498) — starts the playhead clock. Idempotent.
  void startTick() {
    if (_timer != null) return;
    _lastTickWall = DateTime.now();
    _timer = Timer.periodic(_tickInterval, _onTick);
  }

  /// pbStopTick.
  void stopTick() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTick(Timer _) {
    final now = DateTime.now();
    final lastWall = _lastTickWall ?? now;
    _lastTickWall = now;
    if (!_playing) return;

    final wallDeltaMs = now.difference(lastWall).inMilliseconds;
    if (wallDeltaMs <= 0) return;

    // Advance the playhead by wall-clock delta * speed, clamped to "now" —
    // can't play into the future (pbTick, app.js:7437-7438).
    final advanceMs = (wallDeltaMs * speed).round();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final proposed = _playheadMs + advanceMs;
    _playheadMs = proposed < nowMs ? proposed : nowMs;
    notifyListeners();
    onPlayheadAdvance?.call(playhead);

    // Pause at the live edge — caught up to "now", nothing more to play
    // (pbTick, app.js:7488-7493).
    if (_playheadMs >= nowMs - 200) {
      _playing = false;
      notifyListeners();
      unawaited(_applyPausedToAll());
      onReachedLiveEdge?.call();
    }
  }

  // ── Apply state to panes ──────────────────────────────────────────────

  Future<void> _applyPausedToAll() =>
      Future.wait(_panes.values.map(_applyPausedTo));

  Future<void> _applyPausedTo(Player player) async {
    try {
      if (_playing) {
        await player.play();
      } else {
        await player.pause();
      }
    } catch (_) {
      // Non-fatal — mirrors invoke('set_pane_paused', ...).catch(() => {})
      // in pbApplyPausedToAllPanes (app.js:7409-7417).
    }
  }

  Future<void> _applySpeedToAll() =>
      Future.wait(_panes.values.map(_applySpeedTo));

  Future<void> _applySpeedTo(Player player) async {
    try {
      await player.setRate(speed);
    } catch (_) {
      // Non-fatal — mirrors invoke('set_pane_speed', ...).catch(() => {}) in
      // pbApplySpeedToAllPanes (app.js:7399-7407).
    }
  }

  @override
  void dispose() {
    stopTick();
    _panes.clear();
    onPlayheadAdvance = null;
    onReachedLiveEdge = null;
    super.dispose();
  }
}
