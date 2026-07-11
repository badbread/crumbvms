// On-video PTZ interaction: click-to-center, hold-to-pan, and (optionally)
// scroll-wheel optical zoom, driven directly off pointer events on the video
// widget itself (no native-pane event forwarding needed in Flutter — unlike
// the old Tauri client, media_kit's Video widget is a normal Flutter widget
// that receives pointer events directly).
//
// Ported from apps/desktop/src/app.js:
//   ptzNormOffset   (~4478) — normalized click offset from video center
//   ptzPulseMove    (~4504) — timed move-then-stop pulse (center-click mode)
//   ptzVideoSteer   (~4513) — continuous hold-to-pan steer
//   ptzVideoStopPan (~4525) — stop on release
//   ptzVideoClick   (~4537) — dispatch click by mode
//   ptzVideoWheel   (~4552) — debounced optical-zoom pulse on wheel
//
// PTZ is a continuous-velocity (ONVIF ContinuousMove) model with no
// position read-back, so "center on click" is an open-loop timed pulse, not
// a precise seek — this matches the old client's behavior exactly.
//
// Usage: wrap the `Video` widget (or stack this ON TOP of it) inside a
// `Stack`, sized to match the video pane. See ptz_click_mode.dart for the
// mode enum. This widget renders a translucent hint on top when a mode is
// active as the closest Flutter analog of the old client's ASS
// edge-chevron overlay (drawn as mpv OSD there; a widget layer here).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

import 'ptz_click_mode.dart';

class PtzInteractionOverlay extends StatefulWidget {
  const PtzInteractionOverlay({
    super.key,
    required this.api,
    required this.session,
    required this.cameraId,
    required this.mode,
    this.enableWheelZoom = true,
    this.showEdgeHint = true,
  });

  final CrumbApi api;
  final Session session;
  final String cameraId;

  /// Current click-interaction mode. Changing this mid-hold cancels any
  /// in-progress pan (matches `applyPtzClickMode`'s `ptzVideoStopPan()`).
  final PtzClickMode mode;

  /// Whether this overlay also drives wheel-zoom. Leave false if the host
  /// screen already wires wheel-zoom itself (e.g. wall_screen.dart's
  /// maximized pane already does `_ptzWheelZoom` via its own Listener) to
  /// avoid sending duplicate move/stop pairs.
  final bool enableWheelZoom;

  /// Draw a faint directional hint (arrows fading toward the edges) while a
  /// click mode is active, so the affordance is discoverable without docs.
  final bool showEdgeHint;

  @override
  State<PtzInteractionOverlay> createState() => _PtzInteractionOverlayState();
}

class _PtzInteractionOverlayState extends State<PtzInteractionOverlay> {
  Timer? _pulseStopTimer;
  Timer? _wheelStopTimer;
  bool _panActive = false;
  bool _hovering = false;

  static double _clamp(double v) => v.clamp(-1.0, 1.0);

  @override
  void didUpdateWidget(covariant PtzInteractionOverlay old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _stopPan(); // mode switch cancels an in-progress hold-to-pan
    }
  }

  @override
  void dispose() {
    _pulseStopTimer?.cancel();
    _wheelStopTimer?.cancel();
    super.dispose();
  }

  void _cmd({double pan = 0, double tilt = 0, double zoom = 0}) {
    widget.api
        .ptzMove(
          widget.session,
          widget.cameraId,
          pan: pan,
          tilt: tilt,
          zoom: zoom,
        )
        .catchError((_) {});
  }

  void _stopMotion() {
    widget.api.ptzStop(widget.session, widget.cameraId).catchError((_) {});
  }

  /// Normalized offset (-1..1, -1..1) of a local point from the pane center.
  ({double nx, double ny}) _normOffset(Offset local, Size size) {
    final nx = _clamp((local.dx - size.width / 2) / (size.width / 2));
    final ny = _clamp((local.dy - size.height / 2) / (size.height / 2));
    return (nx: nx, ny: ny);
  }

  /// Center mode: proportional recenter pulse, auto-stop after a duration
  /// scaled by how far off-center the click was (app.js `ptzPulseMove`).
  void _pulseMove(double pan, double tilt, int ms) {
    _pulseStopTimer?.cancel();
    _wheelStopTimer?.cancel();
    _cmd(pan: pan, tilt: tilt);
    _pulseStopTimer = Timer(Duration(milliseconds: ms), _stopMotion);
  }

  void _onTapUp(TapUpDetails d, Size size) {
    if (widget.mode != PtzClickMode.center) return;
    final o = _normOffset(d.localPosition, size);
    final mag = math.max(o.nx.abs(), o.ny.abs());
    if (mag < 0.06) return; // dead-center click → ignore
    _pulseMove(
      _clamp(o.nx * 0.7),
      _clamp(-o.ny * 0.7),
      (80 + 320 * mag).round(),
    );
  }

  void _steer(Offset local, Size size) {
    final o = _normOffset(local, size);
    _pulseStopTimer?.cancel();
    _wheelStopTimer?.cancel();
    _panActive = true;
    _cmd(pan: _clamp(o.nx), tilt: _clamp(-o.ny));
  }

  void _stopPan() {
    if (!_panActive) return;
    _panActive = false;
    _stopMotion();
  }

  void _wheelZoom(double scrollDy) {
    _pulseStopTimer?.cancel();
    _wheelStopTimer?.cancel();
    _cmd(zoom: scrollDy > 0 ? -0.5 : 0.5); // wheel up (negative dy) = zoom in
    _wheelStopTimer = Timer(const Duration(milliseconds: 260), _stopMotion);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == PtzClickMode.off) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        Widget area = GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (d) => _onTapUp(d, size),
          child: widget.mode == PtzClickMode.pan
              ? Listener(
                  onPointerDown: (e) => _steer(e.localPosition, size),
                  onPointerMove: (e) => _steer(e.localPosition, size),
                  onPointerUp: (_) => _stopPan(),
                  onPointerCancel: (_) => _stopPan(),
                  child: const SizedBox.expand(),
                )
              : const SizedBox.expand(),
        );
        if (widget.enableWheelZoom) {
          area = Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) _wheelZoom(e.scrollDelta.dy);
            },
            child: area,
          );
        }
        if (widget.showEdgeHint) {
          area = MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: Stack(
              fit: StackFit.expand,
              children: [
                area,
                if (_hovering)
                  IgnorePointer(
                    child: _EdgeHint(mode: widget.mode),
                  ),
              ],
            ),
          );
        }
        return area;
      },
    );
  }
}

/// Faint corner chevrons hinting at the active click mode — the widget
/// analog of the old client's mpv ASS edge-chevron overlay
/// (`ptzBuildEdgeAss`, app.js ~4707). Purely decorative/no-op for hit
/// testing (wrapped in `IgnorePointer` by the caller).
class _EdgeHint extends StatelessWidget {
  const _EdgeHint({required this.mode});
  final PtzClickMode mode;

  @override
  Widget build(BuildContext context) {
    final color = Colors.white.withValues(alpha: 0.35);
    final icon = mode == PtzClickMode.pan
        ? Icons.open_with
        : Icons.center_focus_strong;
    return Center(child: Icon(icon, color: color, size: 28));
  }
}
