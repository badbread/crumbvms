// The motion timeline widget: per-camera intensity histogram, motion-start
// markers, a color legend, a hover tooltip listing which cameras had motion
// at the pointer's time, and prev/next-motion transport buttons. Ported from
// the timeline canvas + pbInjectTimelineLegend + pbShowMotionHint +
// pbPrevMotion/pbNextMotion in apps/desktop/src/app.js (the intensity-drawing
// parts of pbDrawTimeline — recorded-span base bars and live playhead/zoom
// chrome belong to the host playback screen, not this widget).
//
// This widget is presentation + local interaction only; it owns a
// [MotionTimelineController] for data and calls back to the host via
// [onSeek]/[onCameraSelected] for anything that affects shared playback
// state (the playhead, which camera is "selected" for playback).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../api/models.dart';
import '../../api/motion_timeline_api.dart';
import 'camera_colors.dart';
import 'motion_timeline_controller.dart';

/// Cap the legend row's camera swatches so a large grid doesn't overflow the
/// single caption line. Ported from PB_LEGEND_CAM_MAX.
const int kLegendCameraMax = 8;

class MotionTimelineView extends StatefulWidget {
  const MotionTimelineView({
    super.key,
    required this.controller,
    required this.cameras,
    required this.playheadMs,
    required this.onSeek,
    this.height = 96,
  });

  final MotionTimelineController controller;

  /// Used to resolve camera ids -> display names for the legend/hover hint.
  final List<Camera> cameras;

  /// Current playhead position, ms epoch — draws the playhead line and
  /// anchors prev/next-motion search.
  final int playheadMs;

  /// Called with a target ms epoch when the user clicks the ribbon or a
  /// prev/next-motion search lands somewhere.
  final ValueChanged<int> onSeek;

  final double height;

  @override
  State<MotionTimelineView> createState() => _MotionTimelineViewState();
}

class _MotionTimelineViewState extends State<MotionTimelineView> {
  Offset? _hoverLocal;
  double _lastWidth = 0;

