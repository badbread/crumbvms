// Host adapter wiring the generic drag-to-place overlay editor
// (`overlay_editor/`) to custom PTZ panels — the P1 port that retired this
// file's private drag/snap/selection machinery (the old editor's
// per-tick-full-rebuild + re-snap-feedback UX is exactly what the shared
// editor was built to fix; see `overlay_editor_controller.dart`'s file doc).
//
// Split of responsibilities:
// * layout/editing (selection, drag, snap, align, group…) — the shared
//   [OverlayEditorController] at [editor]; the maximized pane renders it via
//   `OverlayEditorLayer` + `OverlayEditorBar` (see `ptz_panel_overlay.dart` /
//   `ptz_panel_palette.dart`).
// * persistence — this host, against the client-local [PtzPanelStore]
//   (panels are a per-device layout preference, unchanged).
// * view-mode PTZ dispatch (press-hold/tap → ONVIF move/stop/preset/imaging)
//   — this host, same wire calls as the stock D-pad controls.
//
// Lifecycle (host-loads-first, per the shared editor's synchronous-edit
// contract — mirrors `ha_overlay/ha_overlay_controller.dart`):
//
//   final token = ptz.editor.editToken;
//   final saved = await ptz.prepareEdit(cam.id);
//   if (ptz.editor.editToken != token) return; // stale — user moved on
//   _maximize(cam);
//   ptz.beginEditFromLoaded(cam.id, saved);
//   // ... later, on Done/Esc/forced transition:
//   await ptz.endEditAndSave();

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/crumb_api.dart';
import '../../api/models.dart';
import '../../api/ptz_extras_api.dart';
import '../../api/ptz_panel_models.dart';
import '../../api/ptz_panel_store.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import '../overlay_editor/overlay_item.dart';

/// [OverlayItem] adapter over one [PtzPanelButton] — pane-anchored,
/// drag-resizable, d-pads kept square, sizes clamped to the PTZ button
/// bounds. Wraps the button in place: the editor mutates the same object the
/// host persists on `endEditAndSave`.
class PtzOverlayButtonItem implements OverlayItem {
  PtzOverlayButtonItem(this.button);

  final PtzPanelButton button;

  @override
  String get id => button.id;

  @override
  double get x => button.x;
  @override
  set x(double v) => button.x = v;
  @override
  double get y => button.y;
  @override
  set y(double v) => button.y = v;

  @override
  OverlayAnchor get anchor => OverlayAnchor.pane;

  @override
  (double w, double h) baseSize() => button.baseSize();

  @override
  void setBaseSize(double w, double h) {
    double clamp(double v) => v.clamp(kPtzBtnMin, kPtzBtnMax).toDouble();
    if (button.kind == PtzButtonKind.dpad) {
      final v = clamp(w > h ? w : h);
      button.w = v;
      button.h = v;
    } else {
      button.w = clamp(w);
      button.h = clamp(h);
    }
  }

  @override
  bool get resizable => true;

  @override
  String? get groupId => button.group;
  @override
  set groupId(String? v) => button.group = v;
}

class PtzPanelController extends ChangeNotifier {
  PtzPanelController({
    required CrumbApi api,
    required Session session,
    required PtzPanelStore store,
  }) : _api = api,
       _session = session,
       _store = store {
    // Forward the shared editor's structure notifications so existing
    // listeners of THIS controller (the maximized pane's mode mirror) see
    // edit-session transitions without subscribing to two objects. Drag
    // ticks fire only `editor.geometry` and never reach this.
    editor.addListener(notifyListeners);
  }

  final CrumbApi _api;
  Session _session;
  final PtzPanelStore _store;

  /// The generic editor session this adapter drives — pass this to
  /// `OverlayEditorLayer`/`OverlayEditorBar` while editing.
  final OverlayEditorController editor = OverlayEditorController();

  void updateSession(Session session) => _session = session;

  String? _viewCameraId;
  List<PtzPanelButton> _viewButtons = const [];

  /// Camera whose panel the current edit session belongs to (null outside
  /// edit mode).
  String? editCameraId;

  bool get editing => editor.editMode;

  /// ONVIF presets for the camera being edited (palette content). Loaded in
  /// the BACKGROUND after `beginEditFromLoaded` — the editor chrome never
  /// waits on the network (the old builder's D5 lag).
  List<PtzPreset> presets = const [];

  int _seq = 0;
  String _newId() => 'b${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  /// The panel to render for `cameraId` right now: `(buttons, editing)`, or
  /// null if there's no custom panel and the camera isn't being edited
  /// (`ptzActivePanel` in app.js — caller falls back to the stock D-pad UI).
  (List<PtzPanelButton> buttons, bool editing)? activePanelFor(
    String? cameraId,
  ) {
    if (editor.editMode && editCameraId == cameraId) {
      return (
        [
          for (final i in editor.items)
            if (i is PtzOverlayButtonItem) i.button,
        ],
        true,
      );
    }
    if (_viewCameraId == cameraId && _viewButtons.isNotEmpty) {
      return (_viewButtons, false);
    }
    return null;
  }

  /// Load the (possibly-null) saved panel for `cameraId` so [activePanelFor]
  /// can serve it in view mode. Call when a tile focuses/maximizes a camera.
  Future<void> loadForView(String cameraId) async {
    final buttons = await _store.panelFor(cameraId);
    _viewCameraId = cameraId;
    _viewButtons = buttons ?? const [];
    notifyListeners();
  }

