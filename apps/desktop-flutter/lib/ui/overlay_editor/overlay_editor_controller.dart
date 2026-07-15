// Generic drag-to-place overlay editor: selection, drag/resize with
// alignment-snap guides, and an explicit SYNCHRONOUS edit lifecycle. Lifted
// from `ptz/ptz_panel_controller.dart` (`ptzSnapLines`/`ptzSnapAxis`,
// `ptzPanelMoveButton`/`ptzPanelResizeButton` in the old client's app.js) and
// repaired per the desktop P0 plan (issue #170 §3.2/§3.3): the PTZ
// controller's `beginEdit`/`endEdit` `await` storage calls BEFORE their only
// `notifyListeners()`, which produces an interleave-clobber race between two
// back-to-back edit sessions (D3) and a UI-lag-behind-the-click window (D5).
//
// This controller never touches storage: `beginEdit` takes an
// ALREADY-LOADED item list and fires `notifyListeners()` synchronously;
// `endEdit` returns the final items synchronously so the HOST persists.
// Hosts own storage entirely — a client-local store for PTZ panels (future
// adapter), a server PUT for HA badge placements
// (`ha_overlay/ha_overlay_controller.dart`).
//
// One [OverlayEditorController] is owned by whatever host adapts a specific
// overlay kind. The host drives [OverlayEditorLayer] (rendering/gestures,
// `overlay_editor_layer.dart`) and [OverlayEditorBar] (palette/props chrome,
// `overlay_editor_bar.dart`).

import 'package:flutter/foundation.dart';

import 'overlay_geometry.dart';
import 'overlay_item.dart';

/// Alignment guide lines (logical px, pane-local) shown while dragging/resizing.
class OverlaySnapGuides {
  const OverlaySnapGuides({this.vx = const [], this.hy = const []});
  final List<double> vx;
  final List<double> hy;
  static const none = OverlaySnapGuides();
}

/// Snap threshold in logical px (`PTZ_SNAP_PX` in the old client /
/// `kPtzSnapPx`).
const double kOverlaySnapPx = 7;

class OverlayEditorController extends ChangeNotifier {
  bool editMode = false;
  String? selectedId;
  OverlaySnapGuides snapGuides = OverlaySnapGuides.none;

  List<OverlayItem> _items = const [];
  OverlayAnchor _anchor = OverlayAnchor.pane;
  int _editToken = 0;

  /// Bumped on every `beginEdit`/`endEdit`. Hosts that kick off an async load
  /// BEFORE calling `beginEdit` (the mandated "host-loads-first" order, see
  /// `ha_overlay/ha_overlay_controller.dart`) should capture this beforehand
  /// and compare it once the load resolves — if it changed, another edit
  /// session started or ended in the meantime, and the late `beginEdit`
  /// call must be skipped (a stale continuation would otherwise clobber
  /// whatever the user is doing now).
  int get editToken => _editToken;

  /// Live item list for the current edit session (empty outside edit mode —
  /// hosts pass their own list to [OverlayEditorLayer] for view mode).
  List<OverlayItem> get items => _items;

  OverlayAnchor get anchor => _anchor;

