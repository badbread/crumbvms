// Play-on-focus audio: exactly one live pane is ever audible at a time — the
// ACTIVE pane (the maximized camera if the wall is maximized, else the
// selected/focused camera). Ported from the Tauri client's
// apps/desktop/src/app.js audio-follow-selection state machine
// (activeAudioSlot app.js:3415, reconcileAudio app.js:3457,
// _reconcileAudioImpl app.js:3461, toggleActiveAudio app.js:3471,
// reapplyAudioAfterRebuild app.js:3451, updateAudioButton app.js:3482).
//
// There, the Rust side owned native mpv panes and audio was routed through
// the `set_pane_muted` Tauri command (apps/desktop/src-tauri/src/lib.rs:1145).
// Here each camera pane is a media_kit Player owned directly by Flutter
// (see lib/ui/wall_screen.dart), so muting is a local, synchronous-ish
// player call — no IPC round trip, no "pane may not exist yet" IPC error to
// swallow. The reconcile serialization is kept anyway because pane
// registration is still async (a tile's Player is created after its stream
// URL resolves), so the same interleaving hazard the old client guarded
// against (two fast selection changes racing and leaving two panes unmuted)
// is still possible here.
//
// Invariant: at most one registered pane is ever audible.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// One audio-capable pane registered with the controller. Panes are keyed by
/// a caller-chosen stable id — e.g. the camera id, or a `slot<index>` string
/// if the wall keeps a fixed grid of slots the way the old client did.
class AudioPane {
  AudioPane({required this.setMuted, required this.hasAudio});

  /// Mute/unmute this pane's player. Mirrors Rust `set_pane_muted`
  /// (lib.rs:1145). Implementations should swallow "pane not ready yet"
  /// style errors themselves, or let [AudioFollowController] swallow them —
  /// it already wraps every call in a try/catch, matching app.js
  /// `setPaneAudio`'s swallowed IPC error (app.js:3429).
  final Future<void> Function(bool muted) setMuted;

  /// Whether this pane currently has a playable stream (camera assigned +
  /// stream resolved). Mirrors app.js `slotHasAudio` (app.js:3421) — a pane
  /// with no camera, or no resolved stream, is never a valid audio target.
  final bool Function() hasAudio;

  /// Convenience constructor for a media_kit-backed pane: mutes via the
  /// native mpv `mute` property when available (matches the property set
  /// already applied on pane creation in wall_screen.dart's `_WallTile`),
  /// falling back to `Player.setVolume` on platforms without a NativePlayer.
  factory AudioPane.forPlayer(Player player, {required bool Function() hasAudio}) {
    return AudioPane(
      hasAudio: hasAudio,
      setMuted: (muted) async {
        final platform = player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('mute', muted ? 'yes' : 'no');
        } else {
          await player.setVolume(muted ? 0.0 : 100.0);
        }
      },
    );
  }
}

/// Serialized, single-audible-pane state machine. Own one instance per live
/// wall (e.g. as a field on the `WallScreen` state), register/unregister
/// panes as tiles mount/unmount, and feed selection + maximize changes into
/// [setSelected] / [setMaximized].
class AudioFollowController extends ChangeNotifier {
  final Map<String, AudioPane> _panes = {};

  /// Master enable — persists across selection changes. Mirrors `audioOn`
  /// (app.js:3411).
  bool get audioOn => _audioOn;
  bool _audioOn = false;

  /// The pane id currently unmuted, or null if none is. Mirrors `audioSlot`
  /// (app.js:3412).
  String? get audibleId => _audibleId;
  String? _audibleId;

  /// Maximized pane id, if the wall is maximized (wins over selection).
  String? _maximizedId;

  /// Selected/focused pane id, used when nothing is maximized.
  String? _selectedId;

  /// The pane that SHOULD be audible right now, ignoring audioOn/hasAudio.
  /// Mirrors app.js `activeAudioSlot` (app.js:3415).
  String? get activePaneId => _maximizedId ?? _selectedId;

  Future<void> _chain = Future<void>.value();

  /// Register a pane, e.g. once a tile's Player has opened its stream. Also
  /// kicks a reconcile in case this pane is already the active target and
  /// audio is on — covers the "pane created after the active slot was
  /// already chosen" race that `reapplyAudioAfterRebuild` covers in the old
  /// client via fixed-delay retries (app.js:3451).
  void registerPane(String id, AudioPane pane) {
    _panes[id] = pane;
    unawaited(reconcile());
  }

