// State + edit-mode logic for a camera's custom PTZ panel. Ports the
// mutation/drag/snap functions in apps/desktop/src/app.js (~4917-5330,
// 5924-5965): `ptzPanelAddButton`, `ptzPanelDeleteButton`, `ptzPanelSelect`,
// `ptzSnapLines`/`ptzSnapAxis`, `ptzPanelMoveButton`, `ptzPanelResizeButton`,
// `ptzPanelResizeSelected`, `ptzPanelEditToggle`/`End`, and the
// front/back-reorder actions from `ptzEditContextMenu`.
//
// One [PtzPanelController] is owned by whatever screen/tile hosts the video
// pane for a PTZ camera; it drives [PtzPanelOverlay] (rendering) and
// [PtzPanelEditorBar] (palette/props UI).

import 'package:flutter/foundation.dart';

import '../../api/crumb_api.dart';
import '../../api/models.dart';
import '../../api/ptz_extras_api.dart';
import '../../api/ptz_panel_models.dart';
import '../../api/ptz_panel_store.dart';

/// Alignment guide lines (logical px) shown while dragging/resizing.
class PtzSnapGuides {
  const PtzSnapGuides({this.vx = const [], this.hy = const []});
  final List<double> vx;
  final List<double> hy;
  static const none = PtzSnapGuides();
}

/// Snap threshold in logical px (`PTZ_SNAP_PX` in app.js).
const double kPtzSnapPx = 7;

class PtzPanelController extends ChangeNotifier {
  PtzPanelController({
    required CrumbApi api,
    required Session session,
    required PtzPanelStore store,
  }) : _api = api,
       _session = session,
       _store = store;

  final CrumbApi _api;
  Session _session;
  final PtzPanelStore _store;

  void updateSession(Session session) => _session = session;

  String? _viewCameraId;
  List<PtzPanelButton> _viewButtons = const [];

  bool editMode = false;
  String? editCameraId;
  String? selectedId;
  PtzSnapGuides snapGuides = PtzSnapGuides.none;
  List<PtzPreset> presets = const [];

  int _seq = 0;
  String _newId() =>
      'b${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  /// The panel to render for `cameraId` right now: `(buttons, editing)`, or
  /// null if there's no custom panel and the camera isn't being edited
  /// (`ptzActivePanel` in app.js — caller falls back to the stock D-pad UI).
  (List<PtzPanelButton> buttons, bool editing)? activePanelFor(
    String? cameraId,
  ) {
    final editing = editMode && editCameraId == cameraId;
    if (editing) return (editButtons, true);
    if (_viewCameraId == cameraId && _viewButtons.isNotEmpty) {
      return (_viewButtons, false);
    }
    return null;
  }

  List<PtzPanelButton> get editButtons {
    if (editCameraId == null) return const [];
    return _store.panelForEditSync(editCameraId!) ?? const [];
  }

  /// Load the (possibly-null) saved panel for `cameraId` so [activePanelFor]
  /// can serve it in view mode. Call when a tile focuses/maximizes a camera.
  Future<void> loadForView(String cameraId) async {
    final buttons = await _store.panelFor(cameraId);
    _viewCameraId = cameraId;
    _viewButtons = buttons ?? const [];
    notifyListeners();
  }

  // ─── Edit-mode lifecycle ────────────────────────────────────────────────

  Future<void> beginEdit(String cameraId) async {
    editMode = true;
    editCameraId = cameraId;
    selectedId = null;
    snapGuides = PtzSnapGuides.none;
    await _store.panelForEdit(cameraId); // ensures a (possibly empty) entry
    presets = await _api.ptzPresets(_session, cameraId);
    notifyListeners();
  }

  Future<void> endEdit() async {
    if (editCameraId != null) {
      await _store.save(editCameraId!, _store.panelForEditSync(editCameraId!) ?? const []);
      if (_viewCameraId == editCameraId) {
        _viewButtons = _store.panelForEditSync(editCameraId!) ?? const [];
      }
    }
    editMode = false;
    editCameraId = null;
    selectedId = null;
    snapGuides = PtzSnapGuides.none;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (editCameraId == null) return;
    await _store.save(editCameraId!, editButtons);
  }

  // ─── Palette actions ────────────────────────────────────────────────────

