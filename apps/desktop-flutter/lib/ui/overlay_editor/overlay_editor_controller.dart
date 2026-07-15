// Generic drag-to-place overlay editor: multi-selection (click / modifier
// toggle / marquee / groups), drag + resize with a LIGHT alignment-snap
// assist, align/distribute/match-size tooling, and an explicit SYNCHRONOUS
// edit lifecycle. Serves both hosts: HA on-video badges
// (`ha_overlay/ha_overlay_controller.dart`) and custom PTZ panels
// (`ptz/ptz_panel_controller.dart`).
//
// ── Notification model (the anti-stutter contract) ─────────────────────────
// This controller is itself a `ChangeNotifier` for STRUCTURAL changes only:
// edit begin/end, selection, add/remove/reorder, align/resize ops, snap
// toggle, drag END. Per-pointer-move drag/resize ticks fire ONLY the
// lightweight [geometry] ticker — `OverlayEditorLayer` subscribes each item's
// `Positioned` (and the snap-guide lines) to [geometry], so a drag relayouts
// a handful of positioned boxes per frame instead of rebuilding the whole
// layer + editor bar + palette (the old per-tick `notifyListeners()` did
// exactly that and was the stutter). Hosts/bars listen to the controller
// itself and never see drag ticks.
//
// ── Snapping (the "snaps like crazy" fix) ──────────────────────────────────
// The old implementation applied the snap delta to the item's CURRENT
// (already snapped) position on every tick, so once an item snapped it could
// only escape if a single pointer event moved farther than the snap radius —
// the item felt glued and resizing fought the guides. This version tracks the
// UNSNAPPED ("raw") position across the whole gesture and snaps that, so the
// item follows the pointer and simply lets go the moment the raw position
// leaves the radius. Additionally: the radius is smaller ([kOverlaySnapPx]),
// resize snaps only to real edges (never centers), holding Alt suppresses
// snapping for the duration of the gesture (the layer passes `snap: false`),
// and [snapEnabled] is an editor-bar toggle.
//
// ── Lifecycle ──────────────────────────────────────────────────────────────
// `beginEdit` takes an ALREADY-LOADED item list and fires notifications
// synchronously; `endEdit` returns the final items synchronously so the HOST
// persists. The controller never touches storage (fixes the PTZ builder's
// D3/D4/D5 races by construction — see the desktop P0 plan §3.2).

import 'dart:math' as math;

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

/// Snap radius in logical px. Deliberately smaller than the old PTZ editor's
/// 7px — combined with raw-position tracking (see the file doc) snapping is a
/// light assist, not a trap.
const double kOverlaySnapPx = 6;

/// Align operations for [OverlayEditorController.alignSelected]. Targets are
/// the selection's bounding box (the convention of every layout tool).
enum OverlayAlign { left, hCenter, right, top, vCenter, bottom }

/// Lightweight notifier for per-pointer-move geometry ticks — see the file
/// doc's notification model. Only positioned wrappers/guides subscribe.
class OverlayGeometryTicker extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// Raw-tracked state for an in-flight move gesture (possibly multi-item).
class _MoveDrag {
  _MoveDrag({
    required this.origins,
    required this.startLeft,
    required this.startTop,
    required this.width,
    required this.height,
    required this.lines,
  })  : rawLeft = startLeft,
        rawTop = startTop;

  /// Each moving item's rendered top-left (px) at gesture start.
  final Map<String, ({double x, double y})> origins;

  /// Moving-set bounding box at gesture start.
  final double startLeft;
  final double startTop;
  final double width;
  final double height;

  /// UNSNAPPED accumulated bbox position — the pointer's truth.
  double rawLeft;
  double rawTop;

  /// Snap candidates from the NON-moving items + the anchor field, computed
  /// once at gesture start (they cannot change mid-drag).
  final OverlaySnapGuides lines;
}

/// Raw-tracked state for an in-flight resize gesture (single item).
class _ResizeDrag {
  _ResizeDrag({
    required this.id,
    required this.left,
    required this.top,
    required double w,
    required double h,
    required this.lines,
  })  : rawW = w,
        rawH = h;

