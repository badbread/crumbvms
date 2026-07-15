// The HA badge editor's right-side vertical panel (issue #170 follow-up,
// readability #9): the camera's linked-entity palette on top and — when a
// badge is selected — a grouped, vertically-laid-out style form (size,
// opacity, label, color, icon, pinned captions) below. Replaces the old
// cramped single-row `selectedExtrasBuilder` in the bottom bar; the bottom bar
// keeps only the generic multi-select geometry ops (align/group/match/undo).
//
// Everything edits the in-session `HaOverlayBadgeItem` (and, for size/opacity,
// the shared controller's selection ops); nothing persists here —
// `HaOverlayController.endEditAndSave` PUTs the whole placement (incl. style,
// opacity + a changed label) on Done, per the shared editor's storage
// contract. Each discrete style change snapshots undo first (`pushUndo`), so
// Ctrl+Z reverts colors/icons/pins/labels just like geometry ops.

import 'package:flutter/material.dart';

import '../color_swatch_picker.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import 'ha_entity_palette.dart';
import 'ha_icons.dart';
import 'ha_overlay_controller.dart' show HaOverlayBadgeItem, HaOverlayController;

/// Format a picked color back to the stored '#RRGGBB' form
/// (the inverse of `parseOverlayColorHex`).
String overlayColorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The full right-side HA editing panel: palette (top) + selected-badge style
/// form (bottom). Rendered by the maximized pane while an HA overlay edit
/// session is active.
class HaOverlayEditPanel extends StatelessWidget {
  const HaOverlayEditPanel({super.key, required this.host});

  final HaOverlayController host;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(10),
      // Rebuild on editor structure changes (selection, add/remove) so the
      // palette checkmarks + which style form shows stay live.
      child: AnimatedBuilder(
        animation: host.editor,
        builder: (context, _) {
          final selected = host.editor.selected;
          final badge = selected is HaOverlayBadgeItem ? selected : null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Entities',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 6),
              HaEntityPalette(
                links: host.links,
                placedIds: host.placedIdsInSession,
                onPick: host.pickFromPalette,
              ),
              if (badge != null) ...[
                const Divider(color: Colors.white12, height: 18),
                Flexible(
                  child: SingleChildScrollView(
                    child: HaBadgeStyleForm(
                      key: ValueKey(badge.id),
                      editor: host.editor,
                      item: badge,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The grouped, vertical style form for one selected badge.
class HaBadgeStyleForm extends StatefulWidget {
  const HaBadgeStyleForm({
    super.key,
    required this.editor,
    required this.item,
  });

  final OverlayEditorController editor;
  final HaOverlayBadgeItem item;

  @override
  State<HaBadgeStyleForm> createState() => _HaBadgeStyleFormState();
}

class _HaBadgeStyleFormState extends State<HaBadgeStyleForm> {
  final _labelCtrl = TextEditingController();
  final _labelFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _labelCtrl.text = widget.item.labelText ?? '';
    // Snapshot undo once when the label field first gains focus, so a whole
    // typing session collapses to a single undo step (not one per keystroke).
    _labelFocus.addListener(() {
      if (_labelFocus.hasFocus) widget.editor.pushUndo();
    });
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _labelFocus.dispose();
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
      allowCustom: true,
    );
    if (result == null || !mounted) return;
    widget.editor.pushUndo();
    item.colorHex = result.cleared ? null : overlayColorToHex(result.color!);
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
    widget.editor.pushUndo();
    item.iconKey = chosen == 'reset' ? null : chosen as String;
    widget.editor.notifyItemsChanged();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // Keep the label field in step if the item changed underneath us (e.g.
    // undo/redo) while it isn't being typed into.
    final want = item.labelText ?? '';
    if (!_labelFocus.hasFocus && _labelCtrl.text != want) {
      _labelCtrl.text = want;
    }
    final colorOverride = parseOverlayColorHex(item.colorHex);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel('Badge'),
        const SizedBox(height: 6),
        _row(
          'Label',
          SizedBox(
            height: 32,
            child: TextField(
              controller: _labelCtrl,
              focusNode: _labelFocus,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Entity name',
                hintStyle: TextStyle(color: Colors.white38),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              onChanged: (v) => item.labelText = v,
            ),
          ),
        ),
        _row(
          'Size',
          Row(
            children: [
              _sq('−', () => widget.editor.resizeSelected(1 / 1.15)),
              const SizedBox(width: 6),
              _sq('+', () => widget.editor.resizeSelected(1.15)),
            ],
          ),
        ),
        _row(
          'Opacity',
          Row(
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
                    value: item.opacity.clamp(0.05, 1.0).toDouble(),
                    onChangeStart: (_) => widget.editor.pushUndo(),
                    onChanged: widget.editor.setSelectedOpacity,
                  ),
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  '${(item.opacity * 100).round()}%',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        _row(
          'Color',
          _propButton(
            onTap: _pickColor,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: colorOverride ?? Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white54),
                  ),
                  child: colorOverride == null
                      ? const Icon(Icons.block, size: 11, color: Colors.white38)
                      : null,
                ),
                const SizedBox(width: 6),
                Text(
                  colorOverride == null ? 'State color' : 'Custom',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        _row(
          'Icon',
          _propButton(
            onTap: _pickIcon,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.iconKey != null
                      ? (kHaBadgeIconChoices[item.iconKey!]?.$1 ??
                          Icons.sensors)
                      : Icons.emoji_objects_outlined,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  item.iconKey != null
                      ? (kHaBadgeIconChoices[item.iconKey!]?.$2 ?? item.iconKey!)
                      : 'Default',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        _checkRow(
          'Pin state text',
          'Always show the live state ("Open"/"On") next to the badge',
          item.showState,
          (v) {
            widget.editor.pushUndo();
            item.showState = v;
            widget.editor.notifyItemsChanged();
          },
        ),
        _checkRow(
          'Pin last-changed time',
          'Always show the age ("2 m ago") next to the badge',
          item.showAge,
          (v) {
            widget.editor.pushUndo();
            item.showAge = v;
            widget.editor.notifyItemsChanged();
          },
        ),
      ],
    );
  }

  Widget _row(String label, Widget field) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 56,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            Expanded(child: field),
          ],
        ),
      );

  Widget _checkRow(
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
                  size: 18,
                  color: value ? const Color(0xFF4CC9FF) : Colors.white38,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _propButton({required Widget child, required VoidCallback onTap}) =>
      SizedBox(
        height: 32,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF2A2F36),
            foregroundColor: Colors.white,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          ),
          child: child,
        ),
      );

  Widget _sq(String label, VoidCallback onTap) => SizedBox(
        width: 32,
        height: 30,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xFF2A2F36),
            foregroundColor: Colors.white,
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          ),
          child: Text(label, style: const TextStyle(fontSize: 14)),
        ),
      );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      );
}
