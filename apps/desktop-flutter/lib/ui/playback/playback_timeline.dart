// Interactive canvas timeline widget — port of the pointer/wheel handling in
// apps/desktop/src/app.js: `pbTimelinePointerDown/Move/Up` (~9137-9260),
// `pbScheduleScrub` (120ms debounce, ~9298), `pbSchedulePanReload` (~9285),
// and `pbZoom`/`pbTimelineWheel` (~9329-9364).
//
// Interaction model (CENTERED, matching the old client exactly):
//   - Press + drag past a small threshold = PAN: the window scrolls under a
//     fixed center; the playhead follows and is redrawn continuously
//     (cheap, local — no network). While dragging, `onLiveSeek` fires
//     debounced (120ms of no movement) so panes do an in-segment keyframe
//     seek without a full /play/ resolve — the "live-seek scrub" in the
//     feature name. On release, `onCommitSeek` fires once for the final
//     position — the caller does the full cross-segment resolve there.
//   - Press + release with no meaningful movement = CLICK-TO-SEEK: jumps
//     the playhead (and recenters the window) to the clicked time, then
//     fires `onCommitSeek` immediately (mirrors `pbJumpTo`).
//   - Mouse wheel = ZOOM, stepping through the same duration ladder as the
//     old client, pivoting on the (always-centered) playhead. Fires
//     `onZoomChanged` so the caller reloads the timeline + re-resolves
//     panes for the new window (mirrors `pbSetZoomIndex`).

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'playback_timeline_controller.dart';
import 'playback_timeline_painter.dart';

/// Horizontal drag distance (px) beyond which a press is treated as a pan
/// rather than a click. Matches `PAN_THRESHOLD_PX` in app.js.
const double _panThresholdPx = 4;

/// Debounce for the cheap in-drag live-seek callback (matches
/// `pbScheduleScrub`'s 120ms).
const Duration _liveSeekDebounce = Duration(milliseconds: 120);

class PlaybackTimeline extends StatefulWidget {
  const PlaybackTimeline({
    super.key,
    required this.controller,
    this.selectedCameraName,
    this.onLiveSeek,
    this.onCommitSeek,
    this.onZoomChanged,
    this.height = 90,
  });

  final PlaybackTimelineController controller;
  final String? selectedCameraName;

  /// Fired ~120ms after the last drag movement, and NOT on click-to-seek or
  /// release — a cheap "keep the visible frame roughly tracking the scrub"
  /// hook. Callers should do an in-segment seek only (no /play/ HTTP call).
  final ValueChanged<DateTime>? onLiveSeek;

  /// Fired once the playhead position is FINAL: on release after a pan, or
  /// immediately on a click-to-seek. Callers should do the full
  /// cross-segment resolve here (equivalent to `pbResolveAllPanes`).
  final ValueChanged<DateTime>? onCommitSeek;

  /// Fired after a wheel-zoom changes the window span. Callers should
  /// reload timeline spans for the new window and re-resolve panes.
  final VoidCallback? onZoomChanged;

  final double height;

  @override
  State<PlaybackTimeline> createState() => _PlaybackTimelineState();
}

class _PlaybackTimelineState extends State<PlaybackTimeline> {
  bool _dragging = false;
  bool _isPan = false;
  double _panStartX = 0;
  DateTime? _panStartPlayhead;
  int? _panStartSpanMs;
  double _width = 1;
  Timer? _liveSeekTimer;

  // Shift+drag = export range selection (instead of pan).
  bool _selecting = false;
  int? _selAnchorMs;

  @override
  void dispose() {
    _liveSeekTimer?.cancel();
    super.dispose();
  }

  DateTime _xToTime(double x) {
    final c = widget.controller;
    final winStart = c.windowStart.millisecondsSinceEpoch;
    final winDur = c.windowEnd.millisecondsSinceEpoch - winStart;
    final ms = winStart + (x / _width) * winDur;
    return DateTime.fromMillisecondsSinceEpoch(ms.round(), isUtc: true);
  }

  void _onPointerDown(PointerDownEvent e) {
    _dragging = true;
    _isPan = false;
    // Shift+drag starts an export-range selection rather than a pan/seek.
    if (HardwareKeyboard.instance.isShiftPressed) {
      _selecting = true;
      _selAnchorMs = _xToTime(e.localPosition.dx).millisecondsSinceEpoch;
      widget.controller.setSelection(_selAnchorMs, _selAnchorMs);
      return;
    }
    _selecting = false;
    _panStartX = e.localPosition.dx;
    _panStartPlayhead = widget.controller.playhead;
    _panStartSpanMs = widget.controller.span.inMilliseconds;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_dragging) return;
    if (_selecting) {
      widget.controller.setSelection(
        _selAnchorMs,
        _xToTime(e.localPosition.dx).millisecondsSinceEpoch,
      );
      return;
    }
    final dx = e.localPosition.dx - _panStartX;
    if (!_isPan && dx.abs() > _panThresholdPx) {
      _isPan = true;
    }
    if (!_isPan) return;

    final spanMs = _panStartSpanMs!;
    if (_width <= 0 || spanMs <= 0) return;
    final msPerPx = spanMs / _width;
    // Centered model: dragging right scrolls BACK in time (content follows
    // the pointer), so a positive dx subtracts from the playhead.
    final deltaMs = (-dx * msPerPx).round();
    final next = _panStartPlayhead!.add(Duration(milliseconds: deltaMs));
    widget.controller.setPlayhead(next);

    _liveSeekTimer?.cancel();
    _liveSeekTimer = Timer(_liveSeekDebounce, () {
      widget.onLiveSeek?.call(widget.controller.playhead);
    });
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!_dragging) return;
    _dragging = false;
    if (_selecting) {
      _selecting = false;
      // A zero-width selection (plain shift-click) is not usable — clear it.
      if (!widget.controller.hasSelection) widget.controller.clearSelection();
      return;
    }
    _liveSeekTimer?.cancel();
    _liveSeekTimer = null;

    if (_isPan) {
      widget.onCommitSeek?.call(widget.controller.playhead);
    } else {
      final t = _xToTime(e.localPosition.dx);
      widget.controller.setPlayhead(t);
      widget.onCommitSeek?.call(widget.controller.playhead);
    }
    _isPan = false;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      // deltaY > 0 = scroll down = zoom out (wider window); < 0 = zoom in.
      final direction = e.scrollDelta.dy > 0 ? 1 : -1;
      final changed = widget.controller.zoomStep(direction);
      if (changed) widget.onZoomChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          return AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              return MouseRegion(
                cursor: _dragging && _isPan
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerSignal: _onPointerSignal,
                  child: CustomPaint(
                    size: Size(_width, widget.height),
                    painter: PlaybackTimelinePainter(
                      windowStart: widget.controller.windowStart,
                      windowEnd: widget.controller.windowEnd,
                      playhead: widget.controller.playhead,
                      spans: widget.controller.spans,
                      selectedCameraName: widget.selectedCameraName,
                      selStartMs: widget.controller.selStartMs,
                      selEndMs: widget.controller.selEndMs,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
