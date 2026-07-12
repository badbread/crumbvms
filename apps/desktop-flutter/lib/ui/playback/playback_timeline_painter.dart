// CustomPainter port of `pbDrawTimeline` (apps/desktop/src/app.js ~8459) —
// the canvas playback timeline: background, grid/ruler with time labels, the
// selected camera's recording-coverage bar, a dimmed "future" region + live
// "now" line, the window-span/edge-time labels, and the playhead marker.
//
// Deliberately ported: layout bands (ruler height, bottom label strip),
// pbPickGridInterval's step table, and pbFmtGridLabel/pbFmtTime/pbFmtSpan's
// formatting rules (HH:MM[:SS], MM/DD prefix on non-today gridlines).
//
// Deliberately OUT of scope for this port (separate features / not part of
// playback-timeline-core): per-camera motion-intensity tracks, multi-camera
// activity overlay, Frigate detection glyphs, export-range brackets.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../api/playback_api.dart';

class PlaybackTimelinePainter extends CustomPainter {
  PlaybackTimelinePainter({
    required this.windowStart,
    required this.windowEnd,
    required this.playhead,
    required this.spans,
    required this.selectedCameraName,
    this.selStartMs,
    this.selEndMs,
    DateTime? now,
  }) : now = now ?? DateTime.now().toUtc();

  final DateTime windowStart;
  final DateTime windowEnd;
  final DateTime playhead;
  final List<RecordedSpan> spans;
  final String? selectedCameraName;
  final int? selStartMs; // export range selection (Shift+drag), or null
  final int? selEndMs;
  final DateTime now;

  static const Color selColor = Color(0xFFE8A33D); // amber brackets/band

  // ── layout bands (px) ───────────────────────────────────────────────────
  static const double labelH = 16; // top ruler / grid-label strip
  static const double bottomH = 16; // bottom span/edge-time label strip

  // ── palette (TL.* in app.js) ────────────────────────────────────────────
  static const Color trackBg = Color(0xFF0E1218);
  static const Color grid = Color(0x1EFFFFFF); // rgba(255,255,255,.12)
  static const Color textColor = Color(0xB3E6EAF0);
  static const Color recBase = Color(0xFF3A4A5A); // slate coverage bar
  static const Color playheadColor = Color(0xFF4FA3FF);
  static const Color laneLabel = Color(0x40FFFFFF);
  static const Color nowLine = Color(0xB378D278);
  static const Color futureDim = Color(0x73000000);

