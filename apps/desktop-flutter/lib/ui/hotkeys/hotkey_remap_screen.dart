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
    // Both banks — the remap list always shows them regardless of `enabled`.
    final rowMap = widget.store.configured(cams);
    final numMap = widget.store.numpadConfigured(cams);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Hotkeys'),
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
            title: const Text('Camera number-key shortcuts'),
            subtitle: const Text(
              'Press 1-9/0 (Shift for 11-20) or the numeric keypad to jump to a '
              'camera. The keypad is a separate bank — by default it mirrors the '
              'number row, but you can point it at different cameras below.',
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
          else ...[
            const _HotkeyHeader(),
            for (final cam in cams)
              _HotkeyRow(
                camera: cam,
                rowToken: _tokenFor(rowMap, cam.id),
                numpadToken: _tokenFor(numMap, cam.id),
                onSelectRow: (token) {
                  widget.store.setMapping(cams, cam.id, token);
                  _notify();
                },
                onSelectNumpad: (token) {
                  widget.store.setNumpadMapping(cams, cam.id, token);
                  _notify();
                },
              ),
          ],
        ],
      ),
    );
  }
}

/// Column headers over the per-camera rows.
class _HotkeyHeader extends StatelessWidget {
  const _HotkeyHeader();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 2, right: 2),
      child: Row(
        children: [
          Expanded(child: Text('Camera', style: style)),
          SizedBox(width: 120, child: Text('Number key', style: style)),
          SizedBox(width: 120, child: Text('Keypad', style: style)),
        ],
      ),
    );
  }
}

/// Number-row logical keys -> base digit. Shift is read separately to pick the
/// shifted "s"-prefixed token (cameras 11-20).
final Map<LogicalKeyboardKey, String> _rowDigitKeys = {
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
};

/// Numeric-keypad logical keys -> numpad token ("n1".."n0").
final Map<LogicalKeyboardKey, String> _numpadKeys = {
  LogicalKeyboardKey.numpad1: 'n1',
  LogicalKeyboardKey.numpad2: 'n2',
  LogicalKeyboardKey.numpad3: 'n3',
  LogicalKeyboardKey.numpad4: 'n4',
  LogicalKeyboardKey.numpad5: 'n5',
  LogicalKeyboardKey.numpad6: 'n6',
  LogicalKeyboardKey.numpad7: 'n7',
  LogicalKeyboardKey.numpad8: 'n8',
  LogicalKeyboardKey.numpad9: 'n9',
  LogicalKeyboardKey.numpad0: 'n0',
};

/// Per-camera hotkey row: a number-row slot and a keypad slot, each a
/// click-to-record button with a clear.
class _HotkeyRow extends StatelessWidget {
  const _HotkeyRow({
    required this.camera,
    required this.rowToken,
    required this.numpadToken,
    required this.onSelectRow,
    required this.onSelectNumpad,
  });

  final Camera camera;
  final String? rowToken;
  final String? numpadToken;
  final void Function(String? token) onSelectRow;
  final void Function(String? token) onSelectNumpad;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(camera.name, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 120,
            child: _RecorderSlot(
              token: rowToken,
              numpad: false,
              onSelect: onSelectRow,
            ),
          ),
          SizedBox(
            width: 120,
            child: _RecorderSlot(
              token: numpadToken,
              numpad: true,
              onSelect: onSelectNumpad,
            ),
          ),
        ],
      ),
    );
  }
}

/// One assignable key slot: click to record the next matching keypress
/// (number-row digit — Shift for 11-20 — or a keypad digit, per [numpad]),
/// with a clear button. Esc cancels recording.
class _RecorderSlot extends StatefulWidget {
  const _RecorderSlot({
    required this.token,
    required this.numpad,
    required this.onSelect,
  });

  final String? token;
  final bool numpad;
  final void Function(String? token) onSelect;

  @override
  State<_RecorderSlot> createState() => _RecorderSlotState();
}

class _RecorderSlotState extends State<_RecorderSlot> {
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
    String? token;
    if (widget.numpad) {
      token = _numpadKeys[event.logicalKey]; // already "n"-prefixed
    } else {
      final digit = _rowDigitKeys[event.logicalKey];
      if (digit != null) {
        token = HardwareKeyboard.instance.isShiftPressed ? 's$digit' : digit;
      }
    }
    if (token == null) return KeyEventResult.ignored; // wrong key — keep waiting
    widget.onSelect(token);
    setState(() => _recording = false);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_recording) {
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.primary),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.numpad ? 'Press keypad · Esc' : 'Press 0-9 (⇧) · Esc',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.primary),
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _startRecording,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            child: Text(
              widget.token == null ? 'Set' : hotkeyLabel(widget.token!),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Clear',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 14),
          onPressed: widget.token == null ? null : () => widget.onSelect(null),
        ),
      ],
    );
  }
}
