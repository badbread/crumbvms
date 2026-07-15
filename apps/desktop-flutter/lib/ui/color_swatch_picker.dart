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
/// adds the reset action (returns [ColorPickResult.cleared]). `allowCustom`
/// adds a "Custom…" action (hex field + RGB sliders) so the operator isn't
/// limited to the preset swatches (issue #10). `palette` defaults to the
/// app-wide camera picker palette.
Future<ColorPickResult?> showColorSwatchPicker(
  BuildContext context, {
  required String title,
  Color? current,
  bool allowReset = false,
  bool allowCustom = false,
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
            if (allowCustom)
              _CustomSwatch(
                onTap: () async {
                  final custom =
                      await showCustomColorDialog(ctx, initial: current);
                  if (custom != null && ctx.mounted) {
                    Navigator.pop(ctx, custom);
                  }
                },
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

/// A free-form color dialog: R/G/B sliders + a `#RRGGBB` hex field with a live
/// preview, kept in sync both ways. Returns the picked color, or null on
/// cancel. Public so other surfaces can reach it directly if needed.
Future<Color?> showCustomColorDialog(
  BuildContext context, {
  Color? initial,
}) {
  return showDialog<Color>(
    context: context,
    builder: (ctx) => _CustomColorDialog(initial: initial ?? const Color(0xFF4C9AFF)),
  );
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

/// The "Custom…" tile in the swatch grid — a rainbow-ringed "+" that opens the
/// free-form color dialog.
class _CustomSwatch extends StatelessWidget {
  const _CustomSwatch({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Custom colour…',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              colors: [
                Color(0xFFFF0000),
                Color(0xFFFFFF00),
                Color(0xFF00FF00),
                Color(0xFF00FFFF),
                Color(0xFF0000FF),
                Color(0xFFFF00FF),
                Color(0xFFFF0000),
              ],
            ),
          ),
          child: const Icon(Icons.add, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}

class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog({required this.initial});
  final Color initial;

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late int _r = (widget.initial.r * 255).round();
  late int _g = (widget.initial.g * 255).round();
  late int _b = (widget.initial.b * 255).round();
  late final TextEditingController _hexCtrl;

  Color get _color => Color.fromARGB(255, _r, _g, _b);

  String get _hex =>
      '#${_r.toRadixString(16).padLeft(2, '0')}${_g.toRadixString(16).padLeft(2, '0')}${_b.toRadixString(16).padLeft(2, '0')}'
          .toUpperCase();

  @override
  void initState() {
    super.initState();
    _hexCtrl = TextEditingController(text: _hex);
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  void _applyHex(String v) {
    var s = v.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length != 6) return;
    final n = int.tryParse(s, radix: 16);
    if (n == null) return;
    setState(() {
      _r = (n >> 16) & 0xFF;
      _g = (n >> 8) & 0xFF;
      _b = n & 0xFF;
    });
  }

  void _syncHexField() {
    final want = _hex;
    if (_hexCtrl.text.toUpperCase() != want) _hexCtrl.text = want;
  }

  @override
  Widget build(BuildContext context) {
    _syncHexField();
    return AlertDialog(
      title: const Text('Custom colour'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(height: 12),
            _channel('R', _r, const Color(0xFFE05353),
                (v) => setState(() => _r = v)),
            _channel('G', _g, const Color(0xFF53E070),
                (v) => setState(() => _g = v)),
            _channel('B', _b, const Color(0xFF5390E0),
                (v) => setState(() => _b = v)),
            const SizedBox(height: 6),
            Row(
              children: [
                const Text('Hex '),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _hexCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    onChanged: _applyHex,
                    onSubmitted: _applyHex,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _color),
          child: const Text('Use colour'),
        ),
      ],
    );
  }

  Widget _channel(
    String label,
    int value,
    Color accent,
    ValueChanged<int> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accent,
              thumbColor: accent,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              min: 0,
              max: 255,
              value: value.toDouble(),
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
        SizedBox(width: 30, child: Text('$value')),
      ],
    );
  }
}
