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

/// Wires the "S" hotkey to a snapshot of the active pane.
///
/// This is a BUBBLE-PHASE handler (a plain `Focus.onKeyEvent`, not a
/// `Shortcuts`/`SingleActivator`): the focused widget sees the key FIRST, so
/// - typing an "s" into a text field (a password, a search box, …) is consumed
///   by that field and never reaches here — the old `Shortcuts` binding fired
///   on bare "s" even while typing, which stole keystrokes from the password
///   field; and
/// - a per-screen S handler (the live wall / playback) that already acted on
///   the key isn't double-fired.
///
/// It also respects the "keyboard shortcuts" toggle ([ClientOptionsStore.
/// hotkeysEnabled]) — with shortcuts off, S does nothing — and re-checks that no
/// text field holds focus, belt-and-suspenders.
class SnapshotHotkey extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false, // never steal focus; just observe bubbled keys
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey !=
            (shortcuts?.keyFor(ShortcutAction.snapshot) ??
                LogicalKeyboardKey.keyS)) {
          return KeyEventResult.ignored;
        }
        if (!(options?.hotkeysEnabled ?? true)) return KeyEventResult.ignored;
        final focused = FocusManager.instance.primaryFocus;
        if (focused?.context?.widget is EditableText) {
          return KeyEventResult.ignored;
        }
        SnapshotService.captureActivePane(context);
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
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
