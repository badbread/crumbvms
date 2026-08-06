// The HA badge editor's POPOVER — everything about ONE badge, anchored to
// that badge with an arrow, instead of in a panel parked somewhere else on
// screen.
//
// This replaces three surfaces at once (all deleted in the same change): the
// floating `HaOverlayEditPanel` window, its `showDialog` icon picker, and its
// `showColorSwatchPicker` dialogs. Each of those had the same defect for this
// particular job — the operator was picking a color or a glyph for a badge
// they could not see while picking it, because the chooser covered the video
// (or, in the panel's case, sat far enough away that the eye had to travel).
// Anchoring to the badge and expanding the choosers INLINE keeps the thing
// being edited and the control editing it in one glance:
//
//   ┌─ popover (≈300px) ───────────┐
//   │ Front Door        ✎  🗑      │  header: name, inline label edit, remove
//   │ Icon   [🚪 Door        ▾]    │  → expands an inline searchable icon grid
//   │ Shape  [ Dot ][ Pill ]       │
//   │ Colors                       │
//   │  Accent  ● Auto: state color │  → expands an inline swatch strip
//   │  Background  [Off ] [On  🔗] │  → two swatches; clicking one ALSO flips
//   │ Size   [−][ 22 ][+]          │    the top bar's state preview to that
//   │ Opacity ▬▬▬▬▬▬○  100%        │    state, so you see the color you edit
//   │ ☐ Pin state  ☐ Pin time  …   │
//   │ Reset style                  │
//   └──────────────────────────────┘
//
// The paired Off/On background swatches are the reason the state preview
// exists: `overlay_bg_color_on` is only visible when the entity reads on, and
// an operator cannot wait for their front door to open to check a color. See
// `HaOverlayController.previewState`.
//
// With 2+ badges selected the popover keeps its anchor (the PRIMARY / REF
// selection) and swaps its body for the geometry toolset — align, distribute,
// match size, group, shared size/opacity, delete — which is what survived of
// the retired bottom `OverlayEditorBar`. Style editing stays single-selection
// deliberately: "make these five badges purple" reads fine as a sentence but
// is a footgun with per-state colors, and nothing in the placement model
// carries a style group.
//
// Nothing here persists — every edit follows the shared editor's host-side
// mutation contract (`pushUndo()` → mutate the item → `notifyItemsChanged()`),
// so Ctrl+Z steps back through style changes and geometry changes alike, and
// the whole session round-trips to the server only on Done
// (`HaOverlayController.endEditAndSave`).

import 'package:flutter/material.dart';

import '../color_swatch_picker.dart';
import '../hotkeys/hotkey_gate.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import '../overlay_editor/overlay_geometry.dart';
import 'ha_icons.dart';
import 'ha_overlay_controller.dart' show HaOverlayBadgeItem, HaOverlayController;

/// Full-gamut swatch set for the badge accent + background pickers — NOT the
/// pastel camera palette (which is tuned for timeline distinguishability).
/// Neutrals (black → white) plus saturated hues across bright and deep, so an
/// operator can pick anything from a solid black chip to a bright accent; the
/// custom wheel covers everything in between.
const List<Color> kBadgeSwatchPalette = [
  // neutrals
  Color(0xFF000000), Color(0xFF3A3A3A), Color(0xFF757575),
  Color(0xFFBDBDBD), Color(0xFFFFFFFF),
  // bright saturated
  Color(0xFFF44336), Color(0xFFFF7043), Color(0xFFFF9800), Color(0xFFFFC107),
  Color(0xFFFFEB3B), Color(0xFFCDDC39), Color(0xFF8BC34A), Color(0xFF4CAF50),
  Color(0xFF009688), Color(0xFF00BCD4), Color(0xFF03A9F4), Color(0xFF2196F3),
  Color(0xFF3F51B5), Color(0xFF673AB7), Color(0xFF9C27B0), Color(0xFFE91E63),
  // deep / dark
  Color(0xFFB71C1C), Color(0xFFE65100), Color(0xFF1B5E20), Color(0xFF006064),
  Color(0xFF0D47A1), Color(0xFF4A148C),
];

/// Format a picked color back to the stored '#RRGGBB' form
/// (the inverse of `parseOverlayColorHex`).
String overlayColorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The default dark chip a badge falls back to with no background override —
/// mirrors `ha_overlay_layer.dart`'s private `_kBadgeDefaultBg` so the "Off"
/// swatch previews the real default rather than a lookalike.
const Color kBadgeDefaultBgPreview = Color(0xFF17171B);

const double kHaPopoverWidth = 300;

// ─── Placement (pure) ───────────────────────────────────────────────────────

