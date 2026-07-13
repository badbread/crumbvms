// Sidebar camera list: click-to-assign into the selected slot, drag-to-assign
// onto any tile, and an "on wall" highlight for cameras already placed.
// Ported from app.js's `buildCameraList` (app.js:2190) — the hotkey badges
// and live-dot health indicator from that function aren't ported (no hotkey
// system or camera health feed exists in the new client yet).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/layout_controller.dart';

/// Drag payload used by [CameraSidebar] rows and consumed by wall-tile
/// `DragTarget`s to implement drag-assign.
class CameraDragData {
  const CameraDragData(this.cameraId);
  final String cameraId;
}

class CameraSidebar extends StatelessWidget {
  const CameraSidebar({super.key, required this.controller});

  final LayoutController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final cams = controller.cameras;
        final onWall = controller.slotMap.values.toSet();
        return Container(
          width: 220,
          color: Colors.black.withValues(alpha: 0.35),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Text(
                  'CAMERAS',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              if (cams.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No cameras found',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: cams.length,
                  itemBuilder: (context, i) {
                    final cam = cams[i];
                    return _CameraRow(
                      camera: cam,
                      isOnWall: onWall.contains(cam.id),
                      onTap: controller.maximized != null
                          ? null
                          : () => controller.assignCameraToSelectedSlot(cam.id),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CameraRow extends StatelessWidget {
  const _CameraRow({
    required this.camera,
    required this.isOnWall,
    required this.onTap,
  });

  final Camera camera;
  final bool isOnWall;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isOnWall ? Colors.cyanAccent.withValues(alpha: 0.08) : null,
          border: Border(
            left: BorderSide(
              color: isOnWall ? Colors.cyanAccent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(
              camera.enabled ? Icons.videocam_outlined : Icons.videocam_off,
              size: 15,
              color: camera.enabled ? Colors.white60 : Colors.white24,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                camera.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isOnWall ? Colors.white : Colors.white70,
                  fontSize: 12.5,
                  fontWeight: isOnWall ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (camera.ptz)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.control_camera,
                  size: 13,
                  color: Colors.white38,
                ),
              ),
          ],
        ),
      ),
    );

    // Draggable so a camera can be dropped directly onto any tile, not just
    // the currently-selected one (app.js relied on click + selectSlot for
    // this; drag is a native-feeling addition matching the "drag-assign"
    // half of this feature's brief).
    return Draggable<CameraDragData>(
      data: CameraDragData(camera.id),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.cyanAccent),
          ),
          child: Text(
            camera.name,
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: row),
      child: row,
    );
  }
}
