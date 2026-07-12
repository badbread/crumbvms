// The playback timeline — a SINGLE compact strip that is both the motion
// display and the scrub surface. It draws (top→bottom): a thin time ruler, the
// per-camera motion-intensity histogram + motion-start markers + Frigate
// detection glyphs, and a thin recording-coverage line at the very bottom (the
// "is there footage here" indicator, folded in from the old separate scrubber
// bar). It owns the pointer interaction too: drag = pan/scrub, click = seek,
// wheel = zoom, Shift+drag = export-range select — everything the removed
// bottom bar used to do.
//
// Data comes from a [MotionTimelineController] (intensity/detections); the
// window, playhead, recorded spans and export selection come from the shared
// [PlaybackTimelineController], which is also what the gestures mutate. Ported
// from the timeline canvas + pbInjectTimelineLegend + pbShowMotionHint in
// apps/desktop/src/app.js, merged with the pointer model of pbTimeline*.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../api/motion_timeline_api.dart';
import '../live_status/detection_icons.dart';
import '../playback/playback_timeline_controller.dart';
import 'camera_colors.dart';
import 'motion_timeline_controller.dart';

/// Cap the legend row's camera swatches so a large grid doesn't overflow the
/// single caption line. Ported from PB_LEGEND_CAM_MAX.
const int kLegendCameraMax = 8;

/// Horizontal drag distance (px) beyond which a press is a pan, not a click.
const double _panThresholdPx = 4;

/// Throttle for the in-drag live-seek callback: the seek fires continuously
/// AS the scrubber moves (leading + trailing edge), ~12/sec, so the video
/// tracks the drag in real time instead of only updating once it settles.
const Duration _liveSeekThrottle = Duration(milliseconds: 80);

class MotionTimelineView extends StatefulWidget {
  const MotionTimelineView({
    super.key,
    required this.motion,
    required this.timeline,
    required this.cameras,
    required this.selectedCameraName,
    this.onLiveSeek,
    this.onCommitSeek,
    this.onZoomChanged,
    this.height = 66,
  });

  /// Motion intensity + detection DATA (its window is kept in sync with
  /// [timeline] by the host so buckets are bucketed for the right span).
  final MotionTimelineController motion;

  /// The shared playback timeline: THE source of the visible window, playhead,
  /// recorded spans and export selection — and what the gestures drive.
  final PlaybackTimelineController timeline;

  /// Resolve camera ids → names for the legend/hover hint.
  final List<Camera> cameras;

  /// Name of the selected camera — drawn faintly at the bottom-left, and whose
  /// recorded spans are the coverage line.
  final String? selectedCameraName;

  /// Fired ~120ms after the last drag movement (cheap in-segment seek).
  final ValueChanged<DateTime>? onLiveSeek;

  /// Fired once the playhead is FINAL (drag release or click-seek): full
  /// cross-segment resolve.
  final ValueChanged<DateTime>? onCommitSeek;

  /// Fired after a wheel-zoom changes the window span.
  final VoidCallback? onZoomChanged;

  final double height;

  @override
  State<MotionTimelineView> createState() => _MotionTimelineViewState();
}

class _MotionTimelineViewState extends State<MotionTimelineView> {
  Offset? _hoverLocal;
  double _lastWidth = 0;
  double _width = 1;

  // ── pan/scrub state (ported from the old PlaybackTimeline) ────────────────
  bool _dragging = false;
  bool _isPan = false;
  double _panStartX = 0;
  DateTime? _panStartPlayhead;
  int? _panStartSpanMs;
  Timer? _liveSeekTimer;
  DateTime _lastLiveSeek = DateTime.fromMillisecondsSinceEpoch(0);

  // Shift+drag = export range selection (instead of pan).
  bool _selecting = false;
  int? _selAnchorMs;

  @override
  void dispose() {
    _liveSeekTimer?.cancel();
    super.dispose();
  }

