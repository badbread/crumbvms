// Renders a camera's custom PTZ panel over the video pane, as real Flutter
// widgets (per the port brief) instead of app.js's mpv-ASS drawing
// (`ptzBuildCustomAss`) + physical-px hit-testing (`ptzCustomHit`). Handles
// both view mode (press-and-hold direction/zoom, tap home/preset/imaging)
// and edit mode (select / drag-with-snap / resize / delete).
//
// Usage: stack this INSIDE the same-sized Positioned.fill video pane that
// hosts the Video widget, above it in z-order:
//
//   Stack(children: [
//     Video(controller: videoController),
//     if (controller.activePanelFor(camera.id) != null)
//       Positioned.fill(child: PtzPanelOverlay(controller: controller, cameraId: camera.id)),
//   ])

import 'package:flutter/material.dart';

import '../../api/ptz_extras_api.dart';
import '../../api/ptz_panel_models.dart';
import 'ptz_panel_controller.dart';

class PtzPanelOverlay extends StatelessWidget {
  const PtzPanelOverlay({
    super.key,
    required this.controller,
    required this.cameraId,
  });

  final PtzPanelController controller;
  final String cameraId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final panel = controller.activePanelFor(cameraId);
        if (panel == null) return const SizedBox.shrink();
        final (buttons, editing) = panel;
        return LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            if (w <= 0 || h <= 0) return const SizedBox.shrink();
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (final btn in buttons)
                  _PtzPanelButtonWidget(
                    key: ValueKey(btn.id),
                    controller: controller,
                    button: btn,
                    paneW: w,
                    paneH: h,
                    editing: editing,
                    selected: editing && controller.selectedId == btn.id,
                  ),
                if (editing) ..._snapGuideLines(controller.snapGuides, w, h),
                if (editing && buttons.isEmpty)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Add controls from the bar, then drag them where you want',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  List<Widget> _snapGuideLines(PtzSnapGuides g, double w, double h) {
    const color = Color(0x664CC9FF);
    return [
      for (final x in g.vx)
        Positioned(
          left: x,
          top: 0,
          width: 1,
          height: h,
          child: Container(color: color),
        ),
      for (final y in g.hy)
        Positioned(
          left: 0,
          top: y,
          width: w,
          height: 1,
          child: Container(color: color),
        ),
    ];
  }
}

class _PtzPanelButtonWidget extends StatelessWidget {
  const _PtzPanelButtonWidget({
    super.key,
    required this.controller,
    required this.button,
    required this.paneW,
    required this.paneH,
    required this.editing,
    required this.selected,
  });

  final PtzPanelController controller;
  final PtzPanelButton button;
  final double paneW;
  final double paneH;
  final bool editing;
  final bool selected;

  static const double _delHandle = 16;
  static const double _resizeHandle = 16;

  @override
  Widget build(BuildContext context) {
    final (x, y, w, h) = PtzPanelGeometry.rectFor(button, paneW, paneH);
    return Positioned(
      left: x,
      top: y,
      width: w,
      height: h,
      child: editing ? _editBody(context, w, h) : _viewBody(context, w, h),
    );
  }

  // ─── Edit-mode: draggable body + delete/resize handles ─────────────────