/// Which side of the anchor badge the popover ended up on — drives which edge
/// the arrow is drawn against.
enum HaPopoverSide { right, left, below, above }

/// Where to put the popover, and where along its arrow edge the arrow points.
class HaPopoverPlacement {
  const HaPopoverPlacement({
    required this.side,
    required this.left,
    required this.top,
    required this.arrowOffset,
  });

  final HaPopoverSide side;

  /// Popover top-left in pane-local logical px.
  final double left;
  final double top;

  /// Distance from the popover's top (for [HaPopoverSide.right]/[left]) or
  /// left (for [below]/[above]) to the arrow's tip — already clamped inside
  /// the popover's rounded corners, so the arrow never grows out of a corner.
  final double arrowOffset;

  @override
  String toString() =>
      'HaPopoverPlacement($side, left: $left, top: $top, arrow: $arrowOffset)';
}

/// Choose the popover's side and position: prefer the RIGHT of the badge, then
/// left, then below, then above — the first side the popover fits on wins. If
/// it fits nowhere (a small pane, a large popover) the side with the most room
/// wins and the position is clamped into the pane, which degrades to "slightly
/// overlapping the badge" instead of "half off screen".
///
/// Pure — no BuildContext, no widgets — so the flip rules are unit-testable.
/// [popover] is the caller's estimate of the rendered size; the widget itself
/// self-sizes, so an estimate that is a little off only affects which side is
/// chosen, never whether the popover renders correctly.
/// [topMargin] (default [margin]) reserves room for chrome pinned over the top
/// of the video. The editor's own top bar does NOT need it — that bar is a
/// sibling of the video viewport rather than an overlay on it, so the frame is
/// never occluded (see the maximized pane's build) — but the pane's floating
/// back button and camera-name pill do sit over the frame's top-left, and this
/// is the knob for keeping clear of them.
HaPopoverPlacement resolveHaPopoverPlacement({
  required Rect badge,
  required Size popover,
  required Size pane,
  double gap = 12,
  double margin = 8,
  double cornerPad = 18,
  double? topMargin,
}) {
  final mTop = topMargin ?? margin;

  double clampX(double v) {
    final max = pane.width - margin - popover.width;
    if (max <= margin) return margin; // pane narrower than the popover
    return v.clamp(margin, max).toDouble();
  }

  double clampY(double v) {
    final max = pane.height - margin - popover.height;
    if (max <= mTop) return mTop; // pane shorter than the popover
    return v.clamp(mTop, max).toDouble();
  }

  // Room available on each side, in that side's own axis.
  final roomRight = pane.width - margin - (badge.right + gap);
  final roomLeft = (badge.left - gap) - margin;
  final roomBelow = pane.height - margin - (badge.bottom + gap);
  final roomAbove = (badge.top - gap) - mTop;

  final fits = <HaPopoverSide, bool>{
    HaPopoverSide.right: roomRight >= popover.width,
    HaPopoverSide.left: roomLeft >= popover.width,
    HaPopoverSide.below: roomBelow >= popover.height,
    HaPopoverSide.above: roomAbove >= popover.height,
  };

  HaPopoverSide side;
  const order = [
    HaPopoverSide.right,
    HaPopoverSide.left,
    HaPopoverSide.below,
    HaPopoverSide.above,
  ];
  final first = order.where((s) => fits[s] == true);
  if (first.isNotEmpty) {
    side = first.first;
  } else {
    // Nothing fits: take the roomiest side. Compare each side's spare room
    // against what it needs so a tall-but-narrow pane still picks sensibly.
    final spare = <HaPopoverSide, double>{
      HaPopoverSide.right: roomRight - popover.width,
      HaPopoverSide.left: roomLeft - popover.width,
      HaPopoverSide.below: roomBelow - popover.height,
      HaPopoverSide.above: roomAbove - popover.height,
    };
    side = order.reduce((a, b) => spare[a]! >= spare[b]! ? a : b);
  }

  switch (side) {
    case HaPopoverSide.right:
    case HaPopoverSide.left:
      final left = side == HaPopoverSide.right
          ? clampX(badge.right + gap)
          : clampX(badge.left - gap - popover.width);
      final top = clampY(badge.center.dy - popover.height / 2);
      return HaPopoverPlacement(
        side: side,
        left: left,
        top: top,
        arrowOffset: _clampArrow(badge.center.dy - top, popover.height,
            cornerPad),
      );
    case HaPopoverSide.below:
    case HaPopoverSide.above:
      final top = side == HaPopoverSide.below
          ? clampY(badge.bottom + gap)
          : clampY(badge.top - gap - popover.height);
      final left = clampX(badge.center.dx - popover.width / 2);
      return HaPopoverPlacement(
        side: side,
        left: left,
        top: top,
        arrowOffset:
            _clampArrow(badge.center.dx - left, popover.width, cornerPad),
      );
  }
}

