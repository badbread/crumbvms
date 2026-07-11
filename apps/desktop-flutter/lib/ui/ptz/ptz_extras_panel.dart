// Combined PTZ "extras" panel: presets pill + imaging (focus/iris) chips +
// a click-mode selector (off/center/pan) that a host screen wires into
// PtzInteractionOverlay. Designed to sit near the existing on-video PTZ
// d-pad (wall_screen.dart's private `_PtzControls`) without needing to
// touch that file — see the integration note for exact placement.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

import 'ptz_click_mode.dart';
import 'ptz_imaging_controls.dart';
import 'ptz_presets_panel.dart';

class PtzExtrasPanel extends StatelessWidget {
  const PtzExtrasPanel({
    super.key,
    required this.api,
    required this.session,
    required this.cameraId,
    required this.clickMode,
    required this.onClickModeChanged,
  });

  final CrumbApi api;
  final Session session;
  final String cameraId;
  final PtzClickMode clickMode;
  final ValueChanged<PtzClickMode> onClickModeChanged;

  Widget _modeChip(PtzClickMode m, IconData icon, String tooltip) {
    final active = clickMode == m;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => onClickModeChanged(m),
        child: Container(
          margin: const EdgeInsets.all(2),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: active
                ? Colors.cyanAccent.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? Colors.cyanAccent : Colors.white24),
          ),
          child: Icon(icon, color: Colors.white, size: 16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        PtzPresetsPanel(api: api, session: session, cameraId: cameraId),
        const SizedBox(height: 6),
        PtzImagingControls(api: api, session: session, cameraId: cameraId),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeChip(PtzClickMode.off, Icons.block, 'Video click: off'),
              _modeChip(PtzClickMode.center, Icons.center_focus_strong, 'Video click: click-to-center'),
              _modeChip(PtzClickMode.pan, Icons.open_with, 'Video click: hold-to-pan'),
            ],
          ),
        ),
      ],
    );
  }
}
