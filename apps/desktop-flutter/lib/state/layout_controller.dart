// Slot state for the managed live wall: which camera sits in which tile,
// which tile is selected, layout-preset switching, click/drag assignment,
// auto-fill, and the "All Cameras" pseudo-view.
//
// Ported from app.js's `state.slotMap` / `state.selectedSlot` /
// `state.layoutId` machinery:
//   - selectSlot                app.js:3309
//   - assignCameraToSelectedSlot app.js:3492
//   - advanceSelectedSlot       app.js:3516
//   - activateLayout            app.js:3536
//   - autoFillSlots             app.js:3573
//   - applyAllCamerasView       app.js:2060
//
// Deliberately NOT ported: server-side Saved Views (`/views` CRUD, hotspots,
// carousels, per-view icons) — that's a separate, much larger feature keyed
// on a server API this task doesn't touch. This controller only manages the
// fixed built-in presets + the client-only "All Cameras" auto-grid, which is
// the full scope of wall-layouts-slot-management.

import 'package:flutter/foundation.dart';

import 'package:crumb_desktop/api/models.dart';
import 'wall_layout.dart';

class LayoutController extends ChangeNotifier {
  LayoutController({required List<Camera> cameras, String initialLayoutId = '2x2'})
    : _cameras = cameras,
      _layoutId = initialLayoutId {
    autoFillSlots();
  }

  List<Camera> _cameras;
  List<Camera> get cameras => _cameras;

  /// slot index -> camera id. A slot with no entry is empty.
  final Map<int, String> _slotMap = {};
  Map<int, String> get slotMap => Map.unmodifiable(_slotMap);

  int _selectedSlot = 0;
  int get selectedSlot => _selectedSlot;

  /// A fixed preset id ('1x1', '2x2', '1plus5', '3x3', '4x4') OR the
  /// '__all__' sentinel for the auto-fit All Cameras grid (mirrors app.js's
  /// `state.currentViewId === '__all__'`).
  String _layoutId;
  String get layoutId => _layoutId;
  bool get isAllCameras => _layoutId == '__all__';

  AutoGrid? _autoGrid; // only set while isAllCameras
  AutoGrid? get autoGrid => _autoGrid;

  LayoutPreset get preset => layoutById(_layoutId);

  /// Total tile count for the current layout (preset tile count, or the
  /// auto-grid's tile count in All Cameras mode).
  int get tileCount => isAllCameras ? (_autoGrid?.tiles ?? 0) : preset.tiles;

  /// Camera currently maximized to fill the whole wall, or null.
  Camera? _maximized;
  Camera? get maximized => _maximized;

  /// Replace the camera list (e.g. after a refresh). Assignments to cameras
  /// that no longer exist are dropped; newly-visible cameras are left
  /// unassigned (the sidebar just shows them as available).
  void setCameras(List<Camera> cameras) {
    _cameras = cameras;
    final validIds = cameras.map((c) => c.id).toSet();
    _slotMap.removeWhere((_, camId) => !validIds.contains(camId));
    if (isAllCameras) {
      _rebuildAllCamerasGrid();
    }
    notifyListeners();
  }

  // ── Slot selection ──────────────────────────────────────────────────────

  void selectSlot(int slotIndex) {
    if (slotIndex == _selectedSlot) return;
    _selectedSlot = slotIndex;
    notifyListeners();
  }

  /// Move selection to the next empty slot after the current one, wrapping
  /// around; if every slot is full, selection is unchanged. (app.js
  /// `advanceSelectedSlot`.)
  void advanceSelectedSlot() {
    final total = tileCount;
    if (total <= 0) return;
    for (var delta = 1; delta <= total; delta++) {
      final next = (_selectedSlot + delta) % total;
      if (!_slotMap.containsKey(next)) {
        _selectedSlot = next;
        return;
      }
    }
  }

  // ── Assignment ───────────────────────────────────────────────────────────