double _clampArrow(double v, double extent, double cornerPad) {
  final max = extent - cornerPad;
  if (max <= cornerPad) return extent / 2;
  return v.clamp(cornerPad, max).toDouble();
}

// ─── The layer ──────────────────────────────────────────────────────────────

/// Which inline chooser (if any) is currently expanded inside the popover.
/// Held by the LAYER, not the body, for two reasons: the expansion changes the
/// popover's height, which the layer needs before it can choose a side; and it
/// must survive the body rebuilding on every editor notification.
enum _Section { icon, accent, bgOff, bgOn }

/// `Positioned.fill` over the maximized pane while an HA overlay edit session
/// is active: renders the badge popover anchored to the current selection, or
/// nothing when there is no selection.
class HaBadgePopoverLayer extends StatefulWidget {
  const HaBadgePopoverLayer({
    super.key,
    required this.host,
    required this.videoW,
    required this.videoH,
    this.topInset = 0,
  });

  final HaOverlayController host;

  /// Height of the pane chrome that FLOATS over the video and paints above
  /// this layer — the back button, the camera-name pill, the live-status
  /// badges. The popover keeps clear of it rather than sliding underneath
  /// when a badge sits near the top of the frame. (The editor's own top bar
  /// is NOT included: it is a sibling of the video viewport, so it covers no
  /// part of the frame.)
  final double topInset;

  /// Decoded video pixel size — the badges are video-frame anchored, so the
  /// popover cannot compute its anchor rect without them (same gate as the
  /// editor layer itself).
  final int? videoW;
  final int? videoH;

  @override
  State<HaBadgePopoverLayer> createState() => _HaBadgePopoverLayerState();
}

class _HaBadgePopoverLayerState extends State<HaBadgePopoverLayer> {
  _Section? _section;

  /// The selection the current [_section] belongs to — selecting a different
  /// badge collapses whatever chooser was open on the old one.
  String? _sectionFor;

  void _toggleSection(_Section s, String itemId) {
    setState(() {
      final same = _section == s && _sectionFor == itemId;
      _sectionFor = itemId;
      _section = same ? null : s;
    });
  }

  void _closeSection() => setState(() => _section = null);

