// Per-badge style editor for a selected HA badge in the shared overlay
// editor bar (`OverlayEditorBar.selectedExtrasBuilder`): caption (label)
// editing, color override (the app's shared swatch picker,
// `ui/color_swatch_picker.dart`), a curated icon override
// (`ha_icons.dart`'s `kHaBadgeIconChoices`), and the pinned-caption toggles
// (live state text / relative age next to the badge on the wall).
//
// Everything edits the in-session `HaOverlayBadgeItem`; nothing persists here
// — `HaOverlayController.endEditAndSave` PUTs the whole placement (incl.
// style + a changed label) on Done, per the shared editor's storage contract.

import 'package:flutter/material.dart';

import '../color_swatch_picker.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import 'ha_icons.dart';
import 'ha_overlay_controller.dart' show HaOverlayBadgeItem;

/// Format a picked color back to the stored '#RRGGBB' form
/// (the inverse of `parseOverlayColorHex`).
String overlayColorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class HaBadgeStyleEditor extends StatefulWidget {
  const HaBadgeStyleEditor({
    super.key,
    required this.editor,
    required this.item,
  });

  /// The shared editor session — used only to re-notify structure after a
  /// style mutation so the badge chip repaints with its new color/icon.
  final OverlayEditorController editor;

  /// The primary selected badge (unwrapped by the caller from
  /// `OverlayEditorController.selected`).
  final HaOverlayBadgeItem item;

  @override
  State<HaBadgeStyleEditor> createState() => _HaBadgeStyleEditorState();
}

class _HaBadgeStyleEditorState extends State<HaBadgeStyleEditor> {
  final _labelCtrl = TextEditingController();
  String? _labelForId;

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickColor() async {
    final item = widget.item;
    final result = await showColorSwatchPicker(
      context,
      title: 'Badge color',
      current: parseOverlayColorHex(item.colorHex),
      allowReset: item.colorHex != null,
      resetLabel: 'Use state color',
    );
    if (result == null || !mounted) return;
    item.colorHex =
        result.cleared ? null : overlayColorToHex(result.color!);
    widget.editor.notifyItemsChanged();
  }

  Future<void> _pickIcon() async {
    final item = widget.item;
    final chosen = await showDialog<Object?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Badge icon'),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in kHaBadgeIconChoices.entries)
                Tooltip(
                  message: entry.value.$2,
                  child: InkWell(
                    onTap: () => Navigator.pop(ctx, entry.key),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: item.iconKey == entry.key
                              ? Theme.of(ctx).colorScheme.primary
                              : Colors.white24,
                          width: item.iconKey == entry.key ? 2 : 1,
                        ),
                      ),
                      child: Icon(entry.value.$1, size: 20),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          if (item.iconKey != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'reset'),
              child: const Text('Use default icon'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    item.iconKey = chosen == 'reset' ? null : chosen as String;
    widget.editor.notifyItemsChanged();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (_labelForId != item.id) {
      _labelForId = item.id;
      _labelCtrl.text = item.labelText ?? '';
    }
    final colorOverride = parseOverlayColorHex(item.colorHex);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        SizedBox(
          width: 140,
          height: 30,
          child: TextField(
            controller: _labelCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Label',
              hintStyle: TextStyle(color: Colors.white38),
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
            ),
            // In-session only; blank falls back to the entity id. Persisted
            // (as the link's label) on Done.
            onChanged: (v) => item.labelText = v,
          ),
        ),
        _StyleButton(
          tooltip: 'Badge color (overrides the state color)',
          onTap: _pickColor,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: colorOverride ?? Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white54),
                ),
                child: colorOverride == null
                    ? const Icon(Icons.block, size: 10, color: Colors.white38)
                    : null,
              ),
              const SizedBox(width: 5),
              const Text('Color', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        _StyleButton(
          tooltip: 'Badge icon (overrides the sensor-type icon)',
          onTap: _pickIcon,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                item.iconKey != null
                    ? (kHaBadgeIconChoices[item.iconKey!]?.$1 ?? Icons.sensors)
                    : Icons.emoji_objects_outlined,
                size: 14,
              ),
              const SizedBox(width: 5),
              const Text('Icon', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        _StyleToggle(
          label: 'Pin state',
          tooltip: 'Always show the live state ("Open"/"On") next to the badge',
          value: item.showState,
          onChanged: (v) {
            item.showState = v;
            widget.editor.notifyItemsChanged();
          },
        ),
        _StyleToggle(
          label: 'Pin time',
          tooltip: 'Always show the last-changed age ("2 m ago") next to the badge',
          value: item.showAge,
          onChanged: (v) {
            item.showAge = v;
            widget.editor.notifyItemsChanged();
          },
        ),
      ],
    );
  }
}

class _StyleButton extends StatelessWidget {
  const _StyleButton({
    required this.child,
    required this.onTap,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = SizedBox(
      height: 30,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFF2A2F36),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        child: child,
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

class _StyleToggle extends StatelessWidget {
  const _StyleToggle({
    required this.label,
    required this.value,
    required this.onChanged,
    this.tooltip,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = SizedBox(
      height: 30,
      child: TextButton.icon(
        onPressed: () => onChanged(!value),
        style: TextButton.styleFrom(
          backgroundColor:
              value ? const Color(0xFF2E4B5F) : const Color(0xFF2A2F36),
          foregroundColor: value ? const Color(0xFF4CC9FF) : Colors.white54,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        icon: Icon(
          value ? Icons.check_box : Icons.check_box_outline_blank,
          size: 13,
        ),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
