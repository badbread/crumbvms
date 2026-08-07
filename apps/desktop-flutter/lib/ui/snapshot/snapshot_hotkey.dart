// Wires the "S" hotkey to [SnapshotService.captureActivePane]. Old client:
// the global keydown handler's `if (e.key === 's' || e.key === 'S')` branch
// (apps/desktop/src/app.js:4132), which called `snapshotActivePane()`
// directly.
//
// Wrap the signed-in shell (same level as ReauthOverlay — see
// lib/ui/reauth/reauth_overlay.dart for the established pattern of wrapping
// `child` rather than editing it) so the hotkey works regardless of which
// pane currently has focus:
//
//   SnapshotHotkey(child: WallShell(...))
//
// This only wires the *hotkey*. The toolbar button (`SnapshotToolbarButton`
// below) is separate so it can be dropped into the existing toolbar without
// needing this wrapper.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/snapshot_service.dart';
import '../../state/client_options.dart';
import '../../state/keyboard_shortcuts.dart';
import '../hotkeys/hotkey_gate.dart';

/// Wires the "S" hotkey to a snapshot of the active pane, from any tab and
/// wherever keyboard focus currently sits.
///
/// It was a `Focus.onKeyEvent` node ("bubble phase", so a focused text field
/// would swallow the key first). That reasoning was sound but the placement
/// was not: this widget is mounted BELOW the app root's `FullscreenEscHandler`
/// (`autofocus: true`), which permanently holds the route scope's focus, and
/// Flutter dispatches only to the focused node and its ANCESTORS — so this
/// node was never on the chain and S never fired at all. It is now a
/// `HardwareKeyboard` handler, which runs for every key event independent of
/// focus, with the guards it used to inherit re-applied explicitly (see
/// hotkey_gate.dart): no typing, no pushed route, no suppressed overlay, and
/// the master "keyboard shortcuts" toggle ([ClientOptionsStore.hotkeysEnabled])
/// still turns it off.
///
/// One instance, at the signed-in shell (see main.dart). Screens must NOT also
/// pass `onSnapshot` to their `GlobalHotkeysListener` — every registered
/// hardware handler runs for every event, so both would fire.
class SnapshotHotkey extends StatefulWidget {
  const SnapshotHotkey({
    super.key,
    required this.child,
    this.options,
    this.shortcuts,
  });

  final Widget child;

  /// Read live at key-press time so toggling the setting takes effect
  /// immediately (no rebuild needed).
  final ClientOptionsStore? options;

  /// Remapped snapshot binding (Keyboard Shortcuts settings). Read live at
  /// key-press time like [options]; null → the default S.
  final KeyboardShortcutsStore? shortcuts;

  @override
  State<SnapshotHotkey> createState() => _SnapshotHotkeyState();
}

class _SnapshotHotkeyState extends State<SnapshotHotkey> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;
    if (event.logicalKey !=
        (widget.shortcuts?.keyFor(ShortcutAction.snapshot) ??
            LogicalKeyboardKey.keyS)) {
      return false;
    }
    // Ctrl+S / Alt+S / Win+S belong to whoever owns that chord.
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      return false;
    }
    if (hotkeyContextBlocked(context)) return false;
    if (shortcutsDisabled(widget.options)) return false;
    SnapshotService.captureActivePane(context);
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Toolbar button, old client: `#toolbar-snapshot-btn`
/// (apps/desktop/src/app.js:6448). Drop next to the existing toolbar
/// buttons (mute, fullscreen, etc.).
class SnapshotToolbarButton extends StatelessWidget {
  const SnapshotToolbarButton({super.key, this.shortcuts});

  /// Names the current snapshot key in the tooltip; null → the default S.
  final KeyboardShortcutsStore? shortcuts;

  @override
  Widget build(BuildContext context) {
    final key = shortcuts?.keyFor(ShortcutAction.snapshot) ??
        LogicalKeyboardKey.keyS;
    return IconButton(
      tooltip: 'Snapshot active pane (${shortcutKeyLabel(key)})',
      icon: const Icon(Icons.camera_alt_outlined),
      onPressed: () => SnapshotService.captureActivePane(context),
    );
  }
}
