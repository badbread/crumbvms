// Entry widget for the custom PTZ panel editor feature: drop this into the
// same Stack that hosts a PTZ-capable camera's video pane (alongside/instead
// of the stock D-pad `_PtzControls` in wall_screen.dart) and it self-manages
// loading the saved layout, rendering it over the video, the "Edit panel"
// toggle, and the edit-mode toolbar.
//
// Integration (wall_screen.dart maximized-tile Stack — NOT edited by this
// port; wire it in by hand):
//
//   if (widget.camera.ptz)
//     Positioned.fill(
//       child: PtzCustomPanelHost(
//         api: widget.api,
//         session: widget.session,
//         camera: widget.camera,
//       ),
//     ),
//
// Placed ABOVE the Video widget and (optionally) alongside the existing
// `_PtzControls` bottom-right D-pad — this widget's own edit-toggle button
// defaults to top-right so the two don't overlap. When a camera has no saved
// custom panel and isn't being edited, [PtzPanelOverlay] renders nothing, so
// stacking this over the stock controls is a no-op until the operator turns
// panel-editing on.
//
// One [PtzPanelStore] should be shared across every `PtzCustomPanelHost` in
// the app (it's a cheap in-memory-cached wrapper over one
// `shared_preferences` key) — pass the same instance down via `store:` from
// wherever the app already threads long-lived singletons (e.g. next to the
// `MediaTokenCache` in the session controller). Omitting it constructs a new
// (working, but separately-cached-until-first-load) store per host, which is
// fine for a single-tile-at-a-time UI but wasteful if several tiles mount
// hosts concurrently.

import 'package:flutter/material.dart';

import '../../api/crumb_api.dart';
import '../../api/models.dart';
import '../../api/ptz_panel_store.dart';
import 'ptz_panel_controller.dart';
import 'ptz_panel_editor_bar.dart';
import 'ptz_panel_overlay.dart';

class PtzCustomPanelHost extends StatefulWidget {
  const PtzCustomPanelHost({
    super.key,
    required this.api,
    required this.session,
    required this.camera,
    this.store,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;

  /// Shared panel store; see the class doc. A private one is created if
  /// omitted.
  final PtzPanelStore? store;

  @override
  State<PtzCustomPanelHost> createState() => _PtzCustomPanelHostState();
}

class _PtzCustomPanelHostState extends State<PtzCustomPanelHost> {
  late final PtzPanelStore _store = widget.store ?? PtzPanelStore();
  late final PtzPanelController _controller = PtzPanelController(
    api: widget.api,
    session: widget.session,
    store: _store,
  );

  @override
  void initState() {
    super.initState();
    _controller.loadForView(widget.camera.id);
  }

  @override
  void didUpdateWidget(covariant PtzCustomPanelHost old) {
    super.didUpdateWidget(old);
    if (old.session.token != widget.session.token ||
        old.session.base != widget.session.base) {
      _controller.updateSession(widget.session);
    }
    if (old.camera.id != widget.camera.id) {
      if (_controller.editMode) _controller.endEdit();
      _controller.loadForView(widget.camera.id);
    }
  }

  @override
  void dispose() {
    if (_controller.editMode) {
      // Best-effort persist of any in-flight edit if the tile is torn down
      // (e.g. un-maximized) without the operator tapping Done.
      _controller.endEdit();
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Stack(
          children: [
            Positioned.fill(
              child: PtzPanelOverlay(
                controller: _controller,
                cameraId: widget.camera.id,
              ),
            ),
            Positioned(
              right: 16,
              top: 16,
              child: _EditToggleButton(
                controller: _controller,
                cameraId: widget.camera.id,
              ),
            ),
            if (_controller.editMode)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: PtzPanelEditorBar(controller: _controller),
              ),
          ],
        );
      },
    );
  }
}

class _EditToggleButton extends StatelessWidget {
  const _EditToggleButton({required this.controller, required this.cameraId});

  final PtzPanelController controller;
  final String cameraId;

  @override
  Widget build(BuildContext context) {
    final active = controller.editMode && controller.editCameraId == cameraId;
    return Material(
      color: active
          ? const Color(0xFF2CA3E8)
          : Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () =>
            active ? controller.endEdit() : controller.beginEdit(cameraId),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            active ? Icons.check : Icons.tune,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}