  OverlayItem? get selected {
    final id = selectedId;
    if (id == null) return null;
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Begin an edit session with `items` the host has ALREADY loaded (and
  /// `anchor`, since an empty item list still needs a coordinate space for
  /// snap-line/placement math). No awaits; fires `notifyListeners()`
  /// synchronously so the editor chrome appears the instant this returns.
  void beginEdit(List<OverlayItem> items, {required OverlayAnchor anchor}) {
    _editToken++;
    editMode = true;
    _items = List.of(items);
    _anchor = anchor;
    selectedId = null;
    snapGuides = OverlaySnapGuides.none;
    notifyListeners();
  }

  /// End the edit session and hand the final item list back to the host,
  /// which persists it. Synchronous — no fire-and-forget transitions.
  List<OverlayItem> endEdit() {
    _editToken++;
    final result = _items;
    editMode = false;
    _items = const [];
    selectedId = null;
    snapGuides = OverlaySnapGuides.none;
    notifyListeners();
    return result;
  }

  void selectItem(String? id) {
    if (selectedId == id) return;
    selectedId = id;
    notifyListeners();
  }

  /// Add a new item to the session (e.g. a palette pick) and select it. Pure
  /// in-memory — the host persists on `endEdit`.
  void addItem(OverlayItem item) {
    _items = [..._items, item];
    selectedId = item.id;
    notifyListeners();
  }

  /// Remove an item from the session (the on-canvas delete handle, or the
  /// selected-item bar's Delete button). Pure in-memory.
  void removeItem(String id) {
    _items = _items.where((i) => i.id != id).toList(growable: false);
    if (selectedId == id) selectedId = null;
    notifyListeners();
  }

  void clearAll() {
    _items = const [];
    selectedId = null;
    notifyListeners();
  }

  /// Nudge the selected item's size by `factor` (editor bar +/- stepper —
  /// `ptzPanelResizeSelected` in the old client). Works for every item,
  /// drag-resizable or not (HA badges use this exclusively).
  void resizeSelected(double factor) {
    final item = selected;
    if (item == null) return;
    final (bw, bh) = item.baseSize();
    item.setBaseSize(bw * factor, bh * factor);
    notifyListeners();
  }

  // ─── Drag / resize with snapping ────────────────────────────────────────

  OverlayItem? _find(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Candidate snap lines from the OTHER items' edges/centres + the anchor
  /// field's edges/centre, in logical px.
  OverlaySnapGuides _snapLines(
    String exceptId,
    double paneW,
    double paneH, {
    int? videoW,
    int? videoH,
  }) {
    final (fx, fy, fw, fh) = OverlayGeometry.fieldRect(
      _anchor,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    final vx = <double>[fx, fx + fw / 2, fx + fw];
    final hy = <double>[fy, fy + fh / 2, fy + fh];
    for (final o in _items) {
      if (o.id == exceptId) continue;
      final (x, y, w, h) = OverlayGeometry.rectFor(
        o,
        paneW,
        paneH,
        videoW: videoW,
        videoH: videoH,
      );
      vx.addAll([x, x + w / 2, x + w]);
      hy.addAll([y, y + h / 2, y + h]);
    }
    return OverlaySnapGuides(vx: vx, hy: hy);
  }

  (double delta, double? guide) _snapAxis(
    List<double> cands,
    List<double> lines,
  ) {
    double? bestDelta;
    double? bestGuide;
    for (final c in cands) {
      for (final g in lines) {
        final d = g - c;
        if (d.abs() <= kOverlaySnapPx &&
            (bestDelta == null || d.abs() < bestDelta.abs())) {
          bestDelta = d;
          bestGuide = g;
        }
      }
    }
    return (bestDelta ?? 0, bestGuide);
  }

  /// Nudge `id` by a pointer-movement delta (px, pane-local); snaps the
  /// resulting edges/centre to alignment guides. Does NOT persist — call on
  /// every drag-update tick; the host persists once at `endEdit`.
  void moveItemByDelta(
    String id,
    double paneW,
    double paneH,
    double dx,
    double dy, {
    int? videoW,
    int? videoH,
  }) {
    final item = _find(id);
    if (item == null) return;
    final (curX, curY, bw, bh) = OverlayGeometry.rectFor(
      item,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    var px = curX + dx;
    var py = curY + dy;
    final lines = _snapLines(id, paneW, paneH, videoW: videoW, videoH: videoH);
    final sx = _snapAxis([px, px + bw / 2, px + bw], lines.vx);
    final sy = _snapAxis([py, py + bh / 2, py + bh], lines.hy);
    px += sx.$1;
    py += sy.$1;
    snapGuides = OverlaySnapGuides(
      vx: sx.$2 != null ? [sx.$2!] : const [],
      hy: sy.$2 != null ? [sy.$2!] : const [],
    );
    final (fx, fy, fw, fh) = OverlayGeometry.fieldRect(
      _anchor,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    item.x = fw <= 0 ? 0 : ((px - fx) / fw).clamp(0, 1).toDouble();
    item.y = fh <= 0 ? 0 : ((py - fy) / fh).clamp(0, 1).toDouble();
    notifyListeners();
  }

  /// Resize `id` by a pointer-movement delta applied to its bottom-right
  /// edge; snaps to alignment guides. Only meaningful for `item.resizable`
  /// items — the layer only shows the drag-resize handle for those; a
  /// non-resizable item's caller shouldn't invoke this (defensive no-op if
  /// it does).
  void resizeItemByDelta(
    String id,
    double paneW,
    double paneH,
    double dx,
    double dy, {
    int? videoW,
    int? videoH,
  }) {
    final item = _find(id);
    if (item == null || !item.resizable) return;
    final s = OverlayGeometry.paneScale(paneW, paneH);
    final (left, top, curW, curH) = OverlayGeometry.rectFor(
      item,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    var nw = curW + dx;
    var nh = curH + dy;
    final lines = _snapLines(id, paneW, paneH, videoW: videoW, videoH: videoH);
    final sx = _snapAxis([left + nw], lines.vx);
    final sy = _snapAxis([top + nh], lines.hy);
    nw += sx.$1;
    nh += sy.$1;
    snapGuides = OverlaySnapGuides(
      vx: sx.$2 != null ? [sx.$2!] : const [],
      hy: sy.$2 != null ? [sy.$2!] : const [],
    );
    item.setBaseSize(s <= 0 ? nw : nw / s, s <= 0 ? nh : nh / s);
    notifyListeners();
  }

  /// End of a drag/resize gesture: clear guides. No persistence — see the
  /// class doc; the host persists once at `endEdit`.
  void commitDrag() {
    snapGuides = OverlaySnapGuides.none;
    notifyListeners();
  }
}