  /// Rough rendered height, used ONLY to choose which side of the badge the
  /// popover opens on (see [resolveHaPopoverPlacement]).
  double _estimateHeight({required bool multi, required _Section? open}) {
    if (multi) return 300;
    var h = 470.0;
    switch (open) {
      case _Section.icon:
        h += 214;
      case _Section.accent:
      case _Section.bgOff:
      case _Section.bgOn:
        h += 104;
      case null:
        break;
    }
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.host.editor;
    // Merged with the geometry ticker so a DRAG (which fires only geometry
    // ticks, by the editor's anti-stutter contract) can hide the popover —
    // otherwise it would sit over the video the operator is dragging across.
    return AnimatedBuilder(
      animation: Listenable.merge([editor, editor.geometry]),
      builder: (context, _) {
        if (!editor.editMode) return const SizedBox.shrink();
        final primary = editor.selected;
        if (primary is! HaOverlayBadgeItem) return const SizedBox.shrink();
        if (widget.videoW == null || widget.videoH == null) {
          return const SizedBox.shrink();
        }
        final multi = editor.selectedIds.length > 1;
        if (_sectionFor != primary.id && _section != null) {
          // Selection moved on; drop the stale expansion on the next frame
          // (we're inside build, so no setState here).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _section = null);
          });
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final paneW = constraints.maxWidth;
            final paneH = constraints.maxHeight;
            if (paneW <= 0 || paneH <= 0) return const SizedBox.shrink();

            final (x, y, w, h) = OverlayGeometry.rectFor(
              primary,
              paneW,
              paneH,
              videoW: widget.videoW,
              videoH: widget.videoH,
            );
            final placement = resolveHaPopoverPlacement(
              badge: Rect.fromLTWH(x, y, w, h),
              popover: Size(
                kHaPopoverWidth,
                _estimateHeight(multi: multi, open: _section),
              ),
              pane: Size(paneW, paneH),
              topMargin: widget.topInset > 0 ? widget.topInset + 8 : null,
            );

            final body = multi
                ? _MultiSelectBody(host: widget.host)
                : _StyleBody(
                    key: ValueKey(primary.id),
                    host: widget.host,
                    item: primary,
                    section: _sectionFor == primary.id ? _section : null,
                    onToggleSection: (s) => _toggleSection(s, primary.id),
                    onCloseSection: _closeSection,
                  );

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: placement.left,
                  top: placement.top,
                  child: Offstage(
                    // Hidden (but kept alive, so the label field and any open
                    // chooser survive) while a drag is in flight.
                    offstage: editor.isDragging,
                    child: _PopoverFrame(
                      placement: placement,
                      maxHeight: paneH - widget.topInset - 16,
                      child: body,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The popover's chrome: rounded dark card + the arrow pointing back at the
/// badge it belongs to.
class _PopoverFrame extends StatelessWidget {
  const _PopoverFrame({
    required this.placement,
    required this.maxHeight,
    required this.child,
  });

  final HaPopoverPlacement placement;
  final double maxHeight;
  final Widget child;

  static const double _arrow = 8;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: kHaPopoverWidth,
      decoration: BoxDecoration(
        color: const Color(0xF21A1D22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
        boxShadow: const [
          BoxShadow(color: Color(0x99000000), blurRadius: 14, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(12),
      // The design is a no-scroll popover, and the content is sized to fit a
      // maximized pane. This guard exists only so a short pane (or a very
      // large text scale) degrades to a scroll instead of a RenderFlex
      // overflow — it is inert whenever the content fits.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(child: child),
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          left: switch (placement.side) {
            HaPopoverSide.right => -_arrow + 1,
            HaPopoverSide.left => null,
            _ => placement.arrowOffset - _arrow,
          },
          right: placement.side == HaPopoverSide.left ? -_arrow + 1 : null,
          top: switch (placement.side) {
            HaPopoverSide.below => -_arrow + 1,
            HaPopoverSide.above => null,
            _ => placement.arrowOffset - _arrow,
          },
          bottom: placement.side == HaPopoverSide.above ? -_arrow + 1 : null,
          child: IgnorePointer(
            child: CustomPaint(
              size: switch (placement.side) {
                HaPopoverSide.right ||
                HaPopoverSide.left =>
                  const Size(_arrow, _arrow * 2),
                _ => const Size(_arrow * 2, _arrow),
              },
              painter: _ArrowPainter(placement.side),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter(this.side);
  final HaPopoverSide side;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = const Color(0xF21A1D22);
    final path = Path();
    switch (side) {
      // The arrow points AWAY from the card, back toward the badge.
      case HaPopoverSide.right:
        path
          ..moveTo(size.width, 0)
          ..lineTo(0, size.height / 2)
          ..lineTo(size.width, size.height);
      case HaPopoverSide.left:
        path
          ..moveTo(0, 0)
          ..lineTo(size.width, size.height / 2)
          ..lineTo(0, size.height);
      case HaPopoverSide.below:
        path
          ..moveTo(0, size.height)
          ..lineTo(size.width / 2, 0)
          ..lineTo(size.width, size.height);
      case HaPopoverSide.above:
        path
          ..moveTo(0, 0)
          ..lineTo(size.width / 2, size.height)
          ..lineTo(size.width, 0);
    }
    path.close();
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) => old.side != side;
}

// ─── Single-selection body: the style form ──────────────────────────────────

class _StyleBody extends StatefulWidget {
  const _StyleBody({
    super.key,
    required this.host,
    required this.item,
    required this.section,
    required this.onToggleSection,
    required this.onCloseSection,
  });

  final HaOverlayController host;
  final HaOverlayBadgeItem item;
  final _Section? section;
  final void Function(_Section) onToggleSection;
  final VoidCallback onCloseSection;

  @override
  State<_StyleBody> createState() => _StyleBodyState();
}

class _StyleBodyState extends State<_StyleBody> {
  final _labelCtrl = TextEditingController();
  final _labelFocus = FocusNode();
  final _sizeCtrl = TextEditingController();
  final _sizeFocus = FocusNode();
  final _iconQueryCtrl = TextEditingController();
  final _iconFocus = FocusNode();

  bool _editingLabel = false;
  String _iconQuery = '';

  OverlayEditorController get _editor => widget.host.editor;
  HaOverlayBadgeItem get _item => widget.item;

  @override
  void initState() {
    super.initState();
    _labelCtrl.text = _item.labelText ?? '';
    // One undo entry per typing SESSION (on focus gain), not one per
    // keystroke — the behavior the retired panel had, kept verbatim.
    _labelFocus.addListener(() {
      if (_labelFocus.hasFocus) _editor.pushUndo();
    });
    _sizeFocus.addListener(() {
      if (!_sizeFocus.hasFocus) _submitSize();
    });
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _labelFocus.dispose();
    _sizeCtrl.dispose();
    _sizeFocus.dispose();
    _iconQueryCtrl.dispose();
    _iconFocus.dispose();
    super.dispose();
  }

  /// The shared host-side mutation contract: snapshot undo, mutate, repaint.
  void _mutate(VoidCallback change) {
    _editor.pushUndo();
    change();
    _editor.notifyItemsChanged();
  }

  void _submitSize() {
    final v = double.tryParse(_sizeCtrl.text.trim());
    if (v == null || v <= 0) return;
    if ((v - _item.baseSize().$2).abs() < 0.5) return;
    // A badge derives its scale from HEIGHT (square dot / pill of that
    // height), so a square set is the honest way to type an exact size.
    _mutate(() => _item.setBaseSize(v, v));
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    // Keep the fields in step when the item changes underneath us (undo/redo,
    // the ± stepper) while they aren't being typed into.
    final wantLabel = item.labelText ?? '';
    if (!_labelFocus.hasFocus && _labelCtrl.text != wantLabel) {
      _labelCtrl.text = wantLabel;
    }
    final wantSize = item.baseSize().$2.round().toString();
    if (!_sizeFocus.hasFocus && _sizeCtrl.text != wantSize) {
      _sizeCtrl.text = wantSize;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: 10),
        _iconRow(),
        if (widget.section == _Section.icon) _iconGrid(),
        const SizedBox(height: 8),
        _shapeRow(),
        const SizedBox(height: 10),
        const _SectionLabel('Colors'),
        const SizedBox(height: 6),
        _accentRow(),
        if (widget.section == _Section.accent)
          _swatchStrip(
            current: parseOverlayColorHex(item.colorHex),
            onPicked: (c) =>
                _mutate(() => item.colorHex = overlayColorToHex(c)),
          ),
        const SizedBox(height: 8),
        _backgroundRow(),
        if (widget.section == _Section.bgOff)
          _swatchStrip(
            current: parseOverlayColorHex(item.bgColorHex),
            onPicked: (c) =>
                _mutate(() => item.bgColorHex = overlayColorToHex(c)),
          ),
        if (widget.section == _Section.bgOn)
          _swatchStrip(
            current: parseOverlayColorHex(item.bgColorOnHex) ??
                parseOverlayColorHex(item.bgColorHex),
            onPicked: (c) =>
                _mutate(() => item.bgColorOnHex = overlayColorToHex(c)),
          ),
        const SizedBox(height: 10),
        _sizeRow(),
        const SizedBox(height: 6),
        _opacityRow(),
        const SizedBox(height: 8),
        _toggle(
          'Pin state text',
          'Always show the live state ("Open"/"On") next to the badge',
          item.showState,
          (v) => _mutate(() => item.showState = v),
        ),
        _toggle(
          'Pin last-changed time',
          'Always show the age ("2 m ago") next to the badge',
          item.showAge,
          (v) => _mutate(() => item.showAge = v),
        ),
        _toggle(
          'Outline + shadow',
          'Add a white outline and drop shadow so the badge pops on a busy '
              'scene',
          item.outline,
          (v) => _mutate(() => item.outline = v),
        ),
        const Divider(color: Colors.white12, height: 18),
        _resetFooter(),
      ],
    );
  }

  // ── Header: name + inline label edit + remove ─────────────────────────────

  Widget _header() {
    final item = _item;
    if (_editingLabel) {
      return Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 32,
              child: SuppressHotkeysWhileFocused(
                child: TextField(
                controller: _labelCtrl,
                focusNode: _labelFocus,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Badge label',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
                onChanged: (v) {
                  item.labelText = v;
                  // Live: a pill's width and a dot's caption both follow the
                  // label, so the badge reshapes as you type.
                  _editor.notifyItemsChanged();
                },
                onSubmitted: (_) => setState(() => _editingLabel = false),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Done',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.check, size: 16, color: Color(0xFF4CC9FF)),
            onPressed: () => setState(() => _editingLabel = false),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.displayLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                item.link.entityId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 10.5),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Rename badge',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.edit, size: 15, color: Colors.white70),
          onPressed: () => setState(() => _editingLabel = true),
        ),
        IconButton(
          tooltip: 'Remove this badge',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.delete_outline,
              size: 16, color: Color(0xFFE5484D)),
          onPressed: () => _editor.removeItem(item.id),
        ),
      ],
    );
  }

  // ── Icon: a row that expands an inline searchable grid ────────────────────

  Widget _iconRow() {
    final item = _item;
    final chosen = item.iconKey == null ? null : kHaBadgeIconChoices[item.iconKey!];
    final open = widget.section == _Section.icon;
    return _FieldRow(
      label: 'Icon',
      child: _PropButton(
        onTap: () => widget.onToggleSection(_Section.icon),
        child: Row(
          children: [
            Icon(chosen?.$1 ?? Icons.auto_awesome, size: 15),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                chosen?.$2 ?? 'Auto',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Icon(open ? Icons.expand_less : Icons.expand_more, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _iconGrid() {
    final q = _iconQuery.trim().toLowerCase();
    final entries = [
      for (final e in kHaBadgeIconChoices.entries)
        if (q.isEmpty ||
            e.value.$2.toLowerCase().contains(q) ||
            e.key.toLowerCase().contains(q))
          e,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 30,
            child: SuppressHotkeysWhileFocused(
              child: TextField(
              controller: _iconQueryCtrl,
              focusNode: _iconFocus,
              // The operator opened this grid deliberately and the next thing
              // they do is type a glyph name, so take focus immediately rather
              // than making them find the box. It also closes the window in
              // which a typed letter could reach a bare-key global shortcut
              // instead of the field.
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, color: Colors.white38, size: 15),
                prefixIconConstraints:
                    BoxConstraints(minWidth: 28, minHeight: 20),
                hintText: 'Search icons…',
                hintStyle: TextStyle(color: Colors.white38),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              ),
              onChanged: (v) => setState(() => _iconQuery = v),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // The one deliberate scroll region in the popover: ~90 glyphs cannot
          // be a flat row, and a dialog is what this whole design removed.
          SizedBox(
            height: 170,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  // "Auto" first: the class-derived default is the right answer
                  // for most badges, and it must be reachable to undo a pick.
                  _iconTile(
                    icon: Icons.auto_awesome,
                    tooltip: 'Auto (icon from the entity\'s device class)',
                    selected: _item.iconKey == null,
                    onTap: () {
                      _mutate(() => _item.iconKey = null);
                      widget.onCloseSection();
                    },
                  ),
                  for (final e in entries)
                    _iconTile(
                      icon: e.value.$1,
                      tooltip: e.value.$2,
                      selected: _item.iconKey == e.key,
                      onTap: () {
                        _mutate(() => _item.iconKey = e.key);
                        widget.onCloseSection();
                      },
                    ),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        'No icons match.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconTile({
    required IconData icon,
    required String tooltip,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF23272E),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected ? const Color(0xFF2CA3E8) : Colors.white12,
                width: selected ? 2 : 1,
              ),
            ),
            child: Icon(icon, size: 17, color: Colors.white70),
          ),
        ),
      );

  // ── Shape ────────────────────────────────────────────────────────────────

  Widget _shapeRow() => _FieldRow(
        label: 'Shape',
        child: Row(
          children: [
            _seg('Dot', !_item.isPill, () => _setShape(null)),
            const SizedBox(width: 6),
            _seg('Pill', _item.isPill, () => _setShape('pill')),
          ],
        ),
      );

  void _setShape(String? shape) {
    if ((_item.shape ?? 'dot') == (shape ?? 'dot')) return;
    _mutate(() => _item.shape = shape);
  }

  // ── Colors ───────────────────────────────────────────────────────────────

  Widget _accentRow() {
    final override = parseOverlayColorHex(_item.colorHex);
    return _FieldRow(
      label: 'Accent',
      child: Row(
        children: [
          _Swatch(
            color: override,
            placeholderIcon: Icons.block,
            selected: widget.section == _Section.accent,
            tooltip: override == null
                ? 'Accent follows the entity state color'
                : 'Custom accent color',
            onTap: () => widget.onToggleSection(_Section.accent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: override == null
                ? const Text(
                    'Auto: state color',
                    style: TextStyle(color: Colors.white38, fontSize: 11.5),
                  )
                : _ResetLink(
                    label: 'Auto: state color',
                    onTap: () => _mutate(() => _item.colorHex = null),
                  ),
          ),
        ],
      ),
    );
  }

  /// Two labelled swatches side by side — the badge's background when the
  /// entity reads OFF (the base value, also used for stale/indeterminate) and
  /// when it reads ON. Tapping either one ALSO flips the top bar's state
  /// preview to that state: the single most important interaction here, since
  /// it means the badge on the video behind the popover is always showing the
  /// exact color being edited.
  Widget _backgroundRow() {
    final off = parseOverlayColorHex(_item.bgColorHex);
    final on = parseOverlayColorHex(_item.bgColorOnHex);
    // Full width rather than a `_FieldRow` — two captioned swatches plus their
    // reset links do not fit in the 200-odd px a label column leaves.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            'Background',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        Row(
        children: [
          Expanded(
            child: _BgSwatchColumn(
              caption: 'Off',
              color: off ?? kBadgeDefaultBgPreview,
              inherited: false,
              selected: widget.section == _Section.bgOff,
              tooltip: off == null
                  ? 'Default dark background'
                  : 'Background while the entity is off',
              resetLabel: off == null ? null : 'Default dark',
              onReset: off == null
                  ? null
                  : () => _mutate(() => _item.bgColorHex = null),
              onTap: () {
                widget.host.previewState = false;
                widget.onToggleSection(_Section.bgOff);
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _BgSwatchColumn(
              caption: 'On',
              color: on ?? off ?? kBadgeDefaultBgPreview,
              // Unset "On" shows the inherited Off value plus a link glyph, so
              // it is obvious the badge doesn't change color when it turns on.
              inherited: on == null,
              selected: widget.section == _Section.bgOn,
              tooltip: on == null
                  ? 'Follows Off'
                  : 'Background while the entity is on',
              resetLabel: on == null ? null : 'Follow Off',
              onReset: on == null
                  ? null
                  : () => _mutate(() => _item.bgColorOnHex = null),
              onTap: () {
                widget.host.previewState = true;
                widget.onToggleSection(_Section.bgOn);
              },
            ),
          ),
        ],
        ),
      ],
    );
  }

  Widget _swatchStrip({
    required Color? current,
    required ValueChanged<Color> onPicked,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: ColorSwatchStrip(
          current: current,
          palette: kBadgeSwatchPalette,
          onPicked: onPicked,
        ),
      );

  // ── Size / opacity ───────────────────────────────────────────────────────

  Widget _sizeRow() => _FieldRow(
        label: 'Size',
        child: Row(
          children: [
            _SqButton('−', () => _editor.resizeSelected(1 / 1.15)),
            const SizedBox(width: 6),
            SizedBox(
              width: 52,
              height: 30,
              child: SuppressHotkeysWhileFocused(
                child: TextField(
                  controller: _sizeCtrl,
                  focusNode: _sizeFocus,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  ),
                  onSubmitted: (_) => _submitSize(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _SqButton('+', () => _editor.resizeSelected(1.15)),
          ],
        ),
      );

  Widget _opacityRow() => _FieldRow(
        label: 'Opacity',
        child: Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  min: 0.05,
                  max: 1.0,
                  value: _item.opacity.clamp(0.05, 1.0).toDouble(),
                  onChangeStart: (_) => _editor.pushUndo(),
                  onChanged: _editor.setSelectedOpacity,
                ),
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                '${(_item.opacity * 100).round()}%',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ],
        ),
      );

  // ── Footer ───────────────────────────────────────────────────────────────

  Widget _resetFooter() => Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: 'Icon, colors, shape, opacity, outline and pins back to '
              'defaults. Keeps the badge where it is, at its size, with its '
              'label.',
          child: TextButton.icon(
            onPressed: () => _mutate(_item.resetStyle),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.restart_alt, size: 15),
            label: const Text('Reset style', style: TextStyle(fontSize: 12)),
          ),
        ),
      );

  Widget _toggle(
    String label,
    String tooltip,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  value ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 17,
                  color: value ? const Color(0xFF4CC9FF) : Colors.white38,
                ),
                const SizedBox(width: 8),
                // Expanded + ellipsis: the popover is a fixed 300px, and these
                // captions are the longest strings in it. At a large text
                // scale (or once these strings are translated) a bare Text
                // overflows the row — the tooltip carries the full wording
                // either way.
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _seg(String label, bool active, VoidCallback onTap) => Expanded(
        child: SizedBox(
          height: 28,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              backgroundColor:
                  active ? const Color(0xFF2CA3E8) : const Color(0xFF2A2F36),
              foregroundColor: active ? Colors.white : Colors.white70,
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            child: Text(
              label,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
}

// ─── Multi-selection body: the geometry toolset ─────────────────────────────

/// What survived of the retired bottom `OverlayEditorBar` — the tools that
/// only make sense with several badges selected. Anchored to the PRIMARY
/// (REF) selection, which is also what match-size measures against.
class _MultiSelectBody extends StatelessWidget {
  const _MultiSelectBody({required this.host});

  final HaOverlayController host;

  @override
  Widget build(BuildContext context) {
    final c = host.editor;
    final n = c.selectedIds.length;
    final ref = c.selected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$n badges selected',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (ref is HaOverlayBadgeItem)
          Text(
            'Reference: ${ref.displayLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 10.5),
          ),
        const SizedBox(height: 4),
        const Text(
          'Style one badge at a time — select a single badge to change its '
          'icon or colors.',
          style: TextStyle(color: Colors.white38, fontSize: 10.5),
        ),
        const SizedBox(height: 10),
        const _SectionLabel('Align'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _icon(Icons.align_horizontal_left, 'Align left',
                () => c.alignSelected(OverlayAlign.left)),
            _icon(Icons.align_horizontal_center, 'Align horizontal centers',
                () => c.alignSelected(OverlayAlign.hCenter)),
            _icon(Icons.align_horizontal_right, 'Align right',
                () => c.alignSelected(OverlayAlign.right)),
            _icon(Icons.align_vertical_top, 'Align top',
                () => c.alignSelected(OverlayAlign.top)),
            _icon(Icons.align_vertical_center, 'Align vertical centers',
                () => c.alignSelected(OverlayAlign.vCenter)),
            _icon(Icons.align_vertical_bottom, 'Align bottom',
                () => c.alignSelected(OverlayAlign.bottom)),
            if (n >= 3) ...[
              _icon(Icons.horizontal_distribute, 'Distribute horizontally',
                  () => c.distributeSelected(horizontal: true)),
              _icon(Icons.vertical_distribute, 'Distribute vertically',
                  () => c.distributeSelected(horizontal: false)),
            ],
          ],
        ),
        const SizedBox(height: 12),
        const _SectionLabel('Size'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _text('Match size', 'Match every selected badge to the REF badge',
                () => c.matchSelectedSize(width: true, height: true)),
            _text('Smaller', null, () => c.resizeSelected(1 / 1.15)),
            _text('Bigger', null, () => c.resizeSelected(1.15)),
          ],
        ),
        const SizedBox(height: 10),
        _FieldRow(
          label: 'Opacity',
          child: Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    min: 0.05,
                    max: 1.0,
                    value: (ref?.opacity ?? 1.0).clamp(0.05, 1.0).toDouble(),
                    onChangeStart: (_) => c.pushUndo(),
                    onChanged: c.setSelectedOpacity,
                  ),
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  '${((ref?.opacity ?? 1.0) * 100).round()}%',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _text('Group', 'Move and resize these badges as one unit',
                c.groupSelected),
            if (c.selectionGrouped)
              _text('Ungroup', null, c.ungroupSelected),
          ],
        ),
        const Divider(color: Colors.white12, height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: c.removeSelected,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE5484D),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.delete_outline, size: 15),
            label: Text(
              'Remove $n badges',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _icon(IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 32,
          height: 30,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF2A2F36),
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            child: Icon(icon, size: 15),
          ),
        ),
      );

  Widget _text(String label, String? tooltip, VoidCallback onTap) {
    final btn = SizedBox(
      height: 30,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFF2A2F36),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: Size.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }
}

// ─── Small shared bits ──────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      );
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(child: child),
        ],
      );
}

class _PropButton extends StatelessWidget {
  const _PropButton({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 30,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF2A2F36),
            foregroundColor: Colors.white,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          child: child,
        ),
      );
}

