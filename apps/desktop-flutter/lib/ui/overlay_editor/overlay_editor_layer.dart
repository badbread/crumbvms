// The overlay editor's render + gesture layer (edit + view mode) — lifted
// from `ptz/ptz_panel_overlay.dart`'s Stack/hit-test structure and
// generalized over any `OverlayItem`. Item VISUALS (body/selection styling)
// come from a host delegate ([OverlayItemBuilder]); this layer owns only the
// generic chrome: the opaque per-item hit target (so gaps between items fall
// through to whatever's underneath — the video pane's own gestures), the
// delete (x) / resize handles in edit mode, and the snap-guide lines.
// Handles are suppressed below [kOverlayHandleMinRenderedPx] (repairs the PTZ
// panel's D6 defect — a small button's handles could cover its whole body,
// see the desktop P0 plan §3.2) — use the editor bar's size stepper /
// selected-item Delete button instead at that size.
//
// Usage: stack this INSIDE the same-sized `Positioned.fill` video pane that
// hosts the Video widget, above it in z-order — same placement rule as
// `PtzPanelOverlay`:
//
//   Stack(children: [
//     Video(controller: videoController),
//     Positioned.fill(child: OverlayEditorLayer(
//       controller: controller,
//       editing: controller.editMode,
//       buildItem: myBuildItem,
//       videoW: videoW, videoH: videoH, // only needed for videoFrame items
//     )),
//   ])

import 'package:flutter/material.dart';

import 'overlay_editor_controller.dart';
import 'overlay_geometry.dart';
import 'overlay_item.dart';

/// Host-supplied item visual: body/selection styling only — NOT the hit
/// target or edit-mode handles, which this layer draws itself.
typedef OverlayItemBuilder =
    Widget Function(
      OverlayItem item, {
      required bool editing,
      required bool selected,
    });

/// Below this rendered size (logical px, either dimension), the delete/resize
/// handles are hidden — repairs the PTZ panel's D6 defect where a small
/// button's own handles could cover most/all of its body. Use the editor
/// bar's size stepper / selected-item Delete button instead at this size.
const double kOverlayHandleMinRenderedPx = 24;

class OverlayEditorLayer extends StatelessWidget {
  const OverlayEditorLayer({
    super.key,
    required this.controller,
    required this.buildItem,
    this.editing = false,
    this.items,
    this.videoW,
    this.videoH,
    this.onTapItem,
    this.emptyEditHint,
  });

  final OverlayEditorController controller;

  /// Item body/selection visual — see [OverlayItemBuilder].
  final OverlayItemBuilder buildItem;

  /// True renders the LIVE edit session (`controller.items`, drag/resize,
  /// handles, snap guides). False renders a read-only view-mode layer from
  /// [items] (badges/buttons only, tap dispatches [onTapItem]).
  final bool editing;

  /// View-mode item list — required (and used) when [editing] is false;
  /// ignored while editing (the controller's own live `items` drives that).
  final List<OverlayItem>? items;

  /// Decoded video pixel size — needed only for `OverlayAnchor.videoFrame`
  /// items. Those are skipped entirely (both modes) until both are known,
  /// rather than falling back to a misplaced full-pane guess.
  final int? videoW;
  final int? videoH;

  /// View-mode tap dispatch (e.g. show a state card). Edit-mode taps select
  /// the item instead and never call this.
  final void Function(OverlayItem item)? onTapItem;