  final String id;
  final double left;
  final double top;
  double rawW;
  double rawH;
  final OverlaySnapGuides lines;
}

class OverlayEditorController extends ChangeNotifier {
  bool editMode = false;

  /// Editor-bar snap toggle. Off ⇒ no gesture ever snaps (Alt additionally
  /// suppresses per-gesture while this is on).
  bool snapEnabled = true;

  OverlaySnapGuides snapGuides = OverlaySnapGuides.none;

  /// Per-drag-tick notifier — see the file doc's notification model.
  final OverlayGeometryTicker geometry = OverlayGeometryTicker();

  List<OverlayItem> _items = [];
  OverlayAnchor _anchor = OverlayAnchor.pane;
  int _editToken = 0;

  final Set<String> _selected = {};
  String? _primaryId;

  _MoveDrag? _moveDrag;
  _ResizeDrag? _resizeDrag;

  // Last-known pane metrics, reported by the layer on every build (plain
  // field writes, no notification) so selection ops (align/distribute/match)
  // and marquee hit-testing can do pixel math without the bar/host having to
  // thread pane dimensions around.
  double _paneW = 0;
  double _paneH = 0;
  int? _videoW;
  int? _videoH;

  /// Bumped on every `beginEdit`/`endEdit`. Hosts that kick off an async load
  /// BEFORE calling `beginEdit` (the mandated "host-loads-first" order)
  /// should capture this beforehand and compare it once the load resolves —
  /// if it changed, another edit session started or ended in the meantime and
  /// the late `beginEdit` must be skipped.
  int get editToken => _editToken;

  /// Live item list for the current edit session (empty outside edit mode —
  /// hosts pass their own list to [OverlayEditorLayer] for view mode).
  List<OverlayItem> get items => _items;

  OverlayAnchor get anchor => _anchor;

  /// Current selection (item ids). Do not mutate — use the select methods.
  Set<String> get selectedIds => _selected;

  /// The reference item for match-size ops: the last explicitly
  /// clicked/grabbed item of the selection.
  String? get primarySelectedId => _primaryId;

  /// The primary selected item (bar props target), or null.
  OverlayItem? get selected {
    final id = _primaryId;
    if (id == null) return null;
    return _find(id);
  }

  bool isSelected(String id) => _selected.contains(id);

  /// True when any selected item belongs to a group.
  bool get selectionGrouped =>
      _selectedItems().any((i) => i.groupId != null);

  /// Called by [OverlayEditorLayer] on every build with its current pane (and
  /// decoded-video) dimensions. Plain field writes — no notification (this
  /// runs during build).
  void updatePaneMetrics(double paneW, double paneH, {int? videoW, int? videoH}) {
    _paneW = paneW;
    _paneH = paneH;
    _videoW = videoW;
    _videoH = videoH;
  }

  // ─── Edit lifecycle ─────────────────────────────────────────────────────

  /// Begin an edit session with `items` the host has ALREADY loaded (and
  /// `anchor`, since an empty item list still needs a coordinate space for
  /// snap-line/placement math). No awaits; fires `notifyListeners()`
  /// synchronously so the editor chrome appears the instant this returns.
  void beginEdit(List<OverlayItem> items, {required OverlayAnchor anchor}) {
    _editToken++;
    editMode = true;
    _items = List.of(items);
    _anchor = anchor;
    _selected.clear();
    _primaryId = null;
    _moveDrag = null;
    _resizeDrag = null;
    snapGuides = OverlaySnapGuides.none;
    notifyListeners();
  }

  /// End the edit session and hand the final item list back to the host,
  /// which persists it. Synchronous — no fire-and-forget transitions.
  List<OverlayItem> endEdit() {
    _editToken++;
    final result = _items;
    editMode = false;
    _items = [];
    _selected.clear();
    _primaryId = null;
    _moveDrag = null;
    _resizeDrag = null;
    snapGuides = OverlaySnapGuides.none;
    notifyListeners();
    return result;
  }

  // ─── Selection ──────────────────────────────────────────────────────────