  /// Assign a camera to the currently-selected slot. If the camera is
  /// already on the wall elsewhere, it's moved (never duplicated) — matches
  /// commercial-VMS behavior. Advances selection to the next empty slot
  /// afterward for fast successive clicks. No-op while maximized. (app.js
  /// `assignCameraToSelectedSlot`.)
  void assignCameraToSelectedSlot(String cameraId) {
    if (_maximized != null) return;
    assignCameraToSlot(cameraId, _selectedSlot);
    advanceSelectedSlot();
  }

  /// Assign a camera to a specific slot (used by click-on-tile-then-camera
  /// and by drag-and-drop onto a tile). Displaces any existing occupant of
  /// that slot; removes the camera from any other slot it currently holds.
  void assignCameraToSlot(String cameraId, int slotIndex) {
    if (_maximized != null) return;
    if (slotIndex < 0 || slotIndex >= tileCount) return;
    _slotMap.removeWhere((_, id) => id == cameraId);
    _slotMap[slotIndex] = cameraId;
    notifyListeners();
  }

  /// Swap/move whatever is in `fromSlot` into `toSlot` (drag a filled tile
  /// onto another tile). If `toSlot` is occupied, the two swap.
  void moveSlot(int fromSlot, int toSlot) {
    if (_maximized != null || fromSlot == toSlot) return;
    final fromCam = _slotMap[fromSlot];
    if (fromCam == null) return;
    final toCam = _slotMap[toSlot];
    if (toCam != null) {
      _slotMap[fromSlot] = toCam;
    } else {
      _slotMap.remove(fromSlot);
    }
    _slotMap[toSlot] = fromCam;
    notifyListeners();
  }

  void clearSlot(int slotIndex) {
    if (_slotMap.remove(slotIndex) != null) notifyListeners();
  }

  // ── Layout switching ─────────────────────────────────────────────────────

  /// Switch to a fixed built-in preset. Assignments beyond the new tile
  /// count are dropped; remaining empty slots are auto-filled with
  /// currently-unassigned cameras. (app.js `activateLayout`.)
  void activateLayout(String presetId) {
    _maximized = null;
    _layoutId = presetId;
    _autoGrid = null;
    final newCount = preset.tiles;
    _slotMap.removeWhere((slot, _) => slot >= newCount);
    autoFillSlots();
    if (_selectedSlot >= newCount) _selectedSlot = 0;
    notifyListeners();
  }

  /// Apply the built-in "All Cameras" view: every visible camera in an
  /// auto-sized square-ish grid, replacing the current slot assignments
  /// entirely. (app.js `applyAllCamerasView`.)
  void applyAllCamerasView() {
    _maximized = null;
    _layoutId = '__all__';
    _rebuildAllCamerasGrid();
    _selectedSlot = 0;
    notifyListeners();
  }

  void _rebuildAllCamerasGrid() {
    _autoGrid = AutoGrid.forCount(_cameras.length);
    _slotMap.clear();
    for (var i = 0; i < _cameras.length; i++) {
      _slotMap[i] = _cameras[i].id;
    }
  }

  /// Fill empty slots with cameras not currently on the wall, in list order.
  /// (app.js `autoFillSlots`.)
  void autoFillSlots() {
    final assigned = _slotMap.values.toSet();
    final unassigned = _cameras.where((c) => !assigned.contains(c.id)).iterator;
    for (var i = 0; i < tileCount; i++) {
      if (_slotMap.containsKey(i)) continue;
      if (!unassigned.moveNext()) break;
      _slotMap[i] = unassigned.current.id;
    }
    notifyListeners();
  }

  // ── Maximize ─────────────────────────────────────────────────────────────

  void maximizeSlot(int slotIndex) {
    final camId = _slotMap[slotIndex];
    if (camId == null) return;
    final cam = _cameras.where((c) => c.id == camId).cast<Camera?>().firstWhere(
      (c) => c != null,
      orElse: () => null,
    );
    if (cam == null) return;
    _maximized = cam;
    notifyListeners();
  }

  void restoreFromMaximize() {
    if (_maximized == null) return;
    _maximized = null;
    notifyListeners();
  }
}
