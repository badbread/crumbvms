// Settings screen: the "Keyboard Shortcuts" section — master enable toggle
// (ClientOptionsStore.hotkeysEnabled), the remappable ACTION shortcuts
// (KeyboardShortcutsStore: snapshot / toggle audio / perf HUD) with a
// click-to-record capture flow (same pattern as hotkey_remap_screen.dart's
// _RecorderSlot), reserved-key + conflict guards, and a read-only listing of
// the camera number-key hotkeys for conflict awareness (those are remapped in
// the Camera Hotkeys section, not here).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';

/// Lone modifier keys — never assignable (they'd fire on every combo and the
/// Windows key belongs to the OS).
final Set<LogicalKeyboardKey> _modifierKeys = {
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.capsLock,
  LogicalKeyboardKey.numLock,
  LogicalKeyboardKey.scrollLock,
  LogicalKeyboardKey.fn,
  LogicalKeyboardKey.fnLock,
};

/// Keys with a fixed app meaning — assigning one would break navigation,
/// typing, or the playback transport. Value = why, for the rejection message.
final Map<LogicalKeyboardKey, String> _reservedKeys = {
  LogicalKeyboardKey.escape: 'closes overlays and restores maximize',
  LogicalKeyboardKey.enter: 'activates the focused control',
  LogicalKeyboardKey.numpadEnter: 'activates the focused control',
  LogicalKeyboardKey.tab: 'moves keyboard focus',
  LogicalKeyboardKey.space: 'play/pause in Playback',
  LogicalKeyboardKey.arrowLeft: 'shifts the Playback window',
  LogicalKeyboardKey.arrowRight: 'shifts the Playback window',
  LogicalKeyboardKey.arrowUp: 'scrolls lists',
  LogicalKeyboardKey.arrowDown: 'scrolls lists',
  LogicalKeyboardKey.comma: 'previous motion / frame step in Playback',
  LogicalKeyboardKey.period: 'next motion / frame step in Playback',
  LogicalKeyboardKey.backspace: 'editing text',
  LogicalKeyboardKey.delete: 'editing text',
  LogicalKeyboardKey.contextMenu: 'opens context menus',
};

/// The camera-hotkey banks' keys — assignable only in Camera Hotkeys.
final Set<LogicalKeyboardKey> _cameraBankKeys = {
  LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9, LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.numpad1, LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3, LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5, LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7, LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9, LogicalKeyboardKey.numpad0,
};

/// The Keyboard Shortcuts settings pane. [store] holds the action bindings;
/// [options] drives the master enable toggle; [cameraHotkeys] + [cameras]
/// feed the read-only camera-key listing (both optional — the section they
/// back simply hides/disables when absent).
class KeyboardShortcutsScreen extends StatefulWidget {
  const KeyboardShortcutsScreen({
    super.key,
    required this.store,
    this.options,
    this.cameraHotkeys,
    this.cameras = const [],
  });

  final KeyboardShortcutsStore store;
  final ClientOptionsStore? options;
  final HotkeyConfigStore? cameraHotkeys;
  final List<Camera> cameras;

  @override
  State<KeyboardShortcutsScreen> createState() =>
      _KeyboardShortcutsScreenState();
}

class _KeyboardShortcutsScreenState extends State<KeyboardShortcutsScreen> {
  /// The action currently in "press a key…" capture mode, or null.
  ShortcutAction? _recording;

  /// Why the last capture was rejected (reserved key / conflict), or null.
  String? _rejectMsg;

  final FocusNode _captureFocus = FocusNode();

  @override
  void dispose() {
    _captureFocus.dispose();
    super.dispose();
  }

  void _startRecording(ShortcutAction action) {
    setState(() {
      _recording = action;
      _rejectMsg = null;
    });
    _captureFocus.requestFocus();
  }

  /// Reserved-key + conflict validation. Null = OK to bind.
  String? _validate(ShortcutAction action, LogicalKeyboardKey key) {
    if (_modifierKeys.contains(key)) {
      return 'Modifier keys (Shift, Ctrl, Alt, the Windows key) can\'t be '
          'used as shortcuts.';
    }
    final reserved = _reservedKeys[key];
    if (reserved != null) {
      return '${shortcutKeyLabel(key)} is reserved — it $reserved.';
    }
    if (_cameraBankKeys.contains(key)) {
      return 'Number keys are the camera hotkeys — remap those in the '
          'Camera Hotkeys section.';
    }
    final other = widget.store.actionForKey(key, except: action);
    if (other != null) {
      return '${shortcutKeyLabel(key)} is already assigned to '
          '"${other.label}".';
    }
    return null;
  }