  double _msToX(int ms, double cw) {
    final winStart = windowStart.millisecondsSinceEpoch;
    final winDur =
        windowEnd.millisecondsSinceEpoch - winStart; // > 0, caller guards
    return ((ms - winStart) / winDur) * cw;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cw = size.width;
    final ch = size.height;
    final winStartMs = windowStart.millisecondsSinceEpoch;
    final winEndMs = windowEnd.millisecondsSinceEpoch;
    final winDur = winEndMs - winStartMs;
    if (cw < 2 || winDur <= 0) return;

    // ── 1. background ───────────────────────────────────────────────────
    canvas.drawRect(Offset.zero & size, Paint()..color = trackBg);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, cw, labelH),
      Paint()..color = const Color(0x0AFFFFFF),
    );

    final tBottom = ch - bottomH;

    // ── 2. grid lines + time labels ─────────────────────────────────────
    final gridIntervalMs = _pickGridInterval(winDur);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final firstGrid =
        ((winStartMs / gridIntervalMs).ceil()) * gridIntervalMs;
    for (var t = firstGrid; t <= winEndMs; t += gridIntervalMs) {
      final x = _msToX(t, cw);
      canvas.drawLine(Offset(x, labelH), Offset(x, tBottom), gridPaint);
      _drawText(
        canvas,
        _fmtGridLabel(t, gridIntervalMs),
        Offset(x, 2),
        textColor,
        10,
        anchor: _Anchor.centerTop,
        clampMinX: 2,
      );
    }

    // ── 3. selected-camera recording coverage bar ───────────────────────
    final tTop = labelH + 3;
    final tH = (tBottom - tTop).clamp(8.0, double.infinity);
    final baseH = (tH * 0.10).clamp(3.0, double.infinity);
    final barPaint = Paint()..color = recBase;
    for (final s in spans) {
      final x1 = _msToX(s.startMs, cw);
      final x2 = _msToX(s.endMs, cw);
      canvas.drawRect(
        Rect.fromLTWH(x1, tBottom - baseH, (x2 - x1).clamp(1.5, cw), baseH),
        barPaint,
      );
    }

    // ── 4. dim the future + "now" line ──────────────────────────────────
    final nowX = _msToX(now.millisecondsSinceEpoch, cw);
    if (nowX < cw) {
      final fx = nowX.clamp(0.0, cw);
      canvas.drawRect(
        Rect.fromLTWH(fx, labelH, cw - fx, ch - labelH - bottomH),
        Paint()..color = futureDim,
      );
      if (nowX >= 0) {
        canvas.drawLine(
          Offset(nowX, labelH),
          Offset(nowX, tBottom),
          Paint()
            ..color = nowLine
            ..strokeWidth = 1,
        );
      }
    }

    // ── 5. camera-name watermark ─────────────────────────────────────────
    _drawText(
      canvas,
      selectedCameraName ?? 'no camera selected',
      Offset(6, tTop + tH / 2),
      laneLabel,
      9,
      anchor: _Anchor.leftMiddle,
    );

    // ── 6. window-span label (center) + edge timestamps ─────────────────
    _drawText(
      canvas,
      _fmtSpan(winDur),
      Offset(cw / 2, ch - 2),
      textColor,
      10,
      anchor: _Anchor.centerBottom,
    );
    _drawText(
      canvas,
      _fmtTime(winStartMs),
      Offset(4, ch - 2),
      textColor,
      10,
      anchor: _Anchor.leftBottom,
    );
    _drawText(
      canvas,
      _fmtTime(winEndMs),
      Offset(cw - 4, ch - 2),
      textColor,
      10,
      anchor: _Anchor.rightBottom,
    );

    // ── 7. playhead ───────────────────────────────────────────────────────
    final phX = _msToX(playhead.millisecondsSinceEpoch, cw);
    canvas.drawLine(
      Offset(phX, labelH - 3),
      Offset(phX, tBottom),
      Paint()
        ..color = playheadColor
        ..strokeWidth = 1.5,
    );
    const tri = 6.0;
    final triPath = Path()
      ..moveTo(phX - tri, labelH - 6)
      ..lineTo(phX + tri, labelH - 6)
      ..lineTo(phX, labelH)
      ..close();
    canvas.drawPath(triPath, Paint()..color = playheadColor);

    // Floating timestamp chip at the playhead.
    final phLabel = _fmtTime(playhead.millisecondsSinceEpoch);
    final tp = _textPainter(phLabel, playheadColor, 10, bold: true);
    final lx = (phX).clamp(tp.width / 2 + 3, cw - tp.width / 2 - 3);
    canvas.drawRect(
      Rect.fromLTWH(lx - tp.width / 2 - 4, 0, tp.width + 8, 13),
      Paint()..color = const Color(0xD9080C14),
    );
    tp.paint(canvas, Offset(lx - tp.width / 2, 1));

    // ── export range selection (Shift+drag): band + brackets + duration ──
    final ss = selStartMs;
    final se = selEndMs;
    if (ss != null && se != null && se > ss) {
      final x1 = _msToX(ss, cw).clamp(0.0, cw);
      final x2 = _msToX(se, cw).clamp(0.0, cw);
      final top = labelH;
      final bot = ch - bottomH;
      canvas.drawRect(
        Rect.fromLTRB(x1, top, x2, bot),
        Paint()..color = selColor.withValues(alpha: 0.18),
      );
      final bp = Paint()
        ..color = selColor
        ..strokeWidth = 2;
      canvas.drawLine(Offset(x1, top), Offset(x1, bot), bp);
      canvas.drawLine(Offset(x2, top), Offset(x2, bot), bp);
      final dtp = _textPainter(_fmtDur(se - ss), Colors.white, 10, bold: true);
      final mid = ((x1 + x2) / 2).clamp(
        dtp.width / 2 + 3,
        cw - dtp.width / 2 - 3,
      );
      canvas.drawRect(
        Rect.fromLTWH(mid - dtp.width / 2 - 4, top + 2, dtp.width + 8, 14),
        Paint()..color = const Color(0xCC000000),
      );
      dtp.paint(canvas, Offset(mid - dtp.width / 2, top + 3));
    }
  }

  String _fmtDur(int ms) {
    final s = (ms / 1000).round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  @override
  bool shouldRepaint(covariant PlaybackTimelinePainter oldDelegate) {
    return oldDelegate.windowStart != windowStart ||
        oldDelegate.windowEnd != windowEnd ||
        oldDelegate.playhead != playhead ||
        oldDelegate.spans != spans ||
        oldDelegate.selectedCameraName != selectedCameraName ||
        oldDelegate.selStartMs != selStartMs ||
        oldDelegate.selEndMs != selEndMs ||
        oldDelegate.now != now;
  }

  // ── text helpers ─────────────────────────────────────────────────────────

  TextPainter _textPainter(
    String text,
    Color color,
    double fontSize, {
    bool bold = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontFeatures: const [ui.FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    return tp;
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset pos,
    Color color,
    double fontSize, {
    required _Anchor anchor,
    double? clampMinX,
  }) {
    final tp = _textPainter(text, color, fontSize);
    double dx;
    double dy;
    switch (anchor) {
      case _Anchor.centerTop:
        dx = pos.dx - tp.width / 2;
        dy = pos.dy;
        break;
      case _Anchor.leftMiddle:
        dx = pos.dx;
        dy = pos.dy - tp.height / 2;
        break;
      case _Anchor.centerBottom:
        dx = pos.dx - tp.width / 2;
        dy = pos.dy - tp.height;
        break;
      case _Anchor.leftBottom:
        dx = pos.dx;
        dy = pos.dy - tp.height;
        break;
      case _Anchor.rightBottom:
        dx = pos.dx - tp.width;
        dy = pos.dy - tp.height;
        break;
    }
    if (clampMinX != null && dx < clampMinX) dx = clampMinX;
    tp.paint(canvas, Offset(dx, dy));
  }

  // ── formatting (pbPickGridInterval / pbFmtGridLabel / pbFmtSpan / pbFmtTime) ─

  static int _pickGridInterval(int winDurMs) {
    const s = 1000;
    const mins = 60000;
    const hrs = 3600000;
    if (winDurMs <= 90 * s) return 10 * s;
    if (winDurMs <= 300 * s) return 30 * s;
    if (winDurMs <= 15 * mins) return 2 * mins;
    if (winDurMs <= 30 * mins) return 5 * mins;
    if (winDurMs <= 60 * mins) return 10 * mins;
    if (winDurMs <= 3 * hrs) return 30 * mins;
    if (winDurMs <= 6 * hrs) return hrs;
    if (winDurMs <= 24 * hrs) return 3 * hrs;
    return 6 * hrs;
  }

  static bool _isToday(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  static String _fmtGridLabel(int epochMs, int intervalMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    final hh = _pad2(d.hour);
    final mm = _pad2(d.minute);
    final ss = _pad2(d.second);
    String time;
    if (intervalMs >= 3600000) {
      time = '$hh:00';
    } else if (intervalMs >= 60000) {
      time = '$hh:$mm';
    } else {
      time = '$hh:$mm:$ss';
    }
    if (!_isToday(epochMs)) {
      return '${_pad2(d.month)}/${_pad2(d.day)} $time';
    }
    return time;
  }

  static String _fmtSpan(int durMs) {
    const s = 1000;
    const mins = 60000;
    const hrs = 3600000;
    if (durMs < 60 * s) return '${(durMs / s).round()}s';
    if (durMs < hrs) return '${(durMs / mins).round()}m';
    final h = durMs / hrs;
    return h == h.roundToDouble() ? '${h.round()}h' : '${h.toStringAsFixed(1)}h';
  }

  static String _fmtTime(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    final hh = _pad2(d.hour);
    final mm = _pad2(d.minute);
    final ss = _pad2(d.second);
    if (!_isToday(epochMs)) {
      return '${_pad2(d.month)}/${_pad2(d.day)} $hh:$mm:$ss';
    }
    return '$hh:$mm:$ss';
  }
}

enum _Anchor { centerTop, leftMiddle, centerBottom, leftBottom, rightBottom }
