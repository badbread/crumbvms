// Settings screen: per-camera "go to" hotkey remap list + master enable
// toggle + reset-to-automatic. Port of app.js's Settings -> This Computer
// "Camera hotkeys" panel (`srvRenderHotkeys` app.js:11052, `srvHotkeyChanged`
// app.js:11072, `srvHotkeyReset` app.js:11085, visibility toggle
// `srvSetHotkeysConfigVisible` app.js:11046).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// Logical keys that record a hotkey token (digit row + numpad). Shift is read
/// separately to pick the shifted "s"-prefixed token (cameras 11-20).
final Map<LogicalKeyboardKey, String> _digitTokens = {
  LogicalKeyboardKey.digit1: '1',
  LogicalKeyboardKey.digit2: '2',
  LogicalKeyboardKey.digit3: '3',
  LogicalKeyboardKey.digit4: '4',
  LogicalKeyboardKey.digit5: '5',
  LogicalKeyboardKey.digit6: '6',
  LogicalKeyboardKey.digit7: '7',
  LogicalKeyboardKey.digit8: '8',
  LogicalKeyboardKey.digit9: '9',
  LogicalKeyboardKey.digit0: '0',
  LogicalKeyboardKey.numpad1: '1',
  LogicalKeyboardKey.numpad2: '2',
  LogicalKeyboardKey.numpad3: '3',
  LogicalKeyboardKey.numpad4: '4',
  LogicalKeyboardKey.numpad5: '5',
  LogicalKeyboardKey.numpad6: '6',
  LogicalKeyboardKey.numpad7: '7',
  LogicalKeyboardKey.numpad8: '8',
  LogicalKeyboardKey.numpad9: '9',
  LogicalKeyboardKey.numpad0: '0',
};

/// Per-camera hotkey row: click "Set key" to record (the next 0-9 / ⇧0-9
/// keypress is captured), with a clear button to unassign. Replaces the old
/// dropdown-list picker.
class _HotkeyRow extends StatefulWidget {
  const _HotkeyRow({
    required this.camera,
    required this.token,
    required this.onSelect,
  });

  final Camera camera;
  final String? token;
  final void Function(String? token) onSelect;

  @override
  State<_HotkeyRow> createState() => _HotkeyRowState();
}

class _HotkeyRowState extends State<_HotkeyRow> {
  final FocusNode _focus = FocusNode();
  bool _recording = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _startRecording() {
    setState(() => _recording = true);
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    final digit = _digitTokens[event.logicalKey];
    if (digit == null) return KeyEventResult.ignored; // keep waiting
    final shift = HardwareKeyboard.instance.isShiftPressed;
    widget.onSelect(shift ? 's$digit' : digit);
    setState(() => _recording = false);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(widget.camera.name, overflow: TextOverflow.ellipsis),
          ),
          if (_recording)
            Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Press 0-9 (⇧ for 11-20) · Esc to cancel',
                  style: TextStyle(fontSize: 12, color: scheme.primary),
                ),
              ),
            )
          else ...[
            SizedBox(
              width: 96,
              child: OutlinedButton(
                onPressed: _startRecording,
                child: Text(
                  widget.token == null
                      ? 'Set key'
                      : hotkeyLabel(widget.token!),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close, size: 16),
              onPressed: widget.token == null
                  ? null
                  : () => widget.onSelect(null),
            ),
          ],
        ],
      ),
    );
  }
}
