// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Digital zoom for a clip's video pane: mouse wheel zooms about the cursor,
// drag pans while zoomed, double-click (or the reset chip) returns to 1x.
//
// The behaviour and constants deliberately mirror the Clips tab player
// (`_applyZoom` / wheel handler in clips_screen.dart): 1.15x per wheel notch,
// a 30x ceiling, a centre-aligned transform, and a pan clamp so the image can
// never be dragged off-screen. The maths lives in pure functions so it is unit
// tested without a widget tree.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Digital-zoom ceiling. Same as the Clips tab, Playback, Android MAX_SCALE and
/// the iOS zoomable() default.
const double kClipZoomMax = 30.0;

/// Zoom factor of one wheel notch (Clips tab).
const double kClipZoomWheelStep = 1.15;

/// How long the zoom-level badge lingers after the last change.
const Duration kZoomBadgeHold = Duration(milliseconds: 1400);

/// Zoom state of a centre-aligned transform: translate by [offset], then scale
/// by [scale] about the pane centre.
class ZoomState {
  const ZoomState(this.scale, this.offset);

  static const ZoomState identity = ZoomState(1.0, Offset.zero);

  final double scale;
  final Offset offset;

  @override
  bool operator ==(Object other) =>
      other is ZoomState && other.scale == scale && other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, offset);

  @override
  String toString() => 'ZoomState($scale, $offset)';
}

/// Wheel direction to a zoom factor: scrolling up (negative dy) zooms in.
double wheelZoomFactor(double scrollDy) =>
    scrollDy < 0 ? kClipZoomWheelStep : 1 / kClipZoomWheelStep;

/// Clamps [scale] to 1..[max] and [offset] so the scaled image always covers
/// the pane (no empty border can be dragged into view).
ZoomState clampZoom(
  double scale,
  Offset offset,
  Size pane, {
  double max = kClipZoomMax,
}) {
  final s = scale.clamp(1.0, max);
  if (s == 1.0) return ZoomState.identity;
  final maxX = (s - 1) * pane.width / 2;
  final maxY = (s - 1) * pane.height / 2;
  return ZoomState(
    s,
    Offset(offset.dx.clamp(-maxX, maxX), offset.dy.clamp(-maxY, maxY)),
  );
}

/// One wheel step about [cursor] (pane-local). The image point under the
/// cursor stays under it; zooming back out to 1x snaps to identity.
ZoomState zoomAboutCursor(
  ZoomState from,
  double factor,
  Offset cursor,
  Size pane, {
  double max = kClipZoomMax,
}) {
  final ns = (from.scale * factor).clamp(1.0, max);
  if (ns == 1.0) return ZoomState.identity;
  final px = cursor.dx - pane.width / 2;
  final py = cursor.dy - pane.height / 2;
  final k = ns / from.scale;
  return clampZoom(
    ns,
    Offset(
      px - (px - from.offset.dx) * k,
      py - (py - from.offset.dy) * k,
    ),
    pane,
    max: max,
  );
}

/// Drag-pan by [delta]; a no-op at 1x.
ZoomState panZoom(ZoomState from, Offset delta, Size pane) {
  if (from.scale <= 1.0) return from;
  return clampZoom(from.scale, from.offset + delta, pane);
}

/// `1.0x` style label for the zoom badge.
String formatZoomLevel(double scale) => '${scale.toStringAsFixed(1)}x';

/// Wraps a video with wheel zoom, drag pan and double-click reset.
///
/// Wheel events are claimed through the pointer-signal resolver, so scrolling
/// over the video never scrolls an ancestor [Scrollable] (the profile's list).
/// Pan uses raw pointer moves rather than a drag recogniser so a vertical drag
/// at 1x still reaches the list behind it.
class ZoomableVideo extends StatefulWidget {
  const ZoomableVideo({super.key, required this.child});

  final Widget child;

  @override
  State<ZoomableVideo> createState() => _ZoomableVideoState();
}

class _ZoomableVideoState extends State<ZoomableVideo> {
  ZoomState _z = ZoomState.identity;
  Size _pane = Size.zero;
  bool _badge = false;
  Timer? _badgeTimer;

  @override
  void dispose() {
    _badgeTimer?.cancel();
    super.dispose();
  }

  void _set(ZoomState z) {
    setState(() {
      _z = z;
      _badge = true;
    });
    _badgeTimer?.cancel();
    _badgeTimer = Timer(kZoomBadgeHold, () {
      if (mounted) setState(() => _badge = false);
    });
  }

  void _reset() => _set(ZoomState.identity);

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    // Claim the event so the ListView behind the player does not scroll.
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      final se = ev as PointerScrollEvent;
      if (!mounted) return;
      _set(
        zoomAboutCursor(_z, wheelZoomFactor(se.scrollDelta.dy), se.localPosition, _pane),
      );
    });
  }

  void _onMove(PointerMoveEvent e) {
    if (_z.scale <= 1.0 || (e.buttons & kPrimaryButton) == 0) return;
    setState(() => _z = panZoom(_z, e.delta, _pane));
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, c) {
        _pane = Size(c.maxWidth, c.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              key: const ValueKey('zoom-listener'),
              onPointerSignal: _onSignal,
              onPointerMove: _onMove,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _reset,
                child: ClipRect(
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translateByDouble(_z.offset.dx, _z.offset.dy, 0, 1)
                      ..scaleByDouble(_z.scale, _z.scale, 1, 1),
                    child: widget.child,
                  ),
                ),
              ),
            ),
            if (_z.scale > 1.0)
              Positioned(
                top: 6,
                right: 6,
                child: Tooltip(
                  message: 'Reset zoom (double-click)',
                  child: InkWell(
                    key: const ValueKey('zoom-reset'),
                    onTap: _reset,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xCC101114),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: accent.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.zoom_out_map, size: 13, color: accent),
                          const SizedBox(width: 4),
                          Text(
                            _badge ? formatZoomLevel(_z.scale) : 'Reset',
                            key: const ValueKey('zoom-label'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
