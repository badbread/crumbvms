// Toolbar row of layout preset buttons + the "All Cameras" pseudo-view
// button. Ported from app.js's `buildLayoutPresets` (app.js:2084), minus the
// server-backed Saved Views list it also rendered there (out of scope here —
// see layout_controller.dart's header comment).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/state/layout_controller.dart';
import 'package:crumb_desktop/state/wall_layout.dart';
import 'layout_preset_icon.dart';

class LayoutPresetBar extends StatelessWidget {
  const LayoutPresetBar({super.key, required this.controller});

  final LayoutController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _PresetButton(
                active: controller.isAllCameras,
                icon: const Icon(
                  Icons.grid_view_rounded,
                  size: 16,
                  color: Colors.white70,
                ),
                label: 'All Cameras',
                tooltip: 'Show every camera in an auto-sized grid',
                onTap: controller.cameras.isEmpty
                    ? null
                    : controller.applyAllCamerasView,
              ),
              const SizedBox(width: 8),
              Container(width: 1, height: 22, color: Colors.white24),
              const SizedBox(width: 8),
              for (final preset in kLayoutPresets) ...[
                _PresetButton(
                  active: !controller.isAllCameras &&
                      controller.layoutId == preset.id,
                  icon: LayoutPresetIcon(layoutId: preset.id),
                  label: preset.label,
                  tooltip: '${preset.label} (${preset.tiles} tiles)',
                  onTap: () => controller.activateLayout(preset.id),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({
    required this.active,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final bool active;
  final Widget icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? Colors.cyanAccent.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? Colors.cyanAccent : Colors.white24,
              width: active ? 1.4 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: active ? Colors.cyanAccent : Colors.white70,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
