// Small grid-diagram icons for the layout preset buttons. Ported from
// app.js's `layoutSvgIcon` (app.js:2129), which generated raw SVG markup for
// the same five patterns (1x1, 2x2, 1+5, 3x3, 4x4). Flutter has no built-in
// SVG renderer without an extra package, so this is a CustomPainter
// reproducing the same cell diagrams natively.

import 'package:flutter/material.dart';

class LayoutPresetIcon extends StatelessWidget {
  const LayoutPresetIcon({
    super.key,
    required this.layoutId,
    this.size = const Size(28, 21),
    this.color = Colors.white70,
    this.highlightColor = Colors.cyanAccent,
  });

  final String layoutId;
  final Size size;
  final Color color;
  final Color highlightColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: size,
      painter: _LayoutIconPainter(
        layoutId: layoutId,
        color: color,
        highlightColor: highlightColor,
      ),
    );
  }
}

class _LayoutIconPainter extends CustomPainter {
  _LayoutIconPainter({
    required this.layoutId,
    required this.color,
    required this.highlightColor,
  });

  final String layoutId;
  final Color color;
  final Color highlightColor;

  static const double _stroke = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    final w = size.width;
    final h = size.height;
    final p = _stroke / 2;

    void cell(double x, double y, double cw, double ch, {bool fill = false}) {
      final rect = Rect.fromLTWH(x, y, cw, ch);
      canvas.drawRect(rect, paint);
      if (fill) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = highlightColor.withValues(alpha: 0.18)
            ..style = PaintingStyle.fill,
        );
      }
    }

    switch (layoutId) {
      case '1x1':
        cell(p, p, w - _stroke, h - _stroke, fill: true);
        break;
      case '2x2':
        {
          final cw = (w - _stroke) / 2, ch = (h - _stroke) / 2;
          cell(p, p, cw - p, ch - p);
          cell(cw + p, p, cw - p, ch - p);
          cell(p, ch + p, cw - p, ch - p);
          cell(cw + p, ch + p, cw - p, ch - p);
        }
        break;
      case '3x3':
        {
          final cw = (w - _stroke) / 3, ch = (h - _stroke) / 3;
          for (var r = 0; r < 3; r++) {
            for (var c = 0; c < 3; c++) {
              cell(c * cw + p, r * ch + p, cw - _stroke, ch - _stroke);
            }
          }
        }
        break;
      case '1plus5':
        {
          final cw = (w - _stroke) / 3, ch = (h - _stroke) / 3;
          cell(p, p, 2 * cw - _stroke, 2 * ch - _stroke, fill: true);
          cell(2 * cw + p, p, cw - _stroke, ch - _stroke);
          cell(2 * cw + p, ch + p, cw - _stroke, ch - _stroke);
          cell(p, 2 * ch + p, cw - _stroke, ch - _stroke);
          cell(cw + p, 2 * ch + p, cw - _stroke, ch - _stroke);
          cell(2 * cw + p, 2 * ch + p, cw - _stroke, ch - _stroke);
        }
        break;
      case '4x4':
        {
          final cw = (w - _stroke) / 4, ch = (h - _stroke) / 4;
          for (var r = 0; r < 4; r++) {
            for (var c = 0; c < 4; c++) {
              cell(c * cw + p, r * ch + p, cw - _stroke, ch - _stroke);
            }
          }
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _LayoutIconPainter oldDelegate) =>
      oldDelegate.layoutId != layoutId ||
      oldDelegate.color != color ||
      oldDelegate.highlightColor != highlightColor;
}
