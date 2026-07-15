// The overlay editor's render + gesture layer (edit + view mode). Item
// VISUALS (body/selection styling) come from a host delegate
// ([OverlayItemBuilder]); this layer owns only the generic chrome: the opaque
// per-item hit target (so gaps between items fall through to whatever's
// underneath — the video pane's own gestures in VIEW mode), the delete (x) /
// resize handles in edit mode, the snap-guide lines, and the marquee
// box-select.
//
// ── Rebuild discipline (the anti-stutter contract, see
//    `overlay_editor_controller.dart`'s file doc) ─────────────────────────────
// The layer's STRUCTURE (item set, selection, mode) rebuilds on the
// controller's own notifications. Per-pointer-move drag ticks fire only
// `controller.geometry`; each item subscribes just its `Positioned` wrapper
// to that (the item's visual subtree is passed as a prebuilt `child`, wrapped
// in a `RepaintBoundary`), so a drag re-positions a few boxes per frame
// instead of rebuilding every item, the editor bar and the host palette.
//
// ── Edit-mode gestures ──────────────────────────────────────────────────────
// * click an item — select it (its whole group); Shift/Ctrl-click toggles it
//   in/out of the selection.
// * drag an item — moves the whole selection; hold Alt to suppress snapping
//   for the gesture.
// * drag empty space — marquee box-select; click empty space — clear
//   selection. (The edit-mode background is an opaque hit target, so video
//   gestures — double-click restore, PTZ steering — can't fire mid-edit.)
//
// Usage: stack this INSIDE the same-sized `Positioned.fill` video pane that
// hosts the Video widget, above it in z-order:
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
import 'package:flutter/services.dart';

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

class OverlayEditorLayer extends StatefulWidget {
  const OverlayEditorLayer({
    super.key,
    required this.controller,
    required this.buildItem,
    this.editing = false,
    this.items,
    this.videoW,
    this.videoH,
    this.onTapItem,
    this.onHoverItem,
    this.emptyEditHint,
  });

  final OverlayEditorController controller;

  /// Item body/selection visual — see [OverlayItemBuilder].
  final OverlayItemBuilder buildItem;

  /// True renders the LIVE edit session (`controller.items`, drag/resize,
  /// handles, snap guides, marquee). False renders a read-only view-mode
  /// layer from [items] (badges/buttons only, tap dispatches [onTapItem]).
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

  /// View-mode hover dispatch (mouse enter/leave over an item's hit target) —
  /// e.g. the HA host's hover-reveal of the badge's live state. Null adds no
  /// MouseRegion at all.
  final void Function(OverlayItem item, bool hovering)? onHoverItem;

  /// Edit-mode placeholder text shown centered when there are no items yet
  /// (e.g. "Add controls from the bar, then drag them where you want"). Null
  /// shows nothing.
  final String? emptyEditHint;

  @override
  State<OverlayEditorLayer> createState() => _OverlayEditorLayerState();
}

class _OverlayEditorLayerState extends State<OverlayEditorLayer> {
  /// Live marquee rect (pane-local px) while box-selecting, else null. A
  /// ValueNotifier so only the marquee visual repaints per pointer move — the
  /// selection updates it drives already no-op unless membership changes.
  final ValueNotifier<Rect?> _marquee = ValueNotifier<Rect?>(null);
  Offset? _marqueeStart;

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  static bool get _toggleModifier =>
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isControlPressed;