  /// Select exactly `id` (expanded to its whole group), or clear with null.
  void selectItem(String? id) {
    if (id == null) {
      clearSelection();
      return;
    }
    final expanded = _expandGroups({id});
    if (setEquals(_selected, expanded) && _primaryId == id) return;
    _selected
      ..clear()
      ..addAll(expanded);
    _primaryId = id;
    notifyListeners();
  }

  /// Shift/Ctrl-click: toggle `id` (and its group) in/out of the selection.
  void toggleSelect(String id) {
    final expanded = _expandGroups({id});
    if (_selected.containsAll(expanded)) {
      _selected.removeAll(expanded);
      if (expanded.contains(_primaryId)) {
        _primaryId = _selected.isEmpty ? null : _selected.first;
      }
    } else {
      _selected.addAll(expanded);
      _primaryId = id;
    }
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty && _primaryId == null) return;
    _selected.clear();
    _primaryId = null;
    notifyListeners();
  }

  /// Replace the selection wholesale (marquee). Group-expanded; no-op when
  /// the expanded set already equals the current selection.
  void setSelection(Set<String> ids) {
    final expanded = _expandGroups(ids);
    if (setEquals(_selected, expanded)) return;
    _selected
      ..clear()
      ..addAll(expanded);
    if (_primaryId == null || !_selected.contains(_primaryId)) {
      _primaryId = _selected.isEmpty ? null : _selected.first;
    }
    notifyListeners();
  }

  /// Marquee box-select: replaces the selection with every item whose
  /// rendered rect intersects the (pane-px) rect.
  void marqueeSelect(double left, double top, double right, double bottom) {
    final hits = <String>{};
    for (final i in _items) {
      final (x, y, w, h) = _rect(i);
      if (x < right && x + w > left && y < bottom && y + h > top) {
        hits.add(i.id);
      }
    }
    setSelection(hits);
  }

  Set<String> _expandGroups(Set<String> ids) {
    final gids = <String>{};
    for (final i in _items) {
      if (ids.contains(i.id) && i.groupId != null) gids.add(i.groupId!);
    }
    if (gids.isEmpty) return {...ids};
    return {
      ...ids,
      for (final i in _items)
        if (i.groupId != null && gids.contains(i.groupId)) i.id,
    };
  }

  List<OverlayItem> _selectedItems() =>
      [for (final i in _items) if (_selected.contains(i.id)) i];

  // ─── Items ──────────────────────────────────────────────────────────────

  /// Add a new item to the session (e.g. a palette pick) and select it. Pure
  /// in-memory — the host persists on `endEdit`.
  void addItem(OverlayItem item) {
    _items.add(item);
    _selected
      ..clear()
      ..add(item.id);
    _primaryId = item.id;
    notifyListeners();
  }

  /// Remove an item from the session (the on-canvas delete handle). Pure
  /// in-memory.
  void removeItem(String id) {
    _items.removeWhere((i) => i.id == id);
    _selected.remove(id);
    if (_primaryId == id) {
      _primaryId = _selected.isEmpty ? null : _selected.first;
    }
    notifyListeners();
  }

  /// Remove every selected item (the bar's Delete with a multi-selection).
  void removeSelected() {
    if (_selected.isEmpty) return;
    _items.removeWhere((i) => _selected.contains(i.id));
    _selected.clear();
    _primaryId = null;
    notifyListeners();
  }

  void clearAll() {
    _items = [];
    _selected.clear();
    _primaryId = null;
    notifyListeners();
  }

  /// Structure re-notify for HOST-side mutations of item content (e.g. a PTZ
  /// button rename, an HA badge recolor) so the layer/bar repaint without the
  /// host reaching into private state.
  void notifyItemsChanged() => notifyListeners();

  /// Z-order: last item renders (and hit-tests) on top.
  void bringToFront(String id) {
    final i = _items.indexWhere((b) => b.id == id);
    if (i < 0 || i == _items.length - 1) return;
    _items.add(_items.removeAt(i));
    notifyListeners();
  }

  void sendToBack(String id) {
    final i = _items.indexWhere((b) => b.id == id);
    if (i <= 0) return;
    _items.insert(0, _items.removeAt(i));
    notifyListeners();
  }

  void toggleSnap() {
    snapEnabled = !snapEnabled;
    notifyListeners();
  }

  // ─── Size ops ───────────────────────────────────────────────────────────

  /// Nudge the selection's size by `factor` (editor bar +/- stepper). With
  /// 2+ items selected this scales the whole cluster — sizes AND positions
  /// relative to the selection's bounding-box top-left — so a grouped d-pad
  /// + buttons layout grows as one unit instead of drifting apart.
  void resizeSelected(double factor) {
    final sel = _selectedItems();
    if (sel.isEmpty) return;
    if (sel.length == 1 || _paneW <= 0 || _paneH <= 0) {
      for (final item in sel) {
        final (bw, bh) = item.baseSize();
        item.setBaseSize(bw * factor, bh * factor);
      }
      notifyListeners();
      return;
    }
    var minX = double.infinity, minY = double.infinity;
    for (final item in sel) {
      final (x, y, _, _) = _rect(item);
      minX = math.min(minX, x);
      minY = math.min(minY, y);
    }
    for (final item in sel) {
      final (x, y, _, _) = _rect(item);
      final (bw, bh) = item.baseSize();
      item.setBaseSize(bw * factor, bh * factor);
      _setNormPos(item, minX + (x - minX) * factor, minY + (y - minY) * factor);
    }
    notifyListeners();
  }

  /// Explicit numeric size: set every selected item's base WIDTH to `w`
  /// (height scaled to keep each item's aspect; item impls clamp/keep-square
  /// as they see fit).
  void setSelectedBaseWidth(double w) {
    if (w <= 0 || !w.isFinite) return;
    final sel = _selectedItems();
    if (sel.isEmpty) return;
    for (final item in sel) {
      final (bw, bh) = item.baseSize();
      final k = bw <= 0 ? 1.0 : w / bw;
      item.setBaseSize(w, bh * k);
    }
    notifyListeners();
  }

  /// Match every selected item's base size to the PRIMARY (last-clicked)
  /// item's — width, height, or both.
  void matchSelectedSize({required bool width, required bool height}) {
    final ref = selected;
    final sel = _selectedItems();
    if (ref == null || sel.length < 2) return;
    final (rw, rh) = ref.baseSize();
    for (final item in sel) {
      if (identical(item, ref)) continue;
      final (bw, bh) = item.baseSize();
      item.setBaseSize(width ? rw : bw, height ? rh : bh);
    }
    notifyListeners();
  }

  // ─── Align / distribute ─────────────────────────────────────────────────

  /// Align the selected items (2+) against the selection's bounding box.
  void alignSelected(OverlayAlign a) {
    final sel = _selectedItems();
    if (sel.length < 2 || _paneW <= 0 || _paneH <= 0) return;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final item in sel) {
      final (x, y, w, h) = _rect(item);
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x + w);
      maxY = math.max(maxY, y + h);
    }
    for (final item in sel) {
      final (x, y, w, h) = _rect(item);
      var nx = x, ny = y;
      switch (a) {
        case OverlayAlign.left:
          nx = minX;
        case OverlayAlign.hCenter:
          nx = (minX + maxX) / 2 - w / 2;
        case OverlayAlign.right:
          nx = maxX - w;
        case OverlayAlign.top:
          ny = minY;
        case OverlayAlign.vCenter:
          ny = (minY + maxY) / 2 - h / 2;
        case OverlayAlign.bottom:
          ny = maxY - h;
      }
      _setNormPos(item, nx, ny);
    }
    notifyListeners();
  }

  /// Distribute the selected items (3+) with equal gaps along one axis; the
  /// outermost two stay put.
  void distributeSelected({required bool horizontal}) {
    final sel = _selectedItems();
    if (sel.length < 3 || _paneW <= 0 || _paneH <= 0) return;
    final entries = [
      for (final item in sel)
        (item: item, rect: _rect(item)),
    ]..sort((a, b) => horizontal
        ? a.rect.$1.compareTo(b.rect.$1)
        : a.rect.$2.compareTo(b.rect.$2));
    double sizeOf((double, double, double, double) r) =>
        horizontal ? r.$3 : r.$4;
    double posOf((double, double, double, double) r) =>
        horizontal ? r.$1 : r.$2;
    final first = entries.first.rect;
    final last = entries.last.rect;
    final span = posOf(last) + sizeOf(last) - posOf(first);
    var total = 0.0;
    for (final e in entries) {
      total += sizeOf(e.rect);
    }
    final gap = (span - total) / (entries.length - 1);
    var cursor = posOf(first) + sizeOf(first) + gap;
    for (var i = 1; i < entries.length - 1; i++) {
      final e = entries[i];
      final (x, y, _, _) = e.rect;
      _setNormPos(
        e.item,
        horizontal ? cursor : x,
        horizontal ? y : cursor,
      );
      cursor += sizeOf(e.rect) + gap;
    }
    notifyListeners();
  }

  // ─── Group / ungroup ────────────────────────────────────────────────────

  void groupSelected() {
    final sel = _selectedItems();
    if (sel.length < 2) return;
    final gid = 'g${DateTime.now().microsecondsSinceEpoch}';
    for (final item in sel) {
      item.groupId = gid;
    }
    notifyListeners();
  }

  void ungroupSelected() {
    var changed = false;
    for (final item in _selectedItems()) {
      if (item.groupId != null) {
        item.groupId = null;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // ─── Drag (move) — raw-tracked, see the file doc ────────────────────────

  /// Start a move gesture on `grabbedId`. If it isn't part of the selection
  /// the selection collapses to it (group-expanded) first; dragging any
  /// selected item moves the WHOLE selection.
  void beginDrag(String grabbedId) {
    if (!editMode || _paneW <= 0 || _paneH <= 0) return;
    if (!_selected.contains(grabbedId)) {
      selectItem(grabbedId);
    } else if (_primaryId != grabbedId) {
      _primaryId = grabbedId;
      notifyListeners();
    }
    final moving = _selectedItems();
    if (moving.isEmpty) return;
    final origins = <String, ({double x, double y})>{};
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final item in moving) {
      final (x, y, w, h) = _rect(item);
      origins[item.id] = (x: x, y: y);
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x + w);
      maxY = math.max(maxY, y + h);
    }
    _moveDrag = _MoveDrag(
      origins: origins,
      startLeft: minX,
      startTop: minY,
      width: maxX - minX,
      height: maxY - minY,
      lines: _snapLines(excludeIds: _selected, includeCenters: true),
    );
  }

  /// Apply a pointer-movement delta to the in-flight move. `snap: false`
  /// (Alt held) bypasses snapping for this tick; [snapEnabled] gates it
  /// globally. Fires only [geometry] — see the notification model.
  void updateDrag(double dx, double dy, {required bool snap}) {
    final d = _moveDrag;
    if (d == null) return;
    d.rawLeft += dx;
    d.rawTop += dy;
    final (fx, fy, fw, fh) = _field();
    // Clamp the whole moving bbox inside the anchor field so a multi-drag
    // keeps its shape at the edges instead of squashing item-by-item.
    var left = d.rawLeft.clamp(fx, math.max(fx, fx + fw - d.width)).toDouble();
    var top = d.rawTop.clamp(fy, math.max(fy, fy + fh - d.height)).toDouble();
    double? gx, gy;
    if (snap && snapEnabled) {
      final sx =
          _snapAxis([left, left + d.width / 2, left + d.width], d.lines.vx);
      final sy =
          _snapAxis([top, top + d.height / 2, top + d.height], d.lines.hy);
      left += sx.$1;
      top += sy.$1;
      gx = sx.$2;
      gy = sy.$2;
    }
    snapGuides = OverlaySnapGuides(
      vx: gx != null ? [gx] : const [],
      hy: gy != null ? [gy] : const [],
    );
    final offX = left - d.startLeft;
    final offY = top - d.startTop;
    for (final item in _items) {
      final o = d.origins[item.id];
      if (o == null) continue;
      _setNormPos(item, o.x + offX, o.y + offY);
    }
    geometry.tick();
  }

  /// End of a move gesture: clear guides, structure-notify once (syncs the
  /// bar's numeric fields). No persistence — the host persists at `endEdit`.
  void endDrag() {
    _moveDrag = null;
    snapGuides = OverlaySnapGuides.none;
    notifyListeners();
  }

  // ─── Drag (resize handle, single item) ──────────────────────────────────

  void beginResizeDrag(String id) {
    if (!editMode || _paneW <= 0 || _paneH <= 0) return;
    final item = _find(id);
    if (item == null || !item.resizable) return;
    if (!_selected.contains(id)) selectItem(id);
    final (x, y, w, h) = _rect(item);
    _resizeDrag = _ResizeDrag(
      id: id,
      left: x,
      top: y,
      w: w,
      h: h,
      // Resize snaps to real EDGES only — an item's center is not a
      // meaningful size target and made the old editor feel trapped.
      lines: _snapLines(excludeIds: {id}, includeCenters: false),
    );
  }

  void updateResizeDrag(double dx, double dy, {required bool snap}) {
    final d = _resizeDrag;
    if (d == null) return;
    final item = _find(d.id);
    if (item == null) return;
    d.rawW += dx;
    d.rawH += dy;
    var nw = math.max(d.rawW, OverlayGeometry.minRenderedPx);
    var nh = math.max(d.rawH, OverlayGeometry.minRenderedPx);
    double? gx, gy;
    if (snap && snapEnabled) {
      final sx = _snapAxis([d.left + nw], d.lines.vx);
      final sy = _snapAxis([d.top + nh], d.lines.hy);
      nw += sx.$1;
      nh += sy.$1;
      gx = sx.$2;
      gy = sy.$2;
    }
    snapGuides = OverlaySnapGuides(
      vx: gx != null ? [gx] : const [],
      hy: gy != null ? [gy] : const [],
    );
    final s = OverlayGeometry.paneScale(_paneW, _paneH);
    item.setBaseSize(s <= 0 ? nw : nw / s, s <= 0 ? nh : nh / s);
    geometry.tick();
  }

  void endResizeDrag() {
    _resizeDrag = null;
    snapGuides = OverlaySnapGuides.none;
    notifyListeners();
  }

  // ─── Internals ──────────────────────────────────────────────────────────

  OverlayItem? _find(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  (double, double, double, double) _rect(OverlayItem item) =>
      OverlayGeometry.rectFor(
        item,
        _paneW,
        _paneH,
        videoW: _videoW,
        videoH: _videoH,
      );

  (double, double, double, double) _field() => OverlayGeometry.fieldRect(
        _anchor,
        _paneW,
        _paneH,
        videoW: _videoW,
        videoH: _videoH,
      );

  /// Write a pane-px top-left back to the item's normalized coordinates.
  void _setNormPos(OverlayItem item, double px, double py) {
    final (fx, fy, fw, fh) = _field();
    item.x = fw <= 0 ? 0 : ((px - fx) / fw).clamp(0, 1).toDouble();
    item.y = fh <= 0 ? 0 : ((py - fy) / fh).clamp(0, 1).toDouble();
  }

  /// Candidate snap lines from the non-moving items' edges (+ centers for
  /// move gestures) and the anchor field's edges/center, in logical px.
  OverlaySnapGuides _snapLines({
    required Set<String> excludeIds,
    required bool includeCenters,
  }) {
    final (fx, fy, fw, fh) = _field();
    final vx = <double>[fx, fx + fw, if (includeCenters) fx + fw / 2];
    final hy = <double>[fy, fy + fh, if (includeCenters) fy + fh / 2];
    for (final o in _items) {
      if (excludeIds.contains(o.id)) continue;
      final (x, y, w, h) = _rect(o);
      vx.addAll([x, x + w]);
      hy.addAll([y, y + h]);
      if (includeCenters) {
        vx.add(x + w / 2);
        hy.add(y + h / 2);
      }
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

  @override
  void dispose() {
    geometry.dispose();
    super.dispose();
  }
}
