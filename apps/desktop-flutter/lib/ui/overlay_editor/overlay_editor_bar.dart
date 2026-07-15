// Shared edit-mode bottom bar frame for the drag-to-place overlay editor.
// Palette content (the PTZ "Add:" row, or the HA linked-entity picker) is
// injected by the host as a plain widget slot; the Done/Clear buttons are
// host callbacks — this bar never calls
// `OverlayEditorController.endEdit()`/`clearAll()` itself, because the
// controller never touches storage (see `overlay_editor_controller.dart`'s
// lifecycle contract) so a host must always be the one that persists on Done.
//
// Selection tooling lives here (shared by both hosts): undo/redo, snap on/off
// toggle, numeric size field + stepper, opacity slider, match
// width/height/size to the last-clicked "reference" item, align + distribute,
// group/ungroup, delete-selected. Host-specific per-item properties (a PTZ
// button's rename/duplicate, an HA badge's label/color/icon/pins) are injected
// via [selectedExtrasBuilder]. A host that surfaces size/opacity in its own
// side panel (the HA badge editor, issue #9) turns them off here via
// [showSizeControls]/[showOpacityControl] to avoid duplication.
//
// This bar listens only to the controller's STRUCTURE notifications — drag
// ticks fire `controller.geometry`, which this bar deliberately does not
// subscribe to (see the controller's anti-stutter contract); the numeric size
// field re-syncs on the structure notify that ends each gesture.
//
// Usage: place along the bottom of the maximized-tile screen that also hosts
// `OverlayEditorLayer`, while `controller.editMode == true`.

import 'package:flutter/material.dart';

import 'overlay_editor_controller.dart';
import 'overlay_item.dart';

class OverlayEditorBar extends StatefulWidget {
  const OverlayEditorBar({
    super.key,
    required this.controller,
    required this.paletteSlot,
    required this.onDone,
    this.onClear,
    this.clearLabel = 'Clear all',
    this.itemLabel,
    this.selectedExtrasBuilder,
    this.showSizeControls = true,
    this.showOpacityControl = true,
    this.showHint = true,
  });

  final OverlayEditorController controller;

  /// Host-supplied palette content, laid out before the shared controls
  /// (e.g. an "Add:" button row for PTZ, or `HaEntityPalette` for HA badges).
  /// Pass `SizedBox.shrink()` when the host surfaces its palette elsewhere.
  final Widget paletteSlot;

  /// Called when the operator taps Done. The host should call
  /// `controller.endEdit()` itself here and persist the returned items —
  /// this bar deliberately does not call it directly (storage is entirely
  /// the host's responsibility).
  final VoidCallback onDone;

  /// Called when the operator taps [clearLabel] (the button is disabled
  /// while there are no items).
  final VoidCallback? onClear;

  final String clearLabel;

  /// Display text for the primary selected item, shown at the head of the
  /// selection row (e.g. its entity id / display label). Null hides the chip.
  final String Function(OverlayItem item)? itemLabel;

  /// Host-specific properties for the primary selected item (PTZ rename /
  /// duplicate / z-order), appended after the shared selection tools. Null
  /// adds nothing. (HA badges surface their style in a side panel — issue #9.)
  final Widget Function(OverlayItem item)? selectedExtrasBuilder;

  /// Show the numeric base-size field + ± stepper (off when a host renders
  /// size in its own panel — issue #9).
  final bool showSizeControls;

  /// Show the opacity slider (off when a host renders opacity in its own
  /// panel — issue #9).
  final bool showOpacityControl;

  /// Show the modifier-hint line (issue #6).
  final bool showHint;

  @override
  State<OverlayEditorBar> createState() => _OverlayEditorBarState();
}

class _OverlayEditorBarState extends State<OverlayEditorBar> {
  final _sizeCtrl = TextEditingController();
  final _sizeFocus = FocusNode();
  String? _sizeForId;