class _SqButton extends StatelessWidget {
  const _SqButton(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 30,
        height: 30,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF2A2F36),
            foregroundColor: Colors.white,
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          child: Text(label, style: const TextStyle(fontSize: 14)),
        ),
      );
}

/// A round accent swatch. `color == null` renders the "no override" state.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    this.placeholderIcon,
  });

  final Color? color;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final IconData? placeholderIcon;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color ?? Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? const Color(0xFF2CA3E8) : Colors.white54,
                width: selected ? 2.4 : 1,
              ),
            ),
            child: color == null && placeholderIcon != null
                ? Icon(placeholderIcon, size: 13, color: Colors.white38)
                : null,
          ),
        ),
      );
}

/// One of the paired Off/On background swatches: caption, square swatch (with
/// a link glyph when it is inheriting), and a per-swatch reset shown only when
/// that swatch is actually overridden.
class _BgSwatchColumn extends StatelessWidget {
  const _BgSwatchColumn({
    required this.caption,
    required this.color,
    required this.inherited,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    required this.resetLabel,
    required this.onReset,
  });

  final String caption;
  final Color color;
  final bool inherited;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final String? resetLabel;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            caption,
            style: const TextStyle(color: Colors.white54, fontSize: 10.5),
          ),
          const SizedBox(height: 3),
          Tooltip(
            message: tooltip,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(5),
              child: Container(
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: selected ? const Color(0xFF2CA3E8) : Colors.white54,
                    width: selected ? 2.4 : 1,
                  ),
                ),
                alignment: Alignment.center,
                child: inherited
                    ? const Icon(Icons.link, size: 13, color: Colors.white54)
                    : null,
              ),
            ),
          ),
          if (resetLabel != null && onReset != null)
            _ResetLink(label: resetLabel!, onTap: onReset!),
        ],
      );
}

/// The per-field "put this back to its default" affordance. Shown ONLY when
/// the field is actually overridden — an always-visible reset on an unset
/// field reads as an available action that does nothing.
class _ResetLink extends StatelessWidget {
  const _ResetLink({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF4CC9FF),
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: const Icon(Icons.undo, size: 12),
          label: Text(label, style: const TextStyle(fontSize: 10.5)),
        ),
      );
}
