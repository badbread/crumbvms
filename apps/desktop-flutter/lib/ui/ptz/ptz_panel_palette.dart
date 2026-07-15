// PTZ host content for the shared overlay editor bar
// (`overlay_editor/overlay_editor_bar.dart`): the "Add:" palette (one button
// per control kind + one per configured ONVIF preset) and the PTZ-specific
// selected-button extras (rename, duplicate, z-order). Ports the palette half
// of the old `ptz_panel_editor_bar.dart` (`ptzPanelEditorRender`,
// apps/desktop/src/app.js:5267-5311); the generic Done/Clear/size/align/
// group tooling now comes from the shared bar itself.

import 'package:flutter/material.dart';

import '../../api/ptz_panel_models.dart';
import 'ptz_panel_controller.dart';

/// The "Add:" row — palette slot for `OverlayEditorBar.paletteSlot`.
class PtzPanelPalette extends StatelessWidget {
  const PtzPanelPalette({super.key, required this.controller});

  final PtzPanelController controller;

  static const _addKinds = <(PtzButtonKind, String)>[
    (PtzButtonKind.dpad, 'D-pad'),
    (PtzButtonKind.up, '▲'),
    (PtzButtonKind.down, '▼'),
    (PtzButtonKind.left, '◄'),
    (PtzButtonKind.right, '►'),
    (PtzButtonKind.home, 'Home'),
    (PtzButtonKind.zoomIn, 'Zoom+'),
    (PtzButtonKind.zoomOut, 'Zoom−'),
    (PtzButtonKind.focusNear, 'Focus−'),
    (PtzButtonKind.focusFar, 'Focus+'),
    (PtzButtonKind.autoFocus, 'AF'),
    (PtzButtonKind.irisOpen, 'Iris+'),
    (PtzButtonKind.irisClose, 'Iris−'),
    (PtzButtonKind.irisAuto, 'IrisA'),
  ];

  @override
  Widget build(BuildContext context) {
    // Listens to the HOST controller (not the shared editor): the preset
    // list arriving is a host-level change, and add-clicks don't need a
    // rebuild here at all (the layer/bar listen to the editor themselves).
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          const Text(
            'Add:',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          for (final (kind, label) in _addKinds)
            _PaletteButton(label: label, onTap: () => controller.addButton(kind)),
          for (final p in controller.presets)
            _PaletteButton(
              label: '★ ${p.label}',
              onTap: () => controller.addButton(
                PtzButtonKind.preset,
                presetToken: p.token,
                presetName: p.label,
              ),
            ),
        ],
      ),
    );
  }
}

/// PTZ-specific properties for the primary selected button — plugs into
/// `OverlayEditorBar.selectedExtrasBuilder`. Rename (labelable kinds),
/// duplicate, and z-order to-front/to-back.
class PtzSelectedButtonExtras extends StatefulWidget {
  const PtzSelectedButtonExtras({
    super.key,
    required this.controller,
    required this.button,
  });

  final PtzPanelController controller;

  /// The primary selected item's button (`OverlayEditorController.selected`,
  /// unwrapped by the caller).
  final PtzPanelButton button;

  @override
  State<PtzSelectedButtonExtras> createState() =>
      _PtzSelectedButtonExtrasState();
}

class _PtzSelectedButtonExtrasState extends State<PtzSelectedButtonExtras> {
  final _renameCtrl = TextEditingController();
  String? _renameForId;

  @override
  void dispose() {
    _renameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = widget.button;
    if (_renameForId != button.id) {
      _renameForId = button.id;
      _renameCtrl.text = button.displayLabel();
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        if (kPtzLabelableKinds.contains(button.kind))
          SizedBox(
            width: 140,
            height: 30,
            child: TextField(
              controller: _renameCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Label',
                hintStyle: TextStyle(color: Colors.white38),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
              ),
              onChanged: widget.controller.renameSelected,
            ),
          ),
        _PaletteButton(
          label: 'Duplicate',
          onTap: widget.controller.duplicateSelected,
        ),
        _PaletteButton(
          label: 'To front',
          onTap: () => widget.controller.editor.bringToFront(button.id),
        ),
        _PaletteButton(
          label: 'To back',
          onTap: () => widget.controller.editor.sendToBack(button.id),
        ),
      ],
    );
  }
}

class _PaletteButton extends StatelessWidget {
  const _PaletteButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF2A2F36);
    return SizedBox(
      height: 30,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: bg,
          disabledBackgroundColor: bg.withValues(alpha: 0.35),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: Size.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
