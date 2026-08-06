// The "H" hotkey for the global hide-Home-Assistant-overlays toggle
// ([HaOverlayPrefs]) — the keyboard twin of the wall toolbar's sensor button.
//
// WHY THIS IS NOT JUST A BRANCH IN [GlobalHotkeysListener]: that widget is a
// `Focus.onKeyEvent` node mounted deep inside the live wall, and Flutter
// dispatches a key event ONLY to the primary-focus node and its ANCESTORS. On
// this app the primary focus sits at the app root: `FullscreenEscHandler`
// (main.dart, `autofocus: true`, built first) claims the route scope's
// `focusedChild`, and a scope applies at most one autofocus request
// (`_Autofocus.applyIfValid` bails once `scope.focusedChild != null`), so the
// wall listener's own `autofocus: true` is discarded. Its node is therefore a
// DESCENDANT of the focused node, never an ancestor — off the dispatch chain,
// its `onKeyEvent` never runs. Nothing on the wall hands it focus later
// either: the tiles are `Listener`/`GestureDetector`, which take no keyboard
// focus. That is why H did nothing on the wall and in the maximized pane while
// the toolbar button worked.
//
// `HardwareKeyboard` handlers are the way out, and the pattern this app
// already uses for exactly this problem (the clip player's Esc in
// clips_screen.dart, the plates screen, main.dart's Shift-hints layer):
// `KeyEventManager` invokes EVERY registered handler for every key event,
// before and independent of focus dispatch. The trade-off is that the focus
// chain's natural guards (a text field or a shortcut-capture box swallowing
// the key first) no longer apply, so this widget re-checks them itself.
//
// Mount it around the live wall — one instance, for the lifetime of the Live
// tab (Playback/Clips draw no HA badges). It registers on mount and
// unregisters on dispose, so the key is inert on every other tab.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';

/// Wires the HA-overlay toggle key (default `H`, remappable) to [onToggle],
/// regardless of where keyboard focus currently sits.
class HaOverlayHotkey extends StatefulWidget {
  const HaOverlayHotkey({
    super.key,
    required this.child,
    required this.onToggle,
    this.options,
    this.shortcuts,
  });

  final Widget child;

  /// What the key does — the live wall passes `HaOverlayPrefs.instance.toggle`.
  final VoidCallback onToggle;

  /// The master "Enable keyboard shortcuts" switch. Read live at key-press
  /// time so flipping it takes effect immediately. Null → shortcuts on.
  final ClientOptionsStore? options;

  /// Remapped binding (Keyboard Shortcuts settings). Read live at key-press
  /// time like [options]; null → the default `H`.
  final KeyboardShortcutsStore? shortcuts;

  @override
  State<HaOverlayHotkey> createState() => _HaOverlayHotkeyState();
}

class _HaOverlayHotkeyState extends State<HaOverlayHotkey> {
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

  /// Returns true only for the press it actually consumed — every other key
  /// (and every guarded case) falls through to the normal focus dispatch.
  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    final bound =
        widget.shortcuts?.keyFor(ShortcutAction.haOverlayToggle) ??
        LogicalKeyboardKey.keyH;
    if (event.logicalKey != bound) return false;

    // Modified presses belong to whatever owns Ctrl/Alt/Win chords, not here.
    // (Shift is allowed: a bare letter binding fires as "H" either way.)
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      return false;
    }

    // The guards the focus chain would have applied for us:
    // typing an "h" into a label/search field must never toggle overlays…
    if (hotkeyContextBlocked()) return false;
    // …a pushed route (dialog, picker, the bookmarks/config-view screens) owns
    // the keyboard while it's up…
    if (Navigator.maybeOf(context)?.canPop() ?? false) return false;
    // …and the master shortcuts switch turns every shortcut off.
    if (!(widget.options?.hotkeysEnabled ?? true)) return false;

    // Deliberate: this still fires while the HA overlay EDITOR is open. The
    // editor force-shows the badges so they stay placeable (wall_screen.dart's
    // edit branch is not gated on the flag), so a press there is a
    // toggle-after-close — the new state shows the moment the editor is
    // dismissed, rather than yanking the badges out from under the editing
    // session.
    widget.onToggle();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
