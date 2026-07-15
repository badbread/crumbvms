// Shared edit-mode bottom bar frame for the drag-to-place overlay editor —
// lifted from `ptz/ptz_panel_editor_bar.dart`'s Done/Clear/selected-props
// chrome and generalized: palette content (the PTZ "Add:" row, or the HA
// linked-entity picker, `ha_overlay/ha_entity_palette.dart`) is injected by
// the host as a plain widget slot; the Done/Clear buttons are host callbacks
// too — this bar never calls `OverlayEditorController.endEdit()`/`clearAll()`
// itself, because the controller never touches storage (see
// `overlay_editor_controller.dart`'s lifecycle contract) so a host must
// always be the one that persists on Done.
//
// Usage: place along the bottom of the maximized-tile screen that also hosts
// `OverlayEditorLayer`, while `controller.editMode == true` — same placement
// rule as `PtzPanelEditorBar`.

import 'package:flutter/material.dart';

import 'overlay_editor_controller.dart';
import 'overlay_item.dart';

class OverlayEditorBar extends StatelessWidget {
  const OverlayEditorBar({
    super.key,
    required this.controller,
    required this.paletteSlot,
    required this.onDone,
    this.onClear,
    this.clearLabel = 'Clear all',
    this.itemLabel,
  });

  final OverlayEditorController controller;

  /// Host-supplied palette content, laid out before the shared Clear/Done +
  /// selected-item controls (e.g. an "Add:" button row for PTZ, or
  /// `HaEntityPalette` for HA badges).
  final Widget paletteSlot;

  /// Called when the operator taps Done. The host should call
  /// `controller.endEdit()` itself here and persist the returned items —
  /// this bar deliberately does not call it directly (storage is entirely
  /// the host's responsibility).
  final VoidCallback onDone;

  /// Called when the operator taps [clearLabel] (the button is disabled
  /// while there are no items). Typically composes `controller.clearAll`
  /// with whatever the host also needs to do on a full clear (e.g. queue
  /// every removed placement to be cleared server-side on the next Done).
  final VoidCallback? onClear;

  final String clearLabel;

  /// Display text for the currently-selected item, shown next to the size
  /// stepper (e.g. its entity id / display label). Null hides the chip.
  final String Function(OverlayItem item)? itemLabel;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final selected = controller.selected;
        final hasItems = controller.items.isNotEmpty;
        return Material(
          color: Colors.black.withValues(alpha: 0.75),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                paletteSlot,
                const SizedBox(width: 12),
                _EdButton(
                  label: clearLabel,
                  danger: true,
                  onTap: hasItems ? onClear : null,
                ),
                _EdButton(label: 'Done', primary: true, onTap: onDone),
                if (selected != null) ...[
                  const _EdLabel('Selected:'),
                  if (itemLabel != null)
                    Text(
                      itemLabel!(selected),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  _EdButton(
                    label: '−',
                    onTap: () => controller.resizeSelected(1 / 1.15),
                  ),
                  const _EdLabel('size'),
                  _EdButton(
                    label: '+',
                    onTap: () => controller.resizeSelected(1.15),
                  ),
                  _EdButton(
                    label: 'Delete',
                    danger: true,
                    onTap: () => controller.removeItem(selected.id),
                  ),
                ],
              ],
            ),
          ),
        );
      },
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

class _EdButton extends StatelessWidget {
  const _EdButton({
    required this.label,
    required this.onTap,
    this.danger = false,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final bg = primary
        ? const Color(0xFF2CA3E8)
        : danger
        ? const Color(0xFF7A2020)
        : const Color(0xFF2A2F36);
    return SizedBox(
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
  }
}