  /// Add a new button of `kind`, placed in its own grid slot (not stacked on
  /// existing buttons — `ptzPanelAddButton` in app.js) and select it.
  Future<void> addButton(
    PtzButtonKind kind, {
    String? presetToken,
    String? presetName,
  }) async {
    final cam = editCameraId;
    if (cam == null) return;
    final arr = _store.panelForEditSync(cam);
    if (arr == null) return;
    final col = arr.length % 4;
    final row = (arr.length ~/ 4) % 4;
    final id = _newId();
    arr.add(
      PtzPanelButton(
        id: id,
        kind: kind,
        x: 0.12 + col * 0.20,
        y: 0.14 + row * 0.18,
        presetToken: presetToken,
        presetName: presetName,
      ),
    );
    selectedId = id;
    await _persist();
    notifyListeners();
  }

  Future<void> deleteButton(String id) async {
    final cam = editCameraId;
    if (cam == null) return;
    final arr = _store.panelForEditSync(cam);
    if (arr == null) return;
    arr.removeWhere((b) => b.id == id);
    if (selectedId == id) selectedId = null;
    await _persist();
    notifyListeners();
  }

  void selectButton(String? id) {
    if (selectedId == id) return;
    selectedId = id;
    notifyListeners();
  }

  Future<void> renameSelected(String label) async {
    final btn = _selected();
    if (btn == null) return;
    btn.label = label;
    await _persist();
    notifyListeners();
  }

  /// Nudge the selected button's size by `factor` (editor +/- buttons —
  /// `ptzPanelResizeSelected` in app.js).
  Future<void> resizeSelected(double factor) async {
    final btn = _selected();
    if (btn == null) return;
    final (bw, bh) = btn.baseSize();
    double clamp(double v, double mn) => v.clamp(mn, kPtzBtnMax).toDouble();
    btn.w = clamp(bw * factor, kPtzBtnMin);
    btn.h = btn.kind == PtzButtonKind.dpad
        ? btn.w
        : clamp(bh * factor, kPtzBtnMin);
    await _persist();
    notifyListeners();
  }

  /// Move the selected/dragged button to front (drawn/hit-tested last) or
  /// back of the z-order (`ptzEditContextMenu` front/back actions).
  Future<void> bringToFront(String id) async {
    final cam = editCameraId;
    if (cam == null) return;
    final arr = _store.panelForEditSync(cam);
    if (arr == null) return;
    final i = arr.indexWhere((b) => b.id == id);
    if (i < 0) return;
    final b = arr.removeAt(i);
    arr.add(b);
    await _persist();
    notifyListeners();
  }

  Future<void> sendToBack(String id) async {
    final cam = editCameraId;
    if (cam == null) return;
    final arr = _store.panelForEditSync(cam);
    if (arr == null) return;
    final i = arr.indexWhere((b) => b.id == id);
    if (i < 0) return;
    final b = arr.removeAt(i);
    arr.insert(0, b);
    await _persist();
    notifyListeners();
  }

  Future<void> clearAll() async {
    final cam = editCameraId;
    if (cam == null) return;
    await _store.clear(cam);
    selectedId = null;
    notifyListeners();
  }

  /// Duplicate the selected button just below/right of the original.
  Future<void> duplicateSelected() async {
    final btn = _selected();
    final cam = editCameraId;
    if (btn == null || cam == null) return;
    final arr = _store.panelForEditSync(cam);
    if (arr == null) return;
    final id = _newId();
    arr.add(
      PtzPanelButton(
        id: id,
        kind: btn.kind,
        x: (btn.x + 0.04).clamp(0, 1).toDouble(),
        y: (btn.y + 0.04).clamp(0, 1).toDouble(),
        w: btn.w,
        h: btn.h,
        label: btn.label,
        presetToken: btn.presetToken,
        presetName: btn.presetName,
      ),
    );
    selectedId = id;
    await _persist();
    notifyListeners();
  }

  PtzPanelButton? _selected() {
    if (selectedId == null || editCameraId == null) return null;
    final arr = _store.panelForEditSync(editCameraId!);
    if (arr == null) return null;
    for (final b in arr) {
      if (b.id == selectedId) return b;
    }
    return null;
  }

  // ─── Drag / resize with snapping (`ptzSnapLines`/`ptzSnapAxis`,
  //     `ptzPanelMoveButton`/`ptzPanelResizeButton` in app.js) ─────────────

