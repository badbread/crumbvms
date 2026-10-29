// Trim timeline for the Add/Edit clip dialog: a simplified scrubber over a
// window slightly wider than the clip, with the export selection highlighted
// between two draggable handles and a draggable playhead.
//
//  * Drag a handle to move that end of the selection; the dialog previews the
//    frame under it while dragging.
//  * Drag (or click) anywhere else to scrub the playhead.
//  * Mouse wheel zooms the window around the cursor, for frame-level trims on
//    a long clip.
//
// The widget only paints and reports gestures; the dialog owns all times and
// the video. Hit-testing is the pure [trimHitTest] so it can be unit-tested.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// What a pointer at a given x grabs.
enum TrimTarget { start, end, playhead }

/// Handle grab zone, in logical pixels either side of a selection edge.
const double kTrimHandleGrab = 12;

/// Width of the painted handle bars.
const double _handleW = 8;

/// Which target a press at [dx] grabs. Handles win within [kTrimHandleGrab]
/// of their edge (the nearer one if both are in reach, e.g. a very short
/// selection); everywhere else moves the playhead.
@visibleForTesting
TrimTarget trimHitTest({
  required double dx,
  required double startX,
  required double endX,
}) {
  final ds = (dx - startX).abs();
  final de = (dx - endX).abs();
  if (ds > kTrimHandleGrab && de > kTrimHandleGrab) return TrimTarget.playhead;
  if (ds == de) return dx < startX ? TrimTarget.start : TrimTarget.end;
  return ds < de ? TrimTarget.start : TrimTarget.end;
}

class ClipTrimTimeline extends StatefulWidget {
  const ClipTrimTimeline({
    super.key,
    required this.windowStart,
    required this.windowEnd,
    required this.selectionStart,
    required this.selectionEnd,
    required this.playhead,
    required this.coverage,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.onZoom,
    this.minSelection = const Duration(seconds: 1),
  });

  final DateTime windowStart;
  final DateTime windowEnd;
  final DateTime selectionStart;
  final DateTime selectionEnd;
  final DateTime playhead;

  /// Recorded spans inside the window, drawn along the bottom of the track.
  final List<(DateTime, DateTime)> coverage;

  final void Function(TrimTarget target) onDragStart;

  /// The dragged target moved to [t] (already clamped: handles keep at least
  /// [minSelection] apart, everything stays inside the window).
  final void Function(TrimTarget target, DateTime t) onDrag;
  final void Function(TrimTarget target, DateTime t) onDragEnd;

  /// Wheel zoom: the new window.
  final void Function(DateTime start, DateTime end) onZoom;

  final Duration minSelection;

  @override
  State<ClipTrimTimeline> createState() => _ClipTrimTimelineState();
}

class _ClipTrimTimelineState extends State<ClipTrimTimeline> {
  TrimTarget? _dragging;
  MouseCursor _cursor = SystemMouseCursors.click;

  int get _winMs =>
      widget.windowEnd.difference(widget.windowStart).inMilliseconds;

  double _x(DateTime t, double w) =>
      (t.difference(widget.windowStart).inMilliseconds / _winMs * w).clamp(
        0.0,
        w,
      );

  DateTime _t(double x, double w) => widget.windowStart.add(
    Duration(milliseconds: (x.clamp(0.0, w) / w * _winMs).round()),
  );

  DateTime _clampFor(TrimTarget target, DateTime t) {
    switch (target) {
      case TrimTarget.start:
        final max = widget.selectionEnd.subtract(widget.minSelection);
        return t.isAfter(max) ? max : t;
      case TrimTarget.end:
        final min = widget.selectionStart.add(widget.minSelection);
        return t.isBefore(min) ? min : t;
      case TrimTarget.playhead:
        return t;
    }
  }

  TrimTarget _hit(double dx, double w) => trimHitTest(
    dx: dx,
    startX: _x(widget.selectionStart, w),
    endX: _x(widget.selectionEnd, w),
  );

  void _begin(double dx, double w) {
    final target = _hit(dx, w);
    setState(() => _dragging = target);
    widget.onDragStart(target);
    // A press on the track jumps the playhead there immediately; a press on
    // a handle grabs it without moving it.
    if (target == TrimTarget.playhead) {
      widget.onDrag(target, _t(dx, w));
    }
  }

  void _update(double dx, double w) {
    final target = _dragging;
    if (target == null) return;
    widget.onDrag(target, _clampFor(target, _t(dx, w)));
  }

  void _end(double w) {
    final target = _dragging;
    if (target == null) return;
    setState(() => _dragging = null);
    final t = switch (target) {
      TrimTarget.start => widget.selectionStart,
      TrimTarget.end => widget.selectionEnd,
      TrimTarget.playhead => widget.playhead,
    };
    widget.onDragEnd(target, t);
  }