  // ─── Edit-mode lifecycle (host-loads-first, see the class doc) ──────────

  /// Fetch the saved panel for `cameraId` — call BEFORE
  /// [beginEditFromLoaded], guarded by `editor.editToken` (class doc).
  Future<List<PtzPanelButton>> prepareEdit(String cameraId) async {
    final buttons = await _store.panelFor(cameraId);
    return buttons ?? const [];
  }

  /// Begin the shared editor's edit session from the already-loaded panel.
  /// Synchronous — the chrome appears immediately; the ONVIF presets for the
  /// palette load in the background and slot in when they arrive.
  void beginEditFromLoaded(String cameraId, List<PtzPanelButton> saved) {
    editCameraId = cameraId;
    presets = const [];
    // Deep-copy into the session so a mid-session external read of the store
    // never observes half-edited state; the host writes back on save.
    final items = [
      for (final b in saved) PtzOverlayButtonItem(b.copyWith()),
    ];
    editor.beginEdit(items, anchor: OverlayAnchor.pane);
    final token = editor.editToken;
    unawaited(
      _api.ptzPresets(_session, cameraId).then((p) {
        // Stale-session guard: only surface presets into the session they
        // were fetched for. (`ptzPresets` returns [] on any error — never
        // throws — so no catchError needed.)
        if (editor.editMode && editor.editToken == token) {
          presets = p;
          notifyListeners();
        }
      }),
    );
  }

  /// End the edit session and persist the final layout to the store; also
  /// refreshes the view-mode copy so the panel repaints in place.
  /// The synchronous part (session teardown + view refresh) completes before
  /// the first await, so callers may fire-and-forget on forced transitions.
  Future<void> endEditAndSave() async {
    if (!editor.editMode) return;
    final cam = editCameraId;
    final items = editor.endEdit();
    editCameraId = null;
    presets = const [];
    if (cam == null) return;
    final buttons = [
      for (final i in items)
        if (i is PtzOverlayButtonItem) i.button,
    ];
    if (_viewCameraId == cam) {
      _viewButtons = buttons;
      notifyListeners();
    }
    await _store.save(cam, buttons);
  }

  // ─── Palette actions (invoked by `PtzPanelPalette` in the shared bar) ───

  /// Add a new button of `kind`, placed in its own grid slot (not stacked on
  /// existing buttons — `ptzPanelAddButton` in app.js) and select it. Pure
  /// in-session; persisted on [endEditAndSave].
  void addButton(
    PtzButtonKind kind, {
    String? presetToken,
    String? presetName,
  }) {
    if (!editor.editMode) return;
    final n = editor.items.length;
    editor.addItem(
      PtzOverlayButtonItem(
        PtzPanelButton(
          id: _newId(),
          kind: kind,
          x: 0.12 + (n % 4) * 0.20,
          y: 0.14 + ((n ~/ 4) % 4) * 0.18,
          presetToken: presetToken,
          presetName: presetName,
        ),
      ),
    );
  }

  PtzPanelButton? get _selectedButton {
    final item = editor.selected;
    return item is PtzOverlayButtonItem ? item.button : null;
  }

  /// Rename the primary selected button (labelable kinds only — the palette
  /// gates the field).
  void renameSelected(String label) {
    final btn = _selectedButton;
    if (btn == null) return;
    btn.label = label;
    editor.notifyItemsChanged();
  }

  /// Duplicate the primary selected button just below/right of the original.
  void duplicateSelected() {
    final btn = _selectedButton;
    if (btn == null) return;
    editor.addItem(
      PtzOverlayButtonItem(
        PtzPanelButton(
          id: _newId(),
          kind: btn.kind,
          x: (btn.x + 0.04).clamp(0, 1).toDouble(),
          y: (btn.y + 0.04).clamp(0, 1).toDouble(),
          w: btn.w,
          h: btn.h,
          label: btn.label,
          presetToken: btn.presetToken,
          presetName: btn.presetName,
        ),
      ),
    );
  }

  // ─── View-mode dispatch (same wire calls as the stock D-pad controls) ──

  Future<void> moveContinuous({double pan = 0, double tilt = 0, double zoom = 0}) {
    final cam = _dispatchCameraId;
    if (cam == null) return Future.value();
    return _api.ptzMove(_session, cam, pan: pan, tilt: tilt, zoom: zoom);
  }

  Future<void> stopContinuous() {
    final cam = _dispatchCameraId;
    if (cam == null) return Future.value();
    return _api.ptzStop(_session, cam);
  }

  Future<void> home() {
    final cam = _dispatchCameraId;
    if (cam == null) return Future.value();
    return _api.ptzHome(_session, cam);
  }

  Future<void> recallPreset(String token) {
    final cam = _dispatchCameraId;
    if (cam == null) return Future.value();
    return _api.ptzRecallPreset(_session, cam, token);
  }

  Future<void> imaging(ImagingAction action, {double? speed}) {
    final cam = _dispatchCameraId;
    if (cam == null) return Future.value();
    return _api.imagingCmd(_session, cam, action, speed: speed);
  }

  String? get _dispatchCameraId =>
      editor.editMode ? editCameraId : _viewCameraId;

  @override
  void dispose() {
    editor.removeListener(notifyListeners);
    editor.dispose();
    super.dispose();
  }
}