  /// Candidate snap lines from the OTHER buttons' edges/centres + the pane
  /// edges/centre, in logical px.
  PtzSnapGuides _snapLines(String exceptId, double paneW, double paneH) {
    final vx = <double>[0, paneW / 2, paneW];
    final hy = <double>[0, paneH / 2, paneH];
    final arr = editCameraId == null
        ? const <PtzPanelButton>[]
        : (_store.panelForEditSync(editCameraId!) ?? const []);
    for (final o in arr) {
      if (o.id == exceptId) continue;
      final (x, y, w, h) = PtzPanelGeometry.rectFor(o, paneW, paneH);
      vx.addAll([x, x + w / 2, x + w]);
      hy.addAll([y, y + h / 2, y + h]);
    }
    return PtzSnapGuides(vx: vx, hy: hy);
  }

  (double delta, double? guide) _snapAxis(List<double> cands, List<double> lines) {
    double? bestDelta;
    double? bestGuide;
    for (final c in cands) {
      for (final g in lines) {
        final d = g - c;
        if (d.abs() <= kPtzSnapPx &&
            (bestDelta == null || d.abs() < bestDelta.abs())) {
          bestDelta = d;
          bestGuide = g;
        }
      }
    }
    return (bestDelta ?? 0, bestGuide);
  }

  /// Nudge `id` by a pointer-movement delta (px, in a `paneW`x`paneH` pane);
  /// snaps the resulting edges/centre to alignment guides. Does NOT persist
  /// (call on every drag-update tick; persistence happens on drag-end via
  /// [commitDrag]). Using a delta (rather than an absolute cursor position)
  /// keeps this correct regardless of ancestor widget transforms — Flutter's
  /// `DragUpdateDetails.delta` is already in the gesture's local px space.
  void moveButtonByDelta(
    String id,
    double paneW,
    double paneH,
    double dx,
    double dy,
  ) {
    final btn = _findButton(id);
    if (btn == null) return;
    final (curX, curY, bw, bh) = PtzPanelGeometry.rectFor(btn, paneW, paneH);
    var px = curX + dx;
    var py = curY + dy;
    final lines = _snapLines(id, paneW, paneH);
    final sx = _snapAxis([px, px + bw / 2, px + bw], lines.vx);
    final sy = _snapAxis([py, py + bh / 2, py + bh], lines.hy);
    px += sx.$1;
    py += sy.$1;
    snapGuides = PtzSnapGuides(
      vx: sx.$2 != null ? [sx.$2!] : const [],
      hy: sy.$2 != null ? [sy.$2!] : const [],
    );
    btn.x = (px / paneW).clamp(0, 1).toDouble();
    btn.y = (py / paneH).clamp(0, 1).toDouble();
    notifyListeners();
  }

  /// Resize `id` by a pointer-movement delta applied to its bottom-right
  /// edge; snaps to alignment guides. Stores the BASE (unscaled) size so it
  /// renders consistently with `paneScale`.
  void resizeButtonByDelta(
    String id,
    double paneW,
    double paneH,
    double dx,
    double dy,
  ) {
    final btn = _findButton(id);
    if (btn == null) return;
    final s = PtzPanelGeometry.paneScale(paneW, paneH);
    final (left, top, curW, curH) = PtzPanelGeometry.rectFor(btn, paneW, paneH);
    var nw = curW + dx;
    var nh = curH + dy;
    final lines = _snapLines(id, paneW, paneH);
    final sx = _snapAxis([left + nw], lines.vx);
    final sy = _snapAxis([top + nh], lines.hy);
    nw += sx.$1;
    nh += sy.$1;
    snapGuides = PtzSnapGuides(
      vx: sx.$2 != null ? [sx.$2!] : const [],
      hy: sy.$2 != null ? [sy.$2!] : const [],
    );
    double clamp(double v) => (v / s).clamp(kPtzBtnMin, kPtzBtnMax).toDouble();
    if (btn.kind == PtzButtonKind.dpad) {
      final v = clamp(nw > nh ? nw : nh);
      btn.w = v;
      btn.h = v;
    } else {
      btn.w = clamp(nw);
      btn.h = clamp(nh);
    }
    notifyListeners();
  }

  PtzPanelButton? _findButton(String id) {
    final arr = editCameraId == null
        ? null
        : _store.panelForEditSync(editCameraId!);
    if (arr == null) return null;
    for (final b in arr) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// End of a drag/resize gesture: clear guides and persist.
  Future<void> commitDrag() async {
    snapGuides = PtzSnapGuides.none;
    await _persist();
    notifyListeners();
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

  String? get _dispatchCameraId => editMode ? editCameraId : _viewCameraId;
}