  void _zoom(PointerScrollEvent e, double w) {
    final anchor = _t(e.localPosition.dx, w);
    final factor = e.scrollDelta.dy > 0 ? 1.25 : 0.8;
    final newMs = (_winMs * factor)
        .clamp(5000, const Duration(hours: 12).inMilliseconds)
        .round();
    final anchorFrac = e.localPosition.dx.clamp(0.0, w) / w;
    final start = anchor.subtract(
      Duration(milliseconds: (newMs * anchorFrac).round()),
    );
    widget.onZoom(start, start.add(Duration(milliseconds: newMs)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        return MouseRegion(
          cursor: _dragging == null
              ? _cursor
              : (_dragging == TrimTarget.playhead
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.resizeLeftRight),
          onHover: (e) {
            final c = _hit(e.localPosition.dx, w) == TrimTarget.playhead
                ? SystemMouseCursors.click
                : SystemMouseCursors.resizeLeftRight;
            if (c != _cursor) setState(() => _cursor = c);
          },
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) _zoom(e, w);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) => _begin(d.localPosition.dx, w),
              onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, w),
              onHorizontalDragEnd: (_) => _end(w),
              onHorizontalDragCancel: () => _end(w),
              // A plain click scrubs too (no drag needed).
              onTapDown: (d) {
                if (_hit(d.localPosition.dx, w) != TrimTarget.playhead) return;
                _begin(d.localPosition.dx, w);
              },
              onTapUp: (_) => _end(w),
              child: SizedBox(
                height: 56,
                width: w,
                child: CustomPaint(
                  painter: _TrimPainter(
                    startX: _x(widget.selectionStart, w),
                    endX: _x(widget.selectionEnd, w),
                    playheadX: _x(widget.playhead, w),
                    coverage: [
                      for (final (s, e) in widget.coverage)
                        (_x(s, w), _x(e, w)),
                    ],
                    accent: theme.colorScheme.primary,
                    track: theme.colorScheme.surfaceContainerHighest,
                    activeHandle: _dragging,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrimPainter extends CustomPainter {
  _TrimPainter({
    required this.startX,
    required this.endX,
    required this.playheadX,
    required this.coverage,
    required this.accent,
    required this.track,
    required this.activeHandle,
  });

  final double startX;
  final double endX;
  final double playheadX;
  final List<(double, double)> coverage;
  final Color accent;
  final Color track;
  final TrimTarget? activeHandle;

  static const double _top = 10;
  static const double _bottom = 50;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(0, _top, w, _bottom),
      const Radius.circular(4),
    );
    canvas.drawRRect(trackRect, Paint()..color = track);

    // Recorded footage: a strip along the bottom of the track.
    final cov = Paint()..color = const Color(0xFF57C888).withValues(alpha: 0.7);
    for (final (a, b) in coverage) {
      if (b <= a) continue;
      canvas.drawRect(Rect.fromLTRB(a, _bottom - 6, b, _bottom), cov);
    }

    // Dim everything outside the selection.
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.45);
    canvas.drawRect(Rect.fromLTRB(0, _top, startX, _bottom), dim);
    canvas.drawRect(Rect.fromLTRB(endX, _top, w, _bottom), dim);

    // Selection: tinted fill + top/bottom borders.
    canvas.drawRect(
      Rect.fromLTRB(startX, _top, endX, _bottom),
      Paint()..color = accent.withValues(alpha: 0.14),
    );
    final edge = Paint()
      ..color = accent
      ..strokeWidth = 2;
    canvas.drawLine(Offset(startX, _top + 1), Offset(endX, _top + 1), edge);
    canvas.drawLine(
      Offset(startX, _bottom - 1),
      Offset(endX, _bottom - 1),
      edge,
    );

    // Handles: bars just outside each edge, with a grip.
    void handle(double x, bool left, bool active) {
      final r = RRect.fromRectAndCorners(
        left
            ? Rect.fromLTRB(x - _handleW, _top, x, _bottom)
            : Rect.fromLTRB(x, _top, x + _handleW, _bottom),
        topLeft: Radius.circular(left ? 4 : 0),
        bottomLeft: Radius.circular(left ? 4 : 0),
        topRight: Radius.circular(left ? 0 : 4),
        bottomRight: Radius.circular(left ? 0 : 4),
      );
      canvas.drawRRect(
        r,
        Paint()
          ..color = active ? Color.lerp(accent, Colors.white, 0.35)! : accent,
      );
      final cx = left ? x - _handleW / 2 : x + _handleW / 2;
      final grip = Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..strokeWidth = 1.2;
      const mid = (_top + _bottom) / 2;
      canvas.drawLine(
        Offset(cx - 1.5, mid - 6),
        Offset(cx - 1.5, mid + 6),
        grip,
      );
      canvas.drawLine(
        Offset(cx + 1.5, mid - 6),
        Offset(cx + 1.5, mid + 6),
        grip,
      );
    }

    handle(startX, true, activeHandle == TrimTarget.start);
    handle(endX, false, activeHandle == TrimTarget.end);

    // Playhead: a line through the track with a knob above it.
    final ph = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(playheadX, 4),
      Offset(playheadX, size.height - 2),
      ph,
    );
    final knob = Path()
      ..moveTo(playheadX - 6, 0)
      ..lineTo(playheadX + 6, 0)
      ..lineTo(playheadX, 8)
      ..close();
    canvas.drawPath(knob, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_TrimPainter old) =>
      old.startX != startX ||
      old.endX != endX ||
      old.playheadX != playheadX ||
      old.coverage != coverage ||
      old.accent != accent ||
      old.track != track ||
      old.activeHandle != activeHandle;
}