  static bool get _snapForGesture => !HardwareKeyboard.instance.isAltPressed;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final source =
            widget.editing ? controller.items : (widget.items ?? const []);
        final hasVideoDims = widget.videoW != null &&
            widget.videoH != null &&
            widget.videoW! > 0 &&
            widget.videoH! > 0;
        final visible = [
          for (final item in source)
            if (item.anchor != OverlayAnchor.videoFrame || hasVideoDims) item,
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            if (w <= 0 || h <= 0) return const SizedBox.shrink();
            if (widget.editing) {
              // Selection ops / marquee math need the pane metrics; plain
              // field writes, safe during build.
              controller.updatePaneMetrics(
                w,
                h,
                videoW: widget.videoW,
                videoH: widget.videoH,
              );
            }
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                if (widget.editing) Positioned.fill(child: _marqueeTarget()),
                for (final item in visible)
                  _OverlayItemWidget(
                    key: ValueKey(item.id),
                    controller: controller,
                    item: item,
                    paneW: w,
                    paneH: h,
                    videoW: widget.videoW,
                    videoH: widget.videoH,
                    editing: widget.editing,
                    selected: widget.editing && controller.isSelected(item.id),
                    buildItem: widget.buildItem,
                    onTap: widget.onTapItem,
                    onHover: widget.onHoverItem,
                  ),
                if (widget.editing)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: controller.geometry,
                        builder: (context, _) => Stack(
                          children:
                              _snapGuideLines(controller.snapGuides, w, h),
                        ),
                      ),
                    ),
                  ),
                if (widget.editing)
                  // Positioned stays a DIRECT child of a Stack (the inner
                  // one) — the repo has been bitten by Positioned under a
                  // builder blanking the release UI (see wall_screen.dart's
                  // ConnLostBanner note), so the builder wraps a Stack, not
                  // a Positioned.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ValueListenableBuilder<Rect?>(
                        valueListenable: _marquee,
                        builder: (context, r, _) => Stack(
                          children: [
                            if (r != null)
                              Positioned(
                                left: r.left,
                                top: r.top,
                                width: r.width,
                                height: r.height,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0x224CC9FF),
                                    border: Border.all(
                                      color: const Color(0x884CC9FF),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (widget.editing &&
                    visible.isEmpty &&
                    widget.emptyEditHint != null)
                  Center(child: _hintChip(widget.emptyEditHint!)),
              ],
            );
          },
        );
      },
    );
  }

  /// The edit-mode background: opaque (blocks the video pane's own gestures —
  /// no accidental double-click restore or PTZ steer mid-edit), tap clears
  /// the selection, drag draws the marquee box-select.
  Widget _marqueeTarget() {
    final controller = widget.controller;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.clearSelection,
      onPanStart: (d) {
        _marqueeStart = d.localPosition;
        _marquee.value = Rect.fromPoints(d.localPosition, d.localPosition);
      },
      onPanUpdate: (d) {
        final s = _marqueeStart;
        if (s == null) return;
        final r = Rect.fromPoints(s, d.localPosition);
        _marquee.value = r;
        controller.marqueeSelect(r.left, r.top, r.right, r.bottom);
      },
      onPanEnd: (_) {
        _marqueeStart = null;
        _marquee.value = null;
      },
      onPanCancel: () {
        _marqueeStart = null;
        _marquee.value = null;
      },
      child: const SizedBox.expand(),
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
    required this.onHover,
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
  final void Function(OverlayItem item, bool hovering)? onHover;

  static const double _handle = 16;

  @override
  Widget build(BuildContext context) {
    // Built ONCE per structure change; the geometry AnimatedBuilder below
    // only re-positions it per drag tick (see the file doc's rebuild
    // discipline). RepaintBoundary keeps a moving item's repaint from
    // spilling into the rest of the layer.
    //
    // Structure note: this widget is a direct child of the layer's Stack,
    // and renders `Positioned.fill` → AnimatedBuilder → INNER Stack →
    // Positioned, so every Positioned stays the DIRECT child of a Stack
    // (a Positioned under a builder has blanked the release UI before —
    // see wall_screen.dart's ConnLostBanner note). The fill wrapper itself
    // claims no hits: only the inner GestureDetector's rect is a target,
    // so gaps between items still fall through to the video pane.
    final body = RepaintBoundary(
      child: editing ? _editBody() : _viewBody(),
    );
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: controller.geometry,
        child: body,
        builder: (context, child) {
          final (x, y, w, h) = OverlayGeometry.rectFor(
            item,
            paneW,
            paneH,
            videoW: videoW,
            videoH: videoH,
          );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: x,
                top: y,
                width: w,
                height: h,
                child: child!,
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── Edit-mode: draggable body + delete/resize handles ─────────────────

  Widget _editBody() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_OverlayEditorLayerState._toggleModifier) {
          controller.toggleSelect(item.id);
        } else {
          controller.selectItem(item.id);
        }
      },
      onPanStart: (_) => controller.beginDrag(item.id),
      onPanUpdate: (d) => controller.updateDrag(
        d.delta.dx,
        d.delta.dy,
        snap: _OverlayEditorLayerState._snapForGesture,
      ),
      onPanEnd: (_) => controller.endDrag(),
      onPanCancel: controller.endDrag,
      // LayoutBuilder (fed by the tight Positioned constraints) rather than
      // captured w/h, so a resize drag re-sizes the visual without a
      // structure rebuild.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final showHandles = w >= kOverlayHandleMinRenderedPx &&
              h >= kOverlayHandleMinRenderedPx;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Explicit SizedBox: a Stack loosens the constraints of a
              // non-positioned child, so the delegate's returned widget must
              // be told its exact target size rather than relying on it to
              // self-size correctly under loose constraints.
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
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          height: 1,
                        ),
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
                    onPanStart: (_) => controller.beginResizeDrag(item.id),
                    onPanUpdate: (d) => controller.updateResizeDrag(
                      d.delta.dx,
                      d.delta.dy,
                      snap: _OverlayEditorLayerState._snapForGesture,
                    ),
                    onPanEnd: (_) => controller.endResizeDrag(),
                    onPanCancel: controller.endResizeDrag,
                    child: Container(
                      width: _handle,
                      height: _handle,
                      decoration: const BoxDecoration(color: Color(0xE62CA3E8)),
                      child: const Icon(
                        Icons.south_east,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ─── View mode: only the item glyph is an opaque hit target ────────────

  Widget _viewBody() {
    final Widget body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null ? null : () => onTap!(item),
      child: buildItem(item, editing: false, selected: false),
    );
    final hover = onHover;
    if (hover == null) return body;
    return MouseRegion(
      onEnter: (_) => hover(item, true),
      onExit: (_) => hover(item, false),
      child: body,
    );
  }
}