  @override
  void dispose() {
    _sizeCtrl.dispose();
    _sizeFocus.dispose();
    super.dispose();
  }

  void _submitSize(OverlayEditorController c) {
    final v = double.tryParse(_sizeCtrl.text.trim());
    if (v != null && v > 0) c.setSelectedBaseWidth(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final selected = c.selected;
        final selCount = c.selectedIds.length;
        final hasItems = c.items.isNotEmpty;

        // Keep the numeric size field in step with the primary selection
        // (unless the operator is typing in it) — same sync-on-build pattern
        // as the old PTZ bar's rename field.
        if (selected != null && widget.showSizeControls) {
          final txt = selected.baseSize().$1.round().toString();
          if (!_sizeFocus.hasFocus &&
              (_sizeForId != selected.id || _sizeCtrl.text != txt)) {
            _sizeForId = selected.id;
            _sizeCtrl.text = txt;
          }
        } else if (selected == null) {
          _sizeForId = null;
        }

        return Material(
          color: Colors.black.withValues(alpha: 0.75),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showHint)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4, left: 2),
                    child: Text(
                      'Shift/Ctrl-click to multi-select  ·  drag empty space to '
                      'box-select  ·  hold Alt to bypass snapping  ·  Ctrl+Z / '
                      'Ctrl+Y undo/redo',
                      style: TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                  ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    widget.paletteSlot,
                    const SizedBox(width: 12),
                    _EdIcon(
                      Icons.undo,
                      'Undo (Ctrl+Z)',
                      c.canUndo ? c.undo : null,
                    ),
                    _EdIcon(
                      Icons.redo,
                      'Redo (Ctrl+Y)',
                      c.canRedo ? c.redo : null,
                    ),
                    _EdToggle(
                      label: 'Snap',
                      value: c.snapEnabled,
                      tooltip: c.snapEnabled
                          ? 'Alignment snapping on (hold Alt to bypass while '
                              'dragging)'
                          : 'Alignment snapping off',
                      onTap: c.toggleSnap,
                    ),
                    _EdButton(
                      label: widget.clearLabel,
                      danger: true,
                      onTap: hasItems ? widget.onClear : null,
                    ),
                    _EdButton(
                      label: 'Done',
                      primary: true,
                      onTap: widget.onDone,
                    ),
                    if (selected != null) ...[
                      _EdLabel(
                        selCount > 1 ? 'Ref: ' : 'Selected: ',
                      ),
                      if (widget.itemLabel != null)
                        Tooltip(
                          message: selCount > 1
                              ? 'Match / properties target: the last-clicked '
                                  'item (marked "REF" on the canvas)'
                              : '',
                          child: Text(
                            widget.itemLabel!(selected),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (widget.showSizeControls) ...[
                        _EdButton(
                          label: '−',
                          onTap: () => c.resizeSelected(1 / 1.15),
                        ),
                        SizedBox(
                          width: 46,
                          height: 30,
                          child: TextField(
                            controller: _sizeCtrl,
                            focusNode: _sizeFocus,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 6,
                              ),
                            ),
                            onSubmitted: (_) => _submitSize(c),
                            onEditingComplete: () {
                              _submitSize(c);
                              _sizeFocus.unfocus();
                            },
                          ),
                        ),
                        _EdButton(
                          label: '+',
                          onTap: () => c.resizeSelected(1.15),
                        ),
                      ],
                      if (widget.showOpacityControl)
                        _OpacitySlider(controller: c, item: selected),
                      if (selCount >= 2) ...[
                        _EdButton(
                          label: 'Match W',
                          tooltip: 'Match width to the REF (last-clicked) item',
                          onTap: () =>
                              c.matchSelectedSize(width: true, height: false),
                        ),
                        _EdButton(
                          label: 'Match H',
                          tooltip: 'Match height to the REF (last-clicked) item',
                          onTap: () =>
                              c.matchSelectedSize(width: false, height: true),
                        ),
                        _EdButton(
                          label: 'Match size',
                          tooltip: 'Match size to the REF (last-clicked) item',
                          onTap: () =>
                              c.matchSelectedSize(width: true, height: true),
                        ),
                        _EdIcon(
                          Icons.align_horizontal_left,
                          'Align left',
                          () => c.alignSelected(OverlayAlign.left),
                        ),
                        _EdIcon(
                          Icons.align_horizontal_center,
                          'Align horizontal centers',
                          () => c.alignSelected(OverlayAlign.hCenter),
                        ),
                        _EdIcon(
                          Icons.align_horizontal_right,
                          'Align right',
                          () => c.alignSelected(OverlayAlign.right),
                        ),
                        _EdIcon(
                          Icons.align_vertical_top,
                          'Align top',
                          () => c.alignSelected(OverlayAlign.top),
                        ),
                        _EdIcon(
                          Icons.align_vertical_center,
                          'Align vertical centers',
                          () => c.alignSelected(OverlayAlign.vCenter),
                        ),
                        _EdIcon(
                          Icons.align_vertical_bottom,
                          'Align bottom',
                          () => c.alignSelected(OverlayAlign.bottom),
                        ),
                        if (selCount >= 3) ...[
                          _EdIcon(
                            Icons.horizontal_distribute,
                            'Distribute horizontally',
                            () => c.distributeSelected(horizontal: true),
                          ),
                          _EdIcon(
                            Icons.vertical_distribute,
                            'Distribute vertically',
                            () => c.distributeSelected(horizontal: false),
                          ),
                        ],
                        _EdButton(label: 'Group', onTap: c.groupSelected),
                      ],
                      if (c.selectionGrouped)
                        _EdButton(label: 'Ungroup', onTap: c.ungroupSelected),
                      if (widget.selectedExtrasBuilder != null)
                        widget.selectedExtrasBuilder!(selected),
                      _EdButton(
                        label: 'Delete',
                        danger: true,
                        onTap: c.removeSelected,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Selection opacity slider — one undo entry per drag (pushUndo on start),
/// then live `setSelectedOpacity` per tick.
class _OpacitySlider extends StatelessWidget {
  const _OpacitySlider({required this.controller, required this.item});

  final OverlayEditorController controller;
  final OverlayItem item;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Opacity',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.opacity, size: 14, color: Colors.white54),
          SizedBox(
            width: 90,
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
                value: item.opacity.clamp(0.05, 1.0).toDouble(),
                onChangeStart: (_) => controller.pushUndo(),
                onChanged: controller.setSelectedOpacity,
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '${(item.opacity * 100).round()}%',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _EdLabel extends StatelessWidget {
  const _EdLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12));
}

class _EdIcon extends StatelessWidget {
  const _EdIcon(this.icon, this.tooltip, this.onTap);
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 30,
        height: 30,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF2A2F36),
            disabledBackgroundColor:
                const Color(0xFF2A2F36).withValues(alpha: 0.35),
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white24,
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
  }
}

class _EdToggle extends StatelessWidget {
  const _EdToggle({
    required this.label,
    required this.value,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final bool value;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = SizedBox(
      height: 30,
      child: TextButton.icon(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor:
              value ? const Color(0xFF2E4B5F) : const Color(0xFF2A2F36),
          foregroundColor: value ? const Color(0xFF4CC9FF) : Colors.white54,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        icon: Icon(
          value ? Icons.grid_on : Icons.grid_off,
          size: 13,
        ),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

class _EdButton extends StatelessWidget {
  const _EdButton({
    required this.label,
    required this.onTap,
    this.danger = false,
    this.primary = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool primary;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final bg = primary
        ? const Color(0xFF2CA3E8)
        : danger
        ? const Color(0xFF7A2020)
        : const Color(0xFF2A2F36);
    final btn = SizedBox(
      height: 30,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: bg,
          disabledBackgroundColor: bg.withValues(alpha: 0.35),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: Size.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