  /// Edit-mode placeholder text shown centered when there are no items yet
  /// (e.g. "Add controls from the bar, then drag them where you want"). Null
  /// shows nothing.
  final String? emptyEditHint;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final source = editing ? controller.items : (items ?? const []);
        final hasVideoDims =
            videoW != null && videoH != null && videoW! > 0 && videoH! > 0;
        final visible = [
          for (final item in source)
            if (item.anchor != OverlayAnchor.videoFrame || hasVideoDims) item,
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            if (w <= 0 || h <= 0) return const SizedBox.shrink();
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final item in visible)
                  _OverlayItemWidget(
                    key: ValueKey(item.id),
                    controller: controller,
                    item: item,
                    paneW: w,
                    paneH: h,
                    videoW: videoW,
                    videoH: videoH,
                    editing: editing,
                    selected: editing && controller.selectedId == item.id,
                    buildItem: buildItem,
                    onTap: onTapItem,
                  ),
                if (editing) ..._snapGuideLines(controller.snapGuides, w, h),
                if (editing && visible.isEmpty && emptyEditHint != null)
                  Center(child: _hintChip(emptyEditHint!)),
              ],
            );
          },
        );
      },
    );
  }

  List<Widget> _snapGuideLines(OverlaySnapGuides g, double w, double h) {
    const color = Color(0x664CC9FF);
    return [
      for (final x in g.vx)
        Positioned(
          left: x,
          top: 0,
          width: 1,
          height: h,
          child: Container(color: color),
        ),
      for (final y in g.hy)
        Positioned(
          left: 0,
          top: y,
          width: w,
          height: 1,
          child: Container(color: color),
        ),
    ];
  }

  Widget _hintChip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
  );
}

class _OverlayItemWidget extends StatelessWidget {
  const _OverlayItemWidget({
    super.key,
    required this.controller,
    required this.item,
    required this.paneW,
    required this.paneH,
    required this.videoW,
    required this.videoH,
    required this.editing,
    required this.selected,
    required this.buildItem,
    required this.onTap,
  });

  final OverlayEditorController controller;
  final OverlayItem item;
  final double paneW;
  final double paneH;
  final int? videoW;
  final int? videoH;
  final bool editing;
  final bool selected;
  final OverlayItemBuilder buildItem;
  final void Function(OverlayItem item)? onTap;

  static const double _handle = 16;

  @override
  Widget build(BuildContext context) {
    final (x, y, w, h) = OverlayGeometry.rectFor(
      item,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    return Positioned(
      left: x,
      top: y,
      width: w,
      height: h,
      child: editing ? _editBody(w, h) : _viewBody(),
    );
  }

  // ─── Edit-mode: draggable body + delete/resize handles ─────────────────

  Widget _editBody(double w, double h) {
    final showHandles =
        w >= kOverlayHandleMinRenderedPx && h >= kOverlayHandleMinRenderedPx;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => controller.selectItem(item.id),
      onPanStart: (_) => controller.selectItem(item.id),
      onPanUpdate: (d) => controller.moveItemByDelta(
        item.id,
        paneW,
        paneH,
        d.delta.dx,
        d.delta.dy,
        videoW: videoW,
        videoH: videoH,
      ),
      onPanEnd: (_) => controller.commitDrag(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Explicit SizedBox: a Stack loosens the constraints of a
          // non-positioned child, so the delegate's returned widget must be
          // told its exact target size rather than relying on it to
          // self-size correctly under loose constraints (mirrors
          // `PtzPanelOverlay`'s `Container(width: w, height: h, ...)`).
          SizedBox(
            width: w,
            height: h,
            child: buildItem(item, editing: true, selected: selected),
          ),
          // Delete (x) handle, top-right.
          if (showHandles)
            Positioned(
              right: 0,
              top: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => controller.removeItem(item.id),
                child: Container(
                  width: _handle,
                  height: _handle,
                  decoration: const BoxDecoration(color: Color(0xCC2030D0)),
                  alignment: Alignment.center,
                  child: const Text(
                    '×',
                    style: TextStyle(color: Colors.white, fontSize: 13, height: 1),
                  ),
                ),
              ),
            ),
          // Resize handle, bottom-right — only when selected AND the item
          // opts into drag-resize (`OverlayItem.resizable`).
          if (showHandles && selected && item.resizable)
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => controller.resizeItemByDelta(
                  item.id,
                  paneW,
                  paneH,
                  d.delta.dx,
                  d.delta.dy,
                  videoW: videoW,
                  videoH: videoH,
                ),
                onPanEnd: (_) => controller.commitDrag(),
                child: Container(
                  width: _handle,
                  height: _handle,
                  decoration: const BoxDecoration(color: Color(0xE62CA3E8)),
                  child: const Icon(Icons.south_east, size: 12, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── View mode: only the item glyph is an opaque hit target ────────────

  Widget _viewBody() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null ? null : () => onTap!(item),
      child: buildItem(item, editing: false, selected: false),
    );
  }
}
