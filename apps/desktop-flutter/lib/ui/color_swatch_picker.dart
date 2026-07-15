// Shared swatch-grid color picker dialog — extracted from the playback
// timeline legend's private per-camera color picker
// (`motion_timeline/playback_legend_bar.dart`, which now calls this) so other
// surfaces (the HA badge editor's color override, issue #170 follow-up) reuse
// the exact same picker instead of growing a second one. Same behavior:
// a Wrap of circular swatches, the current color ringed white, colors already
// used elsewhere flagged (badge + tooltip) but still selectable, and an
// optional "reset to default" action.

import 'package:flutter/material.dart';

import 'motion_timeline/camera_colors.dart' show kCameraPickerPalette;

/// Outcome of [showColorSwatchPicker]: a picked color, or an explicit reset
/// (clear the override). A cancelled dialog returns null instead.
class ColorPickResult {
  const ColorPickResult.picked(Color this.color) : cleared = false;
  const ColorPickResult.cleared() : color = null, cleared = true;

  final Color? color;
  final bool cleared;
}

/// Show the swatch picker. `current` rings the currently-active color;
/// `usedBy` (ARGB32 -> names) flags swatches in use elsewhere; `allowReset`
/// adds the reset action (returns [ColorPickResult.cleared]). `palette`
/// defaults to the app-wide camera picker palette.
Future<ColorPickResult?> showColorSwatchPicker(
  BuildContext context, {
  required String title,
  Color? current,
  bool allowReset = false,
  String resetLabel = 'Reset to default',
  List<Color>? palette,
  Map<int, List<String>> usedBy = const {},
}) async {
  final colors = palette ?? kCameraPickerPalette;
  final chosen = await showDialog<Object?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 300,
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final color in colors)
              _ColorSwatch(
                color: color,
                current: current,
                usedByNames: usedBy[color.toARGB32()],
              ),
          ],
        ),
      ),
      actions: [
        if (allowReset)
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'reset'),
            child: Text(resetLabel),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (chosen == null) return null;
  if (chosen == 'reset') return const ColorPickResult.cleared();
  if (chosen is Color) return ColorPickResult.picked(chosen);
  return null;
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.current,
    required this.usedByNames,
  });

  final Color color;
  final Color? current;
  final List<String>? usedByNames;

  @override
  Widget build(BuildContext context) {
    final isCurrent = current != null && color == current;
    final used = usedByNames != null && usedByNames!.isNotEmpty;
    final swatch = InkWell(
      onTap: () => Navigator.pop(context, color),
      customBorder: const CircleBorder(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isCurrent ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: used
            ? Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, size: 9, color: Colors.white),
                ),
              )
            : null,
      ),
    );
    if (!used) return swatch;
    return Tooltip(
      message: 'In use by ${usedByNames!.join(', ')}',
      child: swatch,
    );
  }
}