  /// Unregister a pane, e.g. from the tile's dispose(). If it was the
  /// audible pane, just clear the bookkeeping — no point muting a player
  /// that's being torn down.
  void unregisterPane(String id) {
    _panes.remove(id);
    if (_audibleId == id) _audibleId = null;
  }

  /// Update the selected (non-maximized) pane. Call this from whatever
  /// "select a tile" interaction the wall uses. Mirrors `selectSlot` calling
  /// `reconcileAudio()` unconditionally (app.js:3317) — reconcile is cheap
  /// and idempotent when nothing actually changes.
  void setSelected(String? id) {
    if (_selectedId == id) return;
    _selectedId = id;
    unawaited(reconcile());
  }

  /// Update the maximized pane (pass null when restoring the wall view).
  ///
  /// [paneRecreated] should be true when the underlying Player for the new
  /// active pane is being torn down and rebuilt as part of this transition
  /// (the common case — maximizing/restoring rebuilds tiles in the old
  /// client too, see app.js:3358-3363 and :3368-3372). In that case the old
  /// audible-pane bookkeeping is cleared immediately (the pane is going
  /// away) and reconcile is retried on a delay to land on the new pane once
  /// its Player exists, mirroring `reapplyAudioAfterRebuild` (app.js:3451).
  /// Pass false if the pane persists across the transition (e.g. maximize
  /// reuses the same Player instance) to reconcile immediately instead.
  void setMaximized(String? id, {bool paneRecreated = true}) {
    _maximizedId = id;
    if (paneRecreated) {
      _audibleId = null; // old pane destroyed/rebuilt — app.js:3359, :4123
      reapplyAfterRebuild();
    } else {
      unawaited(reconcile());
    }
  }

  /// Toggle master audio on/off for the active (maximized else selected)
  /// pane. Returns false, leaving state unchanged, if the active pane has no
  /// playable stream — mirrors `toggleActiveAudio`'s "No camera in the
  /// selected tile" guard (app.js:3473); the caller can use the return value
  /// to surface that same status message.
  Future<bool> toggleAudio() async {
    final active = activePaneId;
    final pane = active == null ? null : _panes[active];
    if (pane == null || !pane.hasAudio()) return false;
    _audioOn = !_audioOn;
    await reconcile();
    return true;
  }

  /// Re-run reconcile a couple of times after panes are torn down and
  /// rebuilt. A rebuilt pane's Player is created asynchronously (stream URL
  /// fetch + `player.open`), so a single fixed delay can miss it on a
  /// slow/cold box. Mirrors `reapplyAudioAfterRebuild` (app.js:3451)
  /// exactly, including the two fixed delays — reconcile is idempotent, so a
  /// redundant call once the first one already landed is a no-op.
  void reapplyAfterRebuild() {
    Timer(const Duration(milliseconds: 350), () => unawaited(reconcile()));
    Timer(const Duration(milliseconds: 1100), () => unawaited(reconcile()));
  }

  /// Enforce the invariant: exactly the active pane is unmuted when
  /// [audioOn], nothing is when off. Serialized via a future chain (mirrors
  /// `reconcileChain` / `_reconcileAudioImpl`, app.js:3456-3468) so
  /// overlapping calls from rapid selection changes can't interleave and
  /// leave two panes unmuted at once — each call queues behind the previous
  /// and re-reads the target when it actually runs.
  Future<void> reconcile() {
    _chain = _chain.then(
      (_) => _reconcileImpl(),
      onError: (Object _, StackTrace __) => _reconcileImpl(),
    );
    return _chain;
  }

  Future<void> _reconcileImpl() async {
    final active = activePaneId;
    final activePane = active == null ? null : _panes[active];
    final target =
        (_audioOn && activePane != null && activePane.hasAudio()) ? active : null;
    if (_audibleId == target) {
      notifyListeners(); // state unchanged, but button/listeners may be stale
      return;
    }
    if (_audibleId != null) {
      await _muteQuietly(_audibleId!, true);
    }
    if (target != null) {
      await _muteQuietly(target, false);
    }
    _audibleId = target;
    notifyListeners();
  }

  Future<void> _muteQuietly(String id, bool muted) async {
    final pane = _panes[id];
    if (pane == null) return; // torn down mid-reconcile — nothing to mute
    try {
      await pane.setMuted(muted);
    } catch (_) {
      // Pane's player may not be ready/may already be disposing — matches
      // app.js `setPaneAudio` swallowing the "no such pane" IPC error
      // (app.js:3429-3434).
    }
  }

  @override
  void dispose() {
    _panes.clear();
    super.dispose();
  }
}
