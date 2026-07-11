// Settings screen: per-camera "go to" hotkey remap list + master enable
// toggle + reset-to-automatic. Port of app.js's Settings -> This Computer
// "Camera hotkeys" panel (`srvRenderHotkeys` app.js:11052, `srvHotkeyChanged`
// app.js:11072, `srvHotkeyReset` app.js:11085, visibility toggle
// `srvSetHotkeysConfigVisible` app.js:11046).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';

/// Route to this with the same [HotkeyConfigStore] instance the wall's
/// [GlobalHotkeysListener] uses, and the current camera list. Pop it (or let
/// the caller re-fetch) when done — it mutates [store] in place and calls
/// [onChanged] after every edit so the host screen can refresh anything that
/// shows hotkey badges.
class HotkeyRemapScreen extends StatefulWidget {
  const HotkeyRemapScreen({
    super.key,
    required this.store,
    required this.cameras,
    this.onChanged,
  });

  final HotkeyConfigStore store;
  final List<Camera> cameras;
  final VoidCallback? onChanged;

  @override
  State<HotkeyRemapScreen> createState() => _HotkeyRemapScreenState();
}

class _HotkeyRemapScreenState extends State<HotkeyRemapScreen> {
  /// Reverse lookup token for a camera out of a token->cameraId map, or null.
  String? _tokenFor(Map<String, String> map, String cameraId) {
    for (final e in map.entries) {
      if (e.value == cameraId) return e.key;
    }
    return null;
  }

  void _notify() {
    setState(() {});
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final cams = widget.cameras;
    final map = widget.store.configured(cams); // ignores enabled — always show
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera hotkeys'),
        actions: [
          TextButton(
            onPressed: () {
              widget.store.reset();
              _notify();
            },
            child: const Text('Reset to automatic'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Number-key camera shortcuts'),
            subtitle: const Text(
              'Press 1-9, 0, or Shift+1-9/0 to jump to a camera.',
            ),
            value: widget.store.enabled,
            onChanged: (v) {
              widget.store.enabled = v;
              _notify();
            },
          ),
          const Divider(height: 32),
          if (!widget.store.enabled)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Shortcuts are off — the remap list below is disabled.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else if (cams.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No cameras.'),
            )
          else
            for (final cam in cams)
              _HotkeyRow(
                camera: cam,
                token: _tokenFor(map, cam.id),
                onSelect: (token) {
                  widget.store.setMapping(cams, cam.id, token);
                  _notify();
                },
              ),
        ],
      ),
    );
  }
}

class _HotkeyRow extends StatelessWidget {
  const _HotkeyRow({
    required this.camera,
    required this.token,
    required this.onSelect,
  });

  final Camera camera;
  final String? token;
  final void Function(String? token) onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(camera.name, overflow: TextOverflow.ellipsis),
          ),
          DropdownButton<String?>(
            value: token,
            hint: const Text('—'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('—')),
              for (final t in hotkeyTokens)
                DropdownMenuItem<String?>(value: t, child: Text(hotkeyLabel(t))),
            ],
            onChanged: onSelect,
          ),
        ],
      ),
    );
  }
}
