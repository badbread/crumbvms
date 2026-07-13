// Tile right-click context menu — port of app.js `ctxOpen` / `ctxMakeItem` /
// `ctxPositionAndShow` (apps/desktop/src/app.js:5804, 6028, 5903).
//
// The old client hand-rolled a floating <div> menu with flyout <div>
// submenus, clamped to the viewport and flipped near the right edge. Flutter
// desktop already gets equivalent behavior for free from `showMenu` (a
// Material popup route: viewport-clamped position, dismiss on outside-click
// or Escape) so this reimplements the SAME command set — Set camera (with an
// "(empty)" clear option, commercial-VMS-style "move" semantics), Stream
// (main/sub, only when the slot has a camera), Maximize/Restore — as two
// cascaded `showMenu` calls (top-level, then the chosen submenu) rather than
// reproducing the old client's manual DOM positioning/hiding.
//
// Call [showTileContextMenu] from a tile's onSecondaryTapUp (right-click)
// handler with the tap's global position.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

import 'stream_pref_store.dart';
import 'wall_slot_controller.dart';

enum _TileMenuAction { setCamera, stream, maximize }

/// Opens the tile context menu for `slot` at `globalPosition` (e.g. from
/// `TapUpDetails.globalPosition` on `onSecondaryTapUp`). Reads/writes
/// [slotController] and [streamPrefStore] directly — both are `ChangeNotifier`s
/// so any listening wall UI re-syncs itself when this menu mutates them
/// (matching app.js's `buildTileGrid()` / `syncPanes()` calls after each
/// action).
///
/// [cameras] is the full viewer-visible camera list (`GET /cameras`), used to
/// populate "Set camera". [api]/[session] are used to fetch stream URLs on
/// demand so the "Stream" submenu can tell whether a sub stream actually
/// exists for the camera in this slot (mirrors app.js checking
/// `state.streams.get(slotCam)` before offering "Sub").
Future<void> showTileContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required int slot,
  required List<Camera> cameras,
  required CrumbApi api,
  required Session session,
  required WallSlotController slotController,
  required StreamPrefStore streamPrefStore,
}) async {
  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromLTRB(
    globalPosition.dx,
    globalPosition.dy,
    overlayBox.size.width - globalPosition.dx,
    overlayBox.size.height - globalPosition.dy,
  );

  // Honour the maximize override, same as app.js's `hereCam` resolution: if
  // this slot is currently the maximized one, show/act on the maximized
  // camera even if it was borrowed from a different slot.
  final hereCamId = slotController.cameraIdForSlot(slot);
  final isMaxed = slotController.isMaximized(slot);

  final action = await showMenu<_TileMenuAction>(
    context: context,
    position: position,
    items: [
      const PopupMenuItem(
        value: _TileMenuAction.setCamera,
        child: _MenuRow('Set camera', hasSubmenu: true),
      ),
      if (hereCamId != null)
        const PopupMenuItem(
          value: _TileMenuAction.stream,
          child: _MenuRow('Stream', hasSubmenu: true),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: _TileMenuAction.maximize,
        child: _MenuRow(isMaxed ? 'Restore' : 'Maximize'),
      ),
    ],
  );

  if (action == null || !context.mounted) return;

  switch (action) {
    case _TileMenuAction.setCamera:
      await _showSetCameraSubmenu(
        context: context,
        position: position,
        slot: slot,
        cameras: cameras,
        hereCamId: hereCamId,
        slotController: slotController,
      );
      break;
    case _TileMenuAction.stream:
      if (hereCamId == null) return;
      await _showStreamSubmenu(
        context: context,
        position: position,
        cameraId: hereCamId,
        api: api,
        session: session,
        streamPrefStore: streamPrefStore,
      );
      break;
    case _TileMenuAction.maximize:
      slotController.toggleMaximize(slot);
      break;
  }
}

/// "Set camera" submenu: "(empty)" to clear, then every camera. The current
/// occupant (if any) is highlighted, matching app.js's
/// `item.style.color = 'var(--live)'` for `isHere`.
Future<void> _showSetCameraSubmenu({
  required BuildContext context,
  required RelativeRect position,
  required int slot,
  required List<Camera> cameras,
  required String? hereCamId,
  required WallSlotController slotController,
}) async {
  const emptySentinel = ''; // '(empty)' choice
  final chosen = await showMenu<String>(
    context: context,
    position: position,
    items: [
      PopupMenuItem(
        value: emptySentinel,
        child: Text(
          '(empty)',
          style: TextStyle(
            color: hereCamId == null
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        ),
      ),
      for (final cam in cameras)
        PopupMenuItem(
          value: cam.id,
          child: Text(
            cam.name,
            style: TextStyle(
              color: cam.id == hereCamId
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
        ),
    ],
  );

  if (chosen == null) return; // dismissed without a choice
  if (chosen == emptySentinel) {
    slotController.clearSlot(slot);
  } else {
    slotController.assignCamera(slot, chosen);
  }
}

/// "Stream" submenu: Main (always) / Sub (disabled if the camera has no sub
/// stream), current preference checked. Mirrors app.js's `hasSub` check
/// against `state.streams.get(slotCam)` and `setStreamPref` + `syncPanes()`.
Future<void> _showStreamSubmenu({
  required BuildContext context,
  required RelativeRect position,
  required String cameraId,
  required CrumbApi api,
  required Session session,
  required StreamPrefStore streamPrefStore,
}) async {
  bool hasSub = false;
  try {
    final streams = await api.cameraStreams(session, cameraId);
    hasSub = streams.rtspSub != null;
  } catch (_) {
    // If the fetch fails, fall back to "unavailable" for sub rather than
    // blocking the menu — matches the old client's tolerance of a missing
    // `state.streams` entry (it just wouldn't offer sub).
    hasSub = false;
  }

  if (!context.mounted) return;
  final pref = streamPrefStore.prefFor(cameraId);

  final chosen = await showMenu<StreamKind>(
    context: context,
    position: position,
    items: [
      CheckedPopupMenuItem(
        value: StreamKind.main,
        checked: pref == StreamKind.main,
        child: const Text('Main — full quality'),
      ),
      CheckedPopupMenuItem(
        value: StreamKind.sub,
        checked: pref == StreamKind.sub,
        enabled: hasSub,
        child: Text(hasSub ? 'Sub — low bandwidth' : 'Sub — (unavailable)'),
      ),
    ],
  );

  if (chosen == null) return;
  streamPrefStore.setPref(cameraId, chosen);
}

/// A menu-item label with an optional trailing "opens a submenu" chevron,
/// standing in for the old client's flyout-arrow submenu affordance.
class _MenuRow extends StatelessWidget {
  const _MenuRow(this.label, {this.hasSubmenu = false});

  final String label;
  final bool hasSubmenu;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        if (hasSubmenu)
          const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
      ],
    );
  }
}
