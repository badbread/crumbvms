// Renders a camera's custom PTZ panel over the video pane, as a thin skin on
// the shared drag-to-place overlay editor (`overlay_editor/`, the P1 port —
// this file used to carry its own Stack/hit-test/drag machinery). This file
// keeps only what is PTZ-specific: the button visual language and the
// view-mode dispatch gestures (press-and-hold direction/zoom, tap
// home/preset/imaging — ported from app.js's `ptzBuildCustomAss` /
// `ptzCustomHit`).
//
// Edit mode renders the live shared-editor session (drag/multi-select/
// marquee/snap all come from `OverlayEditorLayer`); view mode renders the
// saved layout with each button carrying its own gesture handling — the
// layer's generic wrapper stays inert (no `onTapItem`) so the button-local
// detectors receive the events, and gaps between buttons still fall through
// to the video pane's click-to-center / hold-to-pan / wheel-zoom.
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
import '../overlay_editor/overlay_editor_layer.dart';
import '../overlay_editor/overlay_item.dart';
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
        if (editing) {
          return OverlayEditorLayer(
            controller: controller.editor,
            editing: true,
            buildItem: _buildEditItem,
            emptyEditHint:
                'Add controls from the bar, then drag them where you want',
          );
        }
        return OverlayEditorLayer(
          controller: controller.editor,
          editing: false,
          items: [for (final b in buttons) PtzOverlayButtonItem(b)],
          buildItem: _buildViewItem,
        );
      },
    );
  }

  // ─── Edit-mode visual (selection styling only; the shared layer owns the
  //     hit target, handles and drag) ──────────────────────────────────────

  Widget _buildEditItem(
    OverlayItem item, {
    required bool editing,
    required bool selected,
  }) {
    final button = (item as PtzOverlayButtonItem).button;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        border: Border.all(
          color: selected ? const Color(0xFF2CA3E8) : const Color(0xFF4CC9FF),
          width: selected ? 2.4 : 1.4,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            _PtzGlyphOrLabel(button: button, boxHeight: constraints.maxHeight),
      ),
    );
  }

  // ─── View-mode visual + dispatch gestures ───────────────────────────────

  Widget _buildViewItem(
    OverlayItem item, {
    required bool editing,
    required bool selected,
  }) {
    final button = (item as PtzOverlayButtonItem).button;
    return _PtzViewButton(controller: controller, button: button);
  }
}

/// One live (view-mode) panel button: press-and-hold direction/zoom, tap
/// home/preset/imaging — the same dispatch table as the old renderer.
class _PtzViewButton extends StatelessWidget {
  const _PtzViewButton({required this.controller, required this.button});

  final PtzPanelController controller;
  final PtzPanelButton button;

  bool get _isMomentary =>
      button.kind == PtzButtonKind.home ||
      button.kind == PtzButtonKind.preset ||
      button.kind == PtzButtonKind.focusNear ||
      button.kind == PtzButtonKind.focusFar ||
      button.kind == PtzButtonKind.autoFocus ||
      button.kind == PtzButtonKind.irisOpen ||
      button.kind == PtzButtonKind.irisClose ||
      button.kind == PtzButtonKind.irisAuto;

  @override
  Widget build(BuildContext context) {
    if (button.kind == PtzButtonKind.dpad) {
      return LayoutBuilder(
        builder: (context, constraints) => _dpad(
          constraints.maxWidth,
          constraints.maxHeight,
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _isMomentary ? null : (_) => _dispatchDown(),
      onTapUp: _isMomentary ? null : (_) => controller.stopContinuous(),
      onTapCancel: _isMomentary ? null : () => controller.stopContinuous(),
      onTap: _isMomentary ? _dispatchTap : null,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: LayoutBuilder(
          builder: (context, constraints) => _PtzGlyphOrLabel(
            button: button,
            boxHeight: constraints.maxHeight,
          ),
        ),
      ),
    );
  }

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
}

/// A button's glyph (arrow kinds) or text label, sized against the button's
/// rendered height — shared by the edit and view visuals so the two modes
/// read identically.
class _PtzGlyphOrLabel extends StatelessWidget {
  const _PtzGlyphOrLabel({required this.button, required this.boxHeight});

  final PtzPanelButton button;
  final double boxHeight;

  @override
  Widget build(BuildContext context) {
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
        size: (boxHeight * 0.6).clamp(10, 24).toDouble(),
      );
    }
    final label = button.displayLabel();
    if (label.isEmpty) return const SizedBox.shrink();
    final fs = (boxHeight * 0.42).clamp(9, 16).toDouble();
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