  String _nameFor(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c.name;
    }
    return id.length > 6 ? id.substring(0, 6) : id;
  }

  DateTime _xToTime(double x) {
    final c = widget.timeline;
    final winStart = c.windowStart.millisecondsSinceEpoch;
    final winDur = c.windowEnd.millisecondsSinceEpoch - winStart;
    final ms = winStart + (x / _width) * winDur;
    return DateTime.fromMillisecondsSinceEpoch(ms.round(), isUtc: true);
  }

  int? _msAtX(double x) {
    final c = widget.timeline;
    final winStart = c.windowStart.millisecondsSinceEpoch;
    final winDur = c.windowEnd.millisecondsSinceEpoch - winStart;
    if (winDur <= 0 || _width <= 0) return null;
    return winStart + ((x / _width) * winDur).round();
  }

  // ── pointer handlers ──────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e) {
    _dragging = true;
    _isPan = false;
    if (HardwareKeyboard.instance.isShiftPressed) {
      _selecting = true;
      _selAnchorMs = _xToTime(e.localPosition.dx).millisecondsSinceEpoch;
      widget.timeline.setSelection(_selAnchorMs, _selAnchorMs);
      return;
    }
    _selecting = false;
    _panStartX = e.localPosition.dx;
    _panStartPlayhead = widget.timeline.playhead;
    _panStartSpanMs = widget.timeline.span.inMilliseconds;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_dragging) return;
    if (_selecting) {
      widget.timeline.setSelection(
        _selAnchorMs,
        _xToTime(e.localPosition.dx).millisecondsSinceEpoch,
      );
      return;
    }
    final dx = e.localPosition.dx - _panStartX;
    if (!_isPan && dx.abs() > _panThresholdPx) _isPan = true;
    if (!_isPan) return;

    final spanMs = _panStartSpanMs!;
    if (_width <= 0 || spanMs <= 0) return;
    final msPerPx = spanMs / _width;
    // Centered model: drag right scrolls BACK in time (content follows the
    // pointer), so a positive dx subtracts from the playhead.
    final deltaMs = (-dx * msPerPx).round();
    widget.timeline.setPlayhead(_panStartPlayhead!.add(Duration(milliseconds: deltaMs)));

    // Live scrub: push the seek to the panes AS the drag moves (throttled),
    // not just after it settles — leading edge fires now if enough time has
    // passed, otherwise a trailing timer catches the latest position.
    final now = DateTime.now();
    final since = now.difference(_lastLiveSeek);
    _liveSeekTimer?.cancel();
    if (since >= _liveSeekThrottle) {
      _lastLiveSeek = now;
      widget.onLiveSeek?.call(widget.timeline.playhead);
    } else {
      _liveSeekTimer = Timer(_liveSeekThrottle - since, () {
        _lastLiveSeek = DateTime.now();
        widget.onLiveSeek?.call(widget.timeline.playhead);
      });
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!_dragging) return;
    _dragging = false;
    if (_selecting) {
      _selecting = false;
      if (!widget.timeline.hasSelection) widget.timeline.clearSelection();
      return;
    }
    _liveSeekTimer?.cancel();
    _liveSeekTimer = null;
    if (_isPan) {
      widget.onCommitSeek?.call(widget.timeline.playhead);
    } else {
      final t = _xToTime(e.localPosition.dx);
      widget.timeline.setPlayhead(t);
      widget.onCommitSeek?.call(widget.timeline.playhead);
    }
    _isPan = false;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final direction = e.scrollDelta.dy > 0 ? 1 : -1;
      if (widget.timeline.zoomStep(direction)) widget.onZoomChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.motion, widget.timeline]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              _width = width;
              if (width > 0 && (width - _lastWidth).abs() > 1) {
                _lastWidth = width;
                SchedulerBinding.instance.addPostFrameCallback((_) {
                  widget.motion.configure(timelineWidthPx: width);
                });
              }
              return MouseRegion(
                cursor: _dragging && _isPan
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                onHover: (e) => setState(() => _hoverLocal = e.localPosition),
                onExit: (_) => setState(() => _hoverLocal = null),
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerSignal: _onPointerSignal,
                  child: SizedBox(
                    width: width,
                    height: widget.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _TimelinePainter(
                              motion: widget.motion,
                              timeline: widget.timeline,
                              selectedCameraName: widget.selectedCameraName,
                              hoverX: _hoverLocal?.dx,
                            ),
                          ),
                        ),
                        if (_hoverLocal != null)
                          _buildHoverOverlay(_hoverLocal!, width),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          // Legend under the scrubber (in the dead space below it), not above.
          const SizedBox(height: 2),
          _buildLegend(),
          if (widget.motion.error != null) _buildError(),
        ],
      ),
    );
  }

  /// Legend: the color→camera key for every camera with a loaded motion series,
  /// sorted by name — mirrors pbInjectTimelineLegend, capped at
  /// [kLegendCameraMax].
  Widget _buildLegend() {
    final entries = widget.motion.intensityByCam.entries
        .where((e) => e.value.buckets.isNotEmpty)
        .map((e) => MapEntry(e.key, _nameFor(e.key)))
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    if (entries.isEmpty) return const SizedBox.shrink();

    final shown = entries.take(kLegendCameraMax).toList();
    final extra = entries.length - shown.length;

    return Wrap(
      spacing: 10,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final e in shown)
          Tooltip(
            message: 'Motion band color for ${e.value}',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: cameraMotionColor(e.key),
                    shape: BoxShape.circle,
                  ),
                ),
                Text(e.value, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        if (extra > 0)
          Tooltip(
            message: entries.skip(shown.length).map((e) => e.value).join(', '),
            child: Text('+$extra', style: Theme.of(context).textTheme.labelSmall),
          ),
      ],
    );
  }

  /// Floating "which cameras had motion here" chip near the cursor, INSIDE the
  /// fixed-height strip so it never changes layout.
  Widget _buildHoverOverlay(Offset local, double width) {
    final ms = _msAtX(local.dx);
    if (ms == null) return const SizedBox.shrink();
    final camIds = widget.motion.camerasWithMotionAt(ms);
    if (camIds.isEmpty) return const SizedBox.shrink();
    const chipW = 150.0;
    final left = (local.dx - chipW / 2).clamp(
      0.0,
      (width - chipW).clamp(0.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 2,
            children: [
              for (final id in camIds)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: cameraMotionColor(id),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(
                      _nameFor(id),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(
      widget.motion.error!,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.orangeAccent),
    ),
  );
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.motion,
    required this.timeline,
    required this.selectedCameraName,
    this.hoverX,
  }) : super(repaint: Listenable.merge([motion, timeline]));

  final MotionTimelineController motion;
  final PlaybackTimelineController timeline;
  final String? selectedCameraName;
  final double? hoverX;

  // Layout bands (px).
  static const double rulerH = 13; // top time-label strip
  static const double covH = 3; // bottom recording-coverage line

  // Palette.
  static const Color bg = Color(0xFF14181F);
  static const Color grid = Color(0x1EFFFFFF);
  static const Color textColor = Color(0xB3E6EAF0);
  static const Color recColor = Color(0xCC7FA8C8); // recording-coverage line
  static const Color playheadColor = Color(0xFF4FA3FF);
  static const Color nowLine = Color(0xB378D278);
  static const Color futureDim = Color(0x73000000);
  static const Color laneLabel = Color(0x59FFFFFF);
  static const Color selColor = Color(0xFFE8A33D);

  @override
  void paint(Canvas canvas, Size size) {
    final winStart = timeline.windowStart.millisecondsSinceEpoch;
    final winEnd = timeline.windowEnd.millisecondsSinceEpoch;
    final winDur = winEnd - winStart;
    if (winDur <= 0 || size.width <= 0 || size.height <= 0) return;

    double msToX(int ms) => ((ms - winStart) / winDur) * size.width;

    final motionTop = rulerH + 1;
    final motionBottom = size.height - covH - 1; // above the coverage line

    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, rulerH),
      Paint()..color = const Color(0x0AFFFFFF),
    );

    // ── time ruler ──────────────────────────────────────────────────────────
    final gridIntervalMs = _pickGridInterval(winDur);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final firstGrid = (winStart / gridIntervalMs).ceil() * gridIntervalMs;
    for (var t = firstGrid; t <= winEnd; t += gridIntervalMs) {
      final x = msToX(t);
      canvas.drawLine(Offset(x, rulerH), Offset(x, motionBottom), gridPaint);
      _drawText(canvas, _fmtGridLabel(t, gridIntervalMs), Offset(x, 1),
          textColor, 9, anchor: _Anchor.centerTop, clampMinX: 2);
    }

    // ── future dim + now line ───────────────────────────────────────────────
    final nowX = msToX(DateTime.now().toUtc().millisecondsSinceEpoch);
    if (nowX < size.width) {
      final fx = nowX.clamp(0.0, size.width);
      canvas.drawRect(
        Rect.fromLTWH(fx, rulerH, size.width - fx, motionBottom - rulerH),
        Paint()..color = futureDim,
      );
      if (nowX >= 0) {
        canvas.drawLine(Offset(nowX, rulerH), Offset(nowX, motionBottom),
            Paint()..color = nowLine..strokeWidth = 1);
      }
    }

    // ── motion intensity (non-selected first, selected on top) ──────────────
    final selCamId = motion.selectedCameraId;
    final others = motion.intensityByCam.entries
        .where((e) => e.key != selCamId)
        .toList()
      ..sort((a, b) {
        final pa = a.value.buckets.isEmpty
            ? 0.0
            : a.value.buckets.reduce((x, y) => x > y ? x : y);
        final pb = b.value.buckets.isEmpty
            ? 0.0
            : b.value.buckets.reduce((x, y) => x > y ? x : y);
        return pa.compareTo(pb);
      });
    for (final e in others) {
      _drawIntensity(canvas, e.value, msToX, cameraMotionColor(e.key),
          motionTop, motionBottom, prominent: false);
    }
    final sel = motion.selectedIntensity;
    if (sel != null) {
      _drawIntensity(canvas, sel, msToX, cameraMotionColor(selCamId), motionTop,
          motionBottom, prominent: true);
      _drawMotionStarts(canvas, selCamId!, msToX, motionTop);
    }
    _drawDetectionGlyphs(canvas, msToX, selCamId, motionBottom);

    // ── recording-coverage line (bottom): where footage exists ──────────────
    final recPaint = Paint()..color = recColor;
    final covY = size.height - covH;
    for (final s in timeline.spans) {
      final x1 = msToX(s.startMs);
      final x2 = msToX(s.endMs);
      canvas.drawRect(
        Rect.fromLTWH(x1, covY, (x2 - x1).clamp(1.5, size.width), covH),
        recPaint,
      );
    }

    // Selected-camera name, faint, bottom-left over the coverage strip.
    _drawText(canvas, selectedCameraName ?? 'no camera selected',
        Offset(4, size.height - covH - 1), laneLabel, 9,
        anchor: _Anchor.leftBottom);

    // ── export-range selection (Shift+drag) ─────────────────────────────────
    final ss = timeline.selStartMs;
    final se = timeline.selEndMs;
    if (ss != null && se != null && se > ss) {
      final x1 = msToX(ss).clamp(0.0, size.width);
      final x2 = msToX(se).clamp(0.0, size.width);
      canvas.drawRect(Rect.fromLTRB(x1, rulerH, x2, motionBottom),
          Paint()..color = selColor.withValues(alpha: 0.18));
      final bp = Paint()..color = selColor..strokeWidth = 2;
      canvas.drawLine(Offset(x1, rulerH), Offset(x1, motionBottom), bp);
      canvas.drawLine(Offset(x2, rulerH), Offset(x2, motionBottom), bp);
    }

    // ── playhead line + timestamp chip ──────────────────────────────────────
    final phX = msToX(timeline.playhead.millisecondsSinceEpoch);
    canvas.drawLine(Offset(phX, rulerH - 2), Offset(phX, size.height),
        Paint()..color = playheadColor..strokeWidth = 1.5);
    final phLabel = _fmtTime(timeline.playhead.millisecondsSinceEpoch);
    final tp = _textPainter(phLabel, playheadColor, 10, bold: true);
    final lx = phX.clamp(tp.width / 2 + 3, size.width - tp.width / 2 - 3);
    canvas.drawRect(Rect.fromLTWH(lx - tp.width / 2 - 4, 0, tp.width + 8, 13),
        Paint()..color = const Color(0xD9080C14));
    tp.paint(canvas, Offset(lx - tp.width / 2, 1));

    // ── hover line ──────────────────────────────────────────────────────────
    if (hoverX != null) {
      canvas.drawLine(Offset(hoverX!, rulerH), Offset(hoverX!, size.height),
          Paint()..color = Colors.white.withValues(alpha: 0.25)..strokeWidth = 1);
    }
  }

  /// One camera's intensity buckets as a bar histogram between [top]..[bottom].
  void _drawIntensity(
    Canvas canvas,
    IntensityBuckets intensity,
    double Function(int) msToX,
    Color color,
    double top,
    double bottom, {
    required bool prominent,
  }) {
    final buckets = intensity.buckets;
    final n = buckets.length;
    if (n == 0) return;
    final span = (intensity.endMs - intensity.startMs) == 0
        ? 1
        : (intensity.endMs - intensity.startMs);
    final bucketMs =
        intensity.bucketMs > 0 ? intensity.bucketMs : (span / n).round();
    final paint = Paint()..color = color.withValues(alpha: prominent ? 0.95 : 0.35);
    final band = (bottom - top).clamp(1.0, double.infinity);
    final maxH = band * (prominent ? 0.95 : 0.6);
    for (var i = 0; i < n; i++) {
      final v = buckets[i].clamp(0.0, 1.0);
      if (v < kMotionAbsFloor) continue;
      final x1 = msToX(intensity.startMs + i * bucketMs);
      final x2 = msToX(intensity.startMs + (i + 1) * bucketMs);
      final w = (x2 - x1).abs().clamp(1.0, double.infinity);
      final h = maxH *
          (v < 0.02
              ? v / 0.02 * 0.3
              : 0.3 + 0.7 * ((v - 0.02) / (1 - 0.02)).clamp(0.0, 1.0));
      canvas.drawRect(Rect.fromLTWH(x1, bottom - h, w, h), paint);
    }
  }

  void _drawMotionStarts(
    Canvas canvas,
    String cameraId,
    double Function(int) msToX,
    double top,
  ) {
    final starts = motion.motionStartsFor(cameraId);
    if (starts.isEmpty) return;
    final paint = Paint()..color = Colors.white;
    const s = 4.0;
    for (final ms in starts) {
      final x = msToX(ms);
      final path = Path()
        ..moveTo(x - s, top)
        ..lineTo(x + s, top)
        ..lineTo(x, top + s)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  /// Frigate detection markers: the actual type icon on a dark disc + ring,
  /// just above the coverage line, collision-thinned.
  void _drawDetectionGlyphs(
    Canvas canvas,
    double Function(int) msToX,
    String? selCamId,
    double motionBottom,
  ) {
    if (motion.detections.isEmpty) return;
    final y = motionBottom - 8;
    double? lastX;
    for (final ev in motion.detections) {
      final ms = ev.ts.millisecondsSinceEpoch;
      if (ms < timeline.windowStart.millisecondsSinceEpoch ||
          ms > timeline.windowEnd.millisecondsSinceEpoch) {
        continue;
      }
      final x = msToX(ms);
      if (lastX != null && (x - lastX).abs() < 11) continue;
      lastX = x;
      final spec = detectionIconFor(ev.iconKey);
      final prominent = ev.cameraId == selCamId;
      final r = prominent ? 8.0 : 6.5;
      canvas.drawCircle(Offset(x, y), r, Paint()..color = const Color(0xE60A0E16));
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..color = spec.color.withValues(alpha: prominent ? 0.95 : 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final icon = spec.icon;
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: prominent ? 11 : 9,
            color: spec.color.withValues(alpha: prominent ? 1 : 0.75),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
    }
  }

  // ── text helpers ──────────────────────────────────────────────────────────

  TextPainter _textPainter(String text, Color color, double fontSize,
      {bool bold = false}) {
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

  void _drawText(Canvas canvas, String text, Offset pos, Color color,
      double fontSize, {required _Anchor anchor, double? clampMinX}) {
    final tp = _textPainter(text, color, fontSize);
    double dx;
    double dy;
    switch (anchor) {
      case _Anchor.centerTop:
        dx = pos.dx - tp.width / 2;
        dy = pos.dy;
        break;
      case _Anchor.leftBottom:
        dx = pos.dx;
        dy = pos.dy - tp.height;
        break;
    }
    if (clampMinX != null && dx < clampMinX) dx = clampMinX;
    tp.paint(canvas, Offset(dx, dy));
  }

  // ── formatting (ported from playback_timeline_painter) ─────────────────────

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
    return _isToday(epochMs) ? time : '${_pad2(d.month)}/${_pad2(d.day)} $time';
  }

  static String _fmtTime(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    final hh = _pad2(d.hour);
    final mm = _pad2(d.minute);
    final ss = _pad2(d.second);
    return _isToday(epochMs)
        ? '$hh:$mm:$ss'
        : '${_pad2(d.month)}/${_pad2(d.day)} $hh:$mm:$ss';
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) =>
      old.selectedCameraName != selectedCameraName || old.hoverX != hoverX;
}

enum _Anchor { centerTop, leftBottom }
