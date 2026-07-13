// "Go to" a camera on the managed live wall: maximize it if it's already
// somewhere on the wall, otherwise place it in a free slot (or fall back to
// the selected slot) and maximize that. Pressing the same camera's hotkey
// again restores the wall (toggle).
//
// Port of app.js `focusLiveCameraMaximized` (app.js:4076), rebuilt on top of
// [LayoutController]'s existing public API only (this file must not, and
// does not, reach into LayoutController's private slot map).

import 'package:crumb_desktop/state/layout_controller.dart';

/// Maximize `cameraId` on the wall; if it's already the maximized camera,
/// restore instead (mirrors the old client's toggle-off-if-already-maximized
/// behavior). If the camera isn't currently assigned to any slot, it's
/// placed in the first empty slot, falling back to the currently-selected
/// slot if the wall is full — matching app.js's slot-choice fallback order
/// (empty slot preferred over stealing a filled one, so a hotkey press never
/// silently evicts an unrelated camera from the wall).
void goToCameraOnLiveWall(LayoutController controller, String cameraId) {
  if (controller.maximized?.id == cameraId) {
    controller.restoreFromMaximize();
    return;
  }

  final slotMap = controller.slotMap;
  int? slotIndex;
  for (final entry in slotMap.entries) {
    if (entry.value == cameraId) {
      slotIndex = entry.key;
      break;
    }
  }

  if (slotIndex == null) {
    // Camera isn't on the current wall — prefer an EMPTY slot so the
    // maximized pane is fresh + self-consistent (see app.js:4090-4098's
    // reasoning: reusing a FILLED slot leaves the slotMap pointing at a
    // different camera than what's showing).
    for (var i = 0; i < controller.tileCount; i++) {
      if (!slotMap.containsKey(i)) {
        slotIndex = i;
        break;
      }
    }
    slotIndex ??= controller.selectedSlot;
    controller.assignCameraToSlot(cameraId, slotIndex);
  }

  controller.maximizeSlot(slotIndex);
}