  String _nameFor(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c.name;
    }
    return id.length > 6 ? id.substring(0, 6) : id;
  }

  int? _msAtX(double x, double width) {
    final c = widget.controller;
    final winDur = c.windowEndMs - c.windowStartMs;
    if (winDur <= 0 || width <= 0) return null;
    return c.windowStartMs + ((x / width) * winDur).round();
  }

  Future<void> _prevNext(bool next) async {
    final c = widget.controller;
    final camId = c.selectedCameraId;
    if (camId == null) return;
    final target = await c.jumpToMotion(
      cameraId: camId,
      fromMs: widget.playheadMs,
      next: next,
    );
    if (target != null) widget.onSeek(target);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildTransportRow(),
          const SizedBox(height: 4),
          _buildLegend(),
          const SizedBox(height: 2),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              if (width > 0 && (width - _lastWidth).abs() > 1) {
                _lastWidth = width;
                // Report the new pixel width so the controller can pick a
                // stable bucket size on the next refresh (see
                // intensityBucketMs). Deferred to avoid setState-during-build.
                SchedulerBinding.instance.addPostFrameCallback((_) {
                  widget.controller.configure(timelineWidthPx: width);
                });
              }
              return MouseRegion(
                onHover: (e) => setState(() => _hoverLocal = e.localPosition),
                onExit: (_) => setState(() => _hoverLocal = null),
                child: GestureDetector(
                  onTapUp: (d) {
                    final ms = _msAtX(d.localPosition.dx, width);
                    if (ms != null) widget.onSeek(ms);
                  },
                  child: SizedBox(
                    width: width,
                    height: widget.height,
                    child: CustomPaint(
                      painter: _MotionTimelinePainter(
                        controller: widget.controller,
                        playheadMs: widget.playheadMs,
                        hoverX: _hoverLocal?.dx,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (_hoverLocal != null) _buildHoverHint(_hoverLocal!, _lastWidth),
          if (widget.controller.error != null) _buildError(),
        ],
      ),
    );
  }

  Widget _buildTransportRow() {
    final selected = widget.controller.selectedCameraId;
    return Row(
      children: [
        Text(
          'Motion',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Previous motion',
          icon: const Icon(Icons.skip_previous, size: 18),
          onPressed: selected == null ? null : () => _prevNext(false),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          tooltip: 'Next motion',
          icon: const Icon(Icons.skip_next, size: 18),
          onPressed: selected == null ? null : () => _prevNext(true),
          visualDensity: VisualDensity.compact,
        ),
        if (widget.controller.loading)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  /// Legend: a "Recorded" swatch is the host's job (it owns the recording
  /// base bar); this widget's legend is the color->camera key for every
  /// camera with a loaded (non-empty) motion series, sorted by name — mirrors
  /// pbInjectTimelineLegend, capped at [kLegendCameraMax].
  Widget _buildLegend() {
    final entries = widget.controller.intensityByCam.entries
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

  Widget _buildHoverHint(Offset local, double width) {
    final ms = _msAtX(local.dx, width);
    if (ms == null) return const SizedBox.shrink();
    final camIds = widget.controller.camerasWithMotionAt(ms);
    if (camIds.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 8,
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
                Text(_nameFor(id), style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildError() => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(
      widget.controller.error!,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.orangeAccent),
    ),
  );
}

class _MotionTimelinePainter extends CustomPainter {
  _MotionTimelinePainter({
    required this.controller,
    required this.playheadMs,
    this.hoverX,
  });

  final MotionTimelineController controller;
  final int playheadMs;
  final double? hoverX;

  @override
  void paint(Canvas canvas, Size size) {
    final winStart = controller.windowStartMs;
    final winEnd = controller.windowEndMs;
    final winDur = winEnd - winStart;
    if (winDur <= 0 || size.width <= 0 || size.height <= 0) return;

    final bg = Paint()..color = const Color(0xFF14181F);
    canvas.drawRect(Offset.zero & size, bg);

    double msToX(int ms) => ((ms - winStart) / winDur) * size.width;

    final selCamId = controller.selectedCameraId;

    // Draw non-selected cameras first (weakest-peak-first so the loudest one
    // reads clearest on overlap), then the selected camera on top, full
    // opacity — mirrors the old client's z-order.
    final others = controller.intensityByCam.entries
        .where((e) => e.key != selCamId)
        .toList()
      ..sort((a, b) {
        final pa = a.value.buckets.isEmpty ? 0.0 : a.value.buckets.reduce((x, y) => x > y ? x : y);
        final pb = b.value.buckets.isEmpty ? 0.0 : b.value.buckets.reduce((x, y) => x > y ? x : y);
        return pa.compareTo(pb);
      });

    for (final e in others) {
      _drawIntensity(canvas, size, e.value, msToX, cameraMotionColor(e.key), prominent: false);
    }
    final sel = controller.selectedIntensity;
    if (sel != null) {
      _drawIntensity(canvas, size, sel, msToX, cameraMotionColor(selCamId), prominent: true);
      _drawMotionStarts(canvas, size, selCamId!, msToX);
    }

    _drawDetectionGlyphs(canvas, size, msToX, selCamId);

    // Playhead.
    if (playheadMs >= winStart && playheadMs <= winEnd) {
      final x = msToX(playheadMs);
      final p = Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }

    if (hoverX != null) {
      final p = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(hoverX!, 0), Offset(hoverX!, size.height), p);
    }
  }

  /// Draws one camera's intensity buckets as a bar histogram: bar height maps
  /// 0..1 to the track height, dimmed for non-selected cameras. Simplified
  /// from the old client's two-tone ribbon+cap rendering, but the same
  /// underlying value (buckets[i]) and per-camera color.
  void _drawIntensity(
    Canvas canvas,
    Size size,
    IntensityBuckets intensity,
    double Function(int) msToX,
    Color color, {
    required bool prominent,
  }) {
    final buckets = intensity.buckets;
    final n = buckets.length;
    if (n == 0) return;
    final span = (intensity.endMs - intensity.startMs) == 0 ? 1 : (intensity.endMs - intensity.startMs);
    final bucketMs = intensity.bucketMs > 0 ? intensity.bucketMs : (span / n).round();

    final paint = Paint()..color = color.withValues(alpha: prominent ? 0.95 : 0.35);
    final maxH = size.height * (prominent ? 0.9 : 0.55);

    for (var i = 0; i < n; i++) {
      final v = buckets[i].clamp(0.0, 1.0);
      if (v < kMotionAbsFloor) continue;
      final x1 = msToX(intensity.startMs + i * bucketMs);
      final x2 = msToX(intensity.startMs + (i + 1) * bucketMs);
      final w = (x2 - x1).abs().clamp(1.0, double.infinity);
      // sqrt-scale so modest motion is still visible, not squashed near zero.
      final h = maxH * (v < 0.02 ? v / 0.02 * 0.3 : 0.3 + 0.7 * ((v - 0.02) / (1 - 0.02)).clamp(0.0, 1.0));
      canvas.drawRect(
        Rect.fromLTWH(x1, size.height - h, w, h),
        paint,
      );
    }
  }

  /// Small upward triangle markers at each motion-run leading edge. Ported
  /// from pbSelectedMotionStarts's semantics (start of a coalesced run).
  void _drawMotionStarts(
    Canvas canvas,
    Size size,
    String cameraId,
    double Function(int) msToX,
  ) {
    final starts = controller.motionStartsFor(cameraId);
    if (starts.isEmpty) return;
    final paint = Paint()..color = Colors.white;
    const s = 4.0;
    for (final ms in starts) {
      final x = msToX(ms);
      if (x < -s || x > size.width + s) continue;
      final path = Path()
        ..moveTo(x - s, 2)
        ..lineTo(x + s, 2)
        ..lineTo(x, 2 + s)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  /// Object-detection glyphs (person/vehicle/etc.) as small dots at the
  /// bottom of the track, colored by their camera. Ported from the
  /// icon_key-filtered `pbState.detections` drawing.
  void _drawDetectionGlyphs(
    Canvas canvas,
    Size size,
    double Function(int) msToX,
    String? selCamId,
  ) {
    if (controller.detections.isEmpty) return;
    for (final ev in controller.detections) {
      final ms = ev.ts.millisecondsSinceEpoch;
      if (ms < controller.windowStartMs || ms > controller.windowEndMs) continue;
      final x = msToX(ms);
      final color = cameraMotionColor(ev.cameraId);
      final prominent = ev.cameraId == selCamId;
      final paint = Paint()..color = color.withValues(alpha: prominent ? 1 : 0.55);
      canvas.drawCircle(Offset(x, size.height - 3), prominent ? 3 : 2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MotionTimelinePainter old) {
    return old.controller != controller ||
        old.playheadMs != playheadMs ||
        old.hoverX != hoverX ||
        old.controller.intensityByCam.length != controller.intensityByCam.length;
  }
}
