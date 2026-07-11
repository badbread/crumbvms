// Slot-based wall layout state — port of the old Tauri client's `state.slotMap`
// / `state.maximized` (apps/desktop/src/app.js). A "slot" is a tile position in
// the wall grid; slots can be empty or hold one camera id. This is a thin,
// UI-framework-agnostic controller so the context menu (and, eventually, the
// wall grid itself) can share one source of truth for "what camera is showing
// where" and "which slot is maximized right now".
//
// NOTE for integration: the current `wall_screen.dart` renders tiles directly
// from `widget.cameras` (one tile per enabled camera, no empty slots, no
// re-assignment). Wiring this controller in means the grid must be driven by
// slot INDEX (0..slotCount-1) instead of camera list order — see
// integrationNotes from this change for the concrete wiring.

import 'package:flutter/foundation.dart';

/// Which slot (if any) is currently maximized, and which camera occupies it.
/// Mirrors app.js `state.maximized = { slotIndex, cameraId }`.
class MaximizedSlot {
  const MaximizedSlot({required this.slotIndex, required this.cameraId});
  final int slotIndex;
  final String cameraId;
}

/// Owns the slot → camera assignment for one wall layout, plus the maximized
/// override. Commercial-VMS-style "set camera": assigning a camera to a slot
/// removes it from any other slot it currently occupies (a camera can only be
/// shown once at a time), matching app.js's `ctxOpen` "Set camera" handler.
class WallSlotController extends ChangeNotifier {
  WallSlotController({Map<int, String>? initialSlotMap})
    : _slotMap = Map<int, String>.from(initialSlotMap ?? const {});

  final Map<int, String> _slotMap; // slot index -> camera id
  MaximizedSlot? _maximized;

  /// Read-only view of the current slot assignments.
  Map<int, String> get slotMap => Map.unmodifiable(_slotMap);

  MaximizedSlot? get maximized => _maximized;

  /// The camera id showing at `slot` right now, honouring the maximize
  /// override the same way app.js's `ctxOpen` does: if `slot` is the
  /// maximized slot, resolve to the maximized camera (which may have been
  /// maximized from OUTSIDE this slot's normal occupant), not whatever the
  /// slot map says.
  String? cameraIdForSlot(int slot) {
    final max = _maximized;
    if (max != null && max.slotIndex == slot) return max.cameraId;
    return _slotMap[slot];
  }

  bool get isAnyMaximized => _maximized != null;

  bool isMaximized(int slot) => _maximized?.slotIndex == slot;

  /// "Set camera" → cam: move `cameraId` into `slot`, removing it from
  /// wherever else it currently lives (there can be only one live tile per
  /// camera at a time).
  void assignCamera(int slot, String cameraId) {
    _slotMap.removeWhere((_, id) => id == cameraId);
    _slotMap[slot] = cameraId;
    notifyListeners();
  }

  /// "Set camera" → (empty): clear the slot.
  void clearSlot(int slot) {
    _slotMap.remove(slot);
    notifyListeners();
  }

  /// Maximize/Restore toggle for `slot`, mirroring app.js's
  /// `handleTileDoubleClick` / ctx-menu "Maximize"/"Restore" item.
  void toggleMaximize(int slot) {
    final cam = cameraIdForSlot(slot);
    if (_maximized != null && _maximized!.slotIndex == slot) {
      _maximized = null;
    } else if (cam != null) {
      _maximized = MaximizedSlot(slotIndex: slot, cameraId: cam);
    }
    notifyListeners();
  }

  void restore() {
    if (_maximized == null) return;
    _maximized = null;
    notifyListeners();
  }
}
