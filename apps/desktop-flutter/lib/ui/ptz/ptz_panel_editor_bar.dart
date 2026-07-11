// Edit-mode toolbar for a custom PTZ panel: an "Add:" palette (one button
// per control kind + one per configured ONVIF preset), Clear all / Done, and
// — when a button is selected — a properties row (rename, resize, delete).
// Ports `ptzPanelEditorRender` (apps/desktop/src/app.js:5267-5311).
//
// Usage: place below (or above) the video pane while
// `controller.editMode == true`, e.g. as the bottom bar of the maximized-tile
// screen that also hosts [PtzPanelOverlay].

import 'package:flutter/material.dart';

import '../../api/ptz_panel_models.dart';
import 'ptz_panel_controller.dart';

class PtzPanelEditorBar extends StatefulWidget {
  const PtzPanelEditorBar({super.key, required this.controller});

  final PtzPanelController controller;

  @override
  State<PtzPanelEditorBar> createState() => _PtzPanelEditorBarState();
}

class _PtzPanelEditorBarState extends State<PtzPanelEditorBar> {
  final _renameCtrl = TextEditingController();
  String? _renameForId;

  @override
  void dispose() {
    _renameCtrl.dispose();
    super.dispose();
  }

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
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final buttons = c.editButtons;
        PtzPanelButton? selected;
        if (c.selectedId != null) {
          for (final b in buttons) {
            if (b.id == c.selectedId) {
              selected = b;
              break;
            }
          }
        }

        if (selected != null && _renameForId != selected.id) {
          _renameForId = selected.id;
          _renameCtrl.text = selected.displayLabel();
        }

        return Material(
          color: Colors.black.withValues(alpha: 0.75),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                const _EdLabel('Add:'),
                for (final (kind, label) in _addKinds)
                  _EdButton(label: label, onTap: () => c.addButton(kind)),
                for (final p in c.presets)
                  _EdButton(
                    label: '★ ${p.label}',
                    onTap: () => c.addButton(
                      PtzButtonKind.preset,
                      presetToken: p.token,
                      presetName: p.label,
                    ),
                  ),
                const SizedBox(width: 12),
                _EdButton(
                  label: 'Clear all',
                  danger: true,
                  onTap: buttons.isEmpty ? null : c.clearAll,
                ),
                _EdButton(
                  label: 'Done',
                  primary: true,
                  onTap: c.endEdit,
                ),
                if (selected != null) ...[
                  const _EdLabel('Selected:'),
                  if (kPtzLabelableKinds.contains(selected.kind))
                    SizedBox(
                      width: 140,
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
                        onChanged: c.renameSelected,
                      ),
                    ),
                  _EdButton(
                    label: '−',
                    onTap: () => c.resizeSelected(1 / 1.15),
                  ),
                  const _EdLabel('size'),
                  _EdButton(label: '+', onTap: () => c.resizeSelected(1.15)),
                  _EdButton(
                    label: 'Duplicate',
                    onTap: c.duplicateSelected,
                  ),
                  _EdButton(
                    label: 'To front',
                    onTap: () => c.bringToFront(selected!.id),
                  ),
                  _EdButton(
                    label: 'To back',
                    onTap: () => c.sendToBack(selected!.id),
                  ),
                  _EdButton(
                    label: 'Delete',
                    danger: true,
                    onTap: () => c.deleteButton(selected!.id),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EdLabel extends StatelessWidget {
  const _EdLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(color: Colors.white70, fontSize: 12),
  );
}

class _EdButton extends StatelessWidget {
  const _EdButton({
    required this.label,
    required this.onTap,
    this.danger = false,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final bg = primary
        ? const Color(0xFF2CA3E8)
        : danger
        ? const Color(0xFF7A2020)
        : const Color(0xFF2A2F36);
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5),
          ),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