  KeyEventResult _onCaptureKey(FocusNode node, KeyEvent event) {
    final action = _recording;
    if (action == null || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = null);
      return KeyEventResult.handled;
    }
    // A combo (Ctrl+X etc.) can't be stored — bindings are single keys. The
    // modifier's own keydown falls through to _validate's modifier reject.
    final keys = HardwareKeyboard.instance;
    if (!_modifierKeys.contains(event.logicalKey) &&
        (keys.isControlPressed ||
            keys.isAltPressed ||
            keys.isMetaPressed ||
            keys.isShiftPressed)) {
      setState(() {
        _recording = null;
        _rejectMsg = 'Shortcuts are single keys — press one key without '
            'holding a modifier.';
      });
      return KeyEventResult.handled;
    }
    final error = _validate(action, event.logicalKey);
    setState(() {
      _recording = null;
      _rejectMsg = error;
      if (error == null) widget.store.setKey(action, event.logicalKey);
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.options?.hotkeysEnabled ?? true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Keyboard Shortcuts'),
        actions: [
          ListenableBuilder(
            listenable: widget.store,
            builder: (context, _) => TextButton(
              onPressed: widget.store.allDefaults
                  ? null
                  : () => setState(widget.store.resetToDefaults),
              child: const Text('Reset to defaults'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Enable keyboard shortcuts'),
            subtitle: const Text(
              'Master switch for every shortcut — the actions below and the '
              'camera number keys.',
            ),
            value: enabled,
            onChanged: widget.options == null
                ? null
                : (v) => setState(() => widget.options!.hotkeysEnabled = v),
          ),
          const Divider(height: 32),
          if (!enabled)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Shortcuts are off — the bindings below are kept but inert.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          _header(context, 'Actions'),
          for (final action in ShortcutAction.values)
            _actionRow(context, action),
          if (_rejectMsg != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
              child: Text(
                _rejectMsg!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          const Divider(height: 32),
          _header(context, 'Camera hotkeys (read-only)'),
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
            child: Text(
              'The number row (Shift for 11-20) and numeric keypad jump to '
              'cameras. Shown here for conflict awareness — remap them in the '
              'Camera Hotkeys section.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          ..._cameraHotkeyRows(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// One remappable action: label + description on the left, the binding
  /// button (click → "press a key…") on the right.
  Widget _actionRow(BuildContext context, ShortcutAction action) {
    final scheme = Theme.of(context).colorScheme;
    final recording = _recording == action;
    final Widget slot;
    if (recording) {
      slot = Focus(
        focusNode: _captureFocus,
        autofocus: true,
        onKeyEvent: _onCaptureKey,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.primary),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'Press a key · Esc cancels',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.primary),
          ),
        ),
      );
    } else {
      slot = ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) => OutlinedButton(
          onPressed: () => _startRecording(action),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          child: Text(
            shortcutKeyLabel(widget.store.keyFor(action)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(action.label, style: const TextStyle(fontSize: 13)),
                Text(
                  action.description,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 140, child: slot),
        ],
      ),
    );
  }

  /// Read-only camera-key rows: "1 → Front door", "Num 3 → Garage", … from
  /// the SAME configured maps the Camera Hotkeys section edits.
  List<Widget> _cameraHotkeyRows(BuildContext context) {
    final store = widget.cameraHotkeys;
    if (store == null || widget.cameras.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No cameras.', style: TextStyle(fontSize: 12)),
        ),
      ];
    }
    final scheme = Theme.of(context).colorScheme;
    final byId = {for (final c in widget.cameras) c.id: c};
    final rowMap = store.configured(widget.cameras);
    final numMap = store.numpadConfigured(widget.cameras);
    Widget row(String token, String cameraId) {
      final cam = byId[cameraId];
      if (cam == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                hotkeyLabel(token),
                style: TextStyle(
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onSurface,
                ),
              ),
            ),
            Expanded(
              child: Text(
                cam.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }

    return [
      // Stable, familiar order: the token banks' own order, skipping
      // unassigned tokens.
      for (final t in hotkeyTokens)
        if (rowMap[t] != null) row(t, rowMap[t]!),
      for (final t in numpadTokens)
        if (numMap[t] != null) row(t, numMap[t]!),
    ];
  }
}