  Widget _editBody(BuildContext context, double w, double h) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => controller.selectButton(button.id),
      onPanStart: (_) => controller.selectButton(button.id),
      onPanUpdate: (d) => controller.moveButtonByDelta(
        button.id,
        paneW,
        paneH,
        d.delta.dx,
        d.delta.dy,
      ),
      onPanEnd: (_) => controller.commitDrag(),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              border: Border.all(
                color: selected
                    ? const Color(0xFF2CA3E8)
                    : const Color(0xFF4CC9FF),
                width: selected ? 2.4 : 1.4,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: _glyphOrLabel(w, h),
          ),
          // Delete (x) handle, top-right, always live in edit mode.
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => controller.deleteButton(button.id),
              child: Container(
                width: _delHandle,
                height: _delHandle,
                decoration: const BoxDecoration(
                  color: Color(0xCC2030D0),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '×',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
          // Resize handle, bottom-right, only when selected.
          if (selected)
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => controller.resizeButtonByDelta(
                  button.id,
                  paneW,
                  paneH,
                  d.delta.dx,
                  d.delta.dy,
                ),
                onPanEnd: (_) => controller.commitDrag(),
                child: Container(
                  width: _resizeHandle,
                  height: _resizeHandle,
                  decoration: const BoxDecoration(
                    color: Color(0xE62CA3E8),
                  ),
                  child: const Icon(
                    Icons.south_east,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── View mode: press-and-hold direction/zoom, tap home/preset/imaging ──

  Widget _viewBody(BuildContext context, double w, double h) {
    if (button.kind == PtzButtonKind.dpad) return _dpad(w, h);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _isMomentary ? null : (_) => _dispatchDown(),
      onTapUp: _isMomentary ? null : (_) => controller.stopContinuous(),
      onTapCancel: _isMomentary ? null : () => controller.stopContinuous(),
      onTap: _isMomentary ? _dispatchTap : null,
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: _glyphOrLabel(w, h),
      ),
    );
  }

  bool get _isMomentary =>
      button.kind == PtzButtonKind.home ||
      button.kind == PtzButtonKind.preset ||
      button.kind == PtzButtonKind.focusNear ||
      button.kind == PtzButtonKind.focusFar ||
      button.kind == PtzButtonKind.autoFocus ||
      button.kind == PtzButtonKind.irisOpen ||
      button.kind == PtzButtonKind.irisClose ||
      button.kind == PtzButtonKind.irisAuto;

  void _dispatchDown() {
    switch (button.kind) {
      case PtzButtonKind.up:
      case PtzButtonKind.down:
      case PtzButtonKind.left:
      case PtzButtonKind.right:
        final v = kPtzArrowVec[kPtzPanelKinds[button.kind]!.arrow]!;
        controller.moveContinuous(pan: v.$1 * 0.6, tilt: v.$2 * 0.6);
        break;
      case PtzButtonKind.zoomIn:
        controller.moveContinuous(zoom: 0.6);
        break;
      case PtzButtonKind.zoomOut:
        controller.moveContinuous(zoom: -0.6);
        break;
      default:
        break;
    }
  }

  void _dispatchTap() {
    switch (button.kind) {
      case PtzButtonKind.home:
        controller.home();
        break;
      case PtzButtonKind.preset:
        if (button.presetToken != null) {
          controller.recallPreset(button.presetToken!);
        }
        break;
      case PtzButtonKind.focusNear:
        controller.imaging(ImagingAction.focusNear);
        break;
      case PtzButtonKind.focusFar:
        controller.imaging(ImagingAction.focusFar);
        break;
      case PtzButtonKind.autoFocus:
        controller.imaging(ImagingAction.autoFocus);
        break;
      case PtzButtonKind.irisOpen:
        controller.imaging(ImagingAction.irisOpen);
        break;
      case PtzButtonKind.irisClose:
        controller.imaging(ImagingAction.irisClose);
        break;
      case PtzButtonKind.irisAuto:
        controller.imaging(ImagingAction.irisAuto);
        break;
      default:
        break;
    }
  }

  Widget _dpad(double w, double h) {
    final cw = w / 3, ch = h / 3;
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(w / 2 * 0.12),
            ),
          ),
          for (var i = 0; i < 9; i++) _dpadCell(i, cw, ch),
        ],
      ),
    );
  }

  Widget _dpadCell(int i, double cw, double ch) {
    final row = i ~/ 3, col = i % 3;
    final vec = kPtzDpadVec[i];
    final isCenter = i == 4;
    IconData? icon;
    if (row == 0 && col == 1) icon = Icons.keyboard_arrow_up;
    if (row == 2 && col == 1) icon = Icons.keyboard_arrow_down;
    if (row == 1 && col == 0) icon = Icons.keyboard_arrow_left;
    if (row == 1 && col == 2) icon = Icons.keyboard_arrow_right;
    return Positioned(
      left: col * cw,
      top: row * ch,
      width: cw,
      height: ch,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: isCenter
            ? null
            : (_) => controller.moveContinuous(
                pan: (vec?.$1 ?? 0) * 0.6,
                tilt: (vec?.$2 ?? 0) * 0.6,
              ),
        onTapUp: isCenter ? null : (_) => controller.stopContinuous(),
        onTapCancel: isCenter ? null : () => controller.stopContinuous(),
        onTap: isCenter ? () => controller.home() : null,
        child: Center(
          child: icon != null
              ? Icon(icon, color: Colors.white70, size: 16)
              : isCenter
              ? const Icon(Icons.home, color: Colors.white70, size: 16)
              : const Text(
                  '•',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
        ),
      ),
    );
  }

  Widget _glyphOrLabel(double w, double h) {
    final spec = kPtzPanelKinds[button.kind];
    if (spec?.arrow != null) {
      final icon = switch (spec!.arrow) {
        'up' => Icons.keyboard_arrow_up,
        'down' => Icons.keyboard_arrow_down,
        'left' => Icons.keyboard_arrow_left,
        'right' => Icons.keyboard_arrow_right,
        _ => Icons.circle,
      };
      return Icon(
        icon,
        color: Colors.white,
        size: (h * 0.6).clamp(10, 24).toDouble(),
      );
    }
    final label = button.displayLabel();
    if (label.isEmpty) return const SizedBox.shrink();
    final fs = (h * 0.42).clamp(9, 16).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: fs),
      ),
    );
  }
}
