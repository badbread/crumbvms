// Tracks which video pane is currently "active" (maximized, else the
// selected tile) so the snapshot hotkey/button knows which mpv-backed
// [Player] to grab a frame from.
//
// The old Tauri client resolved this the same way: `snapshotActivePane`
// (apps/desktop/src/app.js:4154) picked `state.maximized ? ... :
// state.selectedSlot`, then the Rust side looked the mpv handle up by pane id
// out of `AppState.panes` (apps/desktop/src-tauri/src/lib.rs:1234,
// `snapshot_pane`). media_kit already gives each Flutter-side pane its own
// [Player] object (see lib/ui/wall_screen.dart `_WallTileState`/
// `_MaximizedPaneState`), so there's no native pane map to keep in sync here
// — this is purely the "which pane is active" bookkeeping, done in Dart.
//
// Any screen with capturable video panes (live wall, playback, the clip
// player) registers/unregisters its panes here and marks one active on
// selection/maximize. See integrationNotes for the exact call sites.

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// One capturable video pane: a live mpv-backed [Player] plus enough
/// metadata to name the saved snapshot file.
class SnapshotTarget {
  const SnapshotTarget({required this.player, required this.cameraName});

  final Player player;

  /// Used only for the saved filename (sanitized) — cosmetic, not an id.
  final String cameraName;
}

class SnapshotRegistry {
  SnapshotRegistry._();

  static final SnapshotRegistry instance = SnapshotRegistry._();

  final Map<String, SnapshotTarget> _panes = <String, SnapshotTarget>{};

  /// Id of the pane the S hotkey / snapshot button should capture, e.g.
  /// `"slot3"` or `"maximized"` — caller's choice of scheme, mirroring the
  /// old client's `slot${slot}` pane ids.
  final ValueNotifier<String?> activePaneId = ValueNotifier<String?>(null);

  /// Call from the pane's `initState` (once its [Player] exists).
  void register(String paneId, SnapshotTarget target) {
    _panes[paneId] = target;
  }

  /// Call from the pane's `dispose`.
  void unregister(String paneId) {
    _panes.remove(paneId);
    if (activePaneId.value == paneId) {
      activePaneId.value = null;
    }
  }

  /// Call on selection change / maximize / un-maximize. Pass `null` when
  /// nothing is selected (e.g. the wall was just built and nothing has been
  /// clicked yet).
  void setActive(String? paneId) {
    activePaneId.value = paneId;
  }

  /// The pane [SnapshotService.captureActivePane] will grab a frame from, or
  /// `null` if nothing is active / the active pane already unregistered
  /// (torn down mid-rebuild).
  SnapshotTarget? get active {
    final id = activePaneId.value;
    if (id == null) return null;
    return _panes[id];
  }
}
