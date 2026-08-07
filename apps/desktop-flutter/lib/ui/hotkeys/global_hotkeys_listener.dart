// Global keyboard shortcuts: F8 (perf HUD), S (snapshot), M (toggle audio),
// Esc (restore maximize), and the 1-9/0 + Shift+1-9/0 "go to camera" keys.
// The three action keys (F8/S/M) are the DEFAULTS — a wired-up
// [KeyboardShortcutsStore] (Keyboard Shortcuts settings section) rebinds
// them, and [ClientOptionsStore.hotkeysEnabled] is the master off switch for
// everything except Esc.
//
// Port of app.js `handleKeyDown` (app.js:4106-4151).
//
// THIS USED TO BE A `Focus.onKeyEvent` NODE, AND THAT IS WHY NONE OF IT
// WORKED. Flutter delivers a key event to `primaryFocus` and its ANCESTORS
// only, and the app root (`FullscreenEscHandler`, `autofocus: true`, built
// first) permanently owns the route scope's `focusedChild`, so this widget's
// own `autofocus: true` was silently discarded and its node sat BELOW the
// focused one, off the dispatch chain. Nothing on the wall handed it focus
// later either — the tiles are `Listener`/`GestureDetector`, which take no
// keyboard focus. Every shortcut in here was inert in the shipped client.
//
// It is now a `HardwareKeyboard` handler (registered on mount, removed on
// dispose), the mechanism the H overlay toggle, the clip player's Esc and the
// Shift-hint layer already use: `KeyEventManager` invokes EVERY registered
// handler for every key event, independent of focus. The guards the focus
// chain used to provide are re-applied explicitly via
// [hotkeyContextBlocked] — see hotkey_gate.dart.
//
// ORDERING NOTES, since hardware handlers have no tree to order them:
// - Every registered handler runs for every event; a `true` return marks the
//   event consumed but does NOT stop the other handlers, nor the focus
//   dispatch that follows them. So two handlers claiming the same key both
//   fire. Keep [onSnapshot] null wherever the app-level `SnapshotHotkey` is
//   mounted (it always is, main.dart), and keep [onEscape] null where a
//   screen already has its own hardware Esc handler (the Clips clip player).
// - Esc priority (app.js:4113-4129: leave the fullscreen camera wall first,
//   un-maximize second) used to come from tree position. It now comes from
//   the explicit [fullscreen] check below, which stands this handler down
//   while the OS window is fullscreen so `FullscreenEscHandler` gets the key.
//
// NOTE on overlap: `M` also has a dedicated, independently-ported widget —
// lib/ui/audio/audio_toggle_button.dart (`AudioHotkeyListener` ->
// `AudioFollowController.toggleAudio()`). Don't wire both on one screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';
import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';

/// A keydown -> hotkey token ("3", "s3", "n3"), or null. Uses the PHYSICAL key
/// (independent of layout/shift symbol) — the Flutter equivalent of app.js's
/// `e.code`-based `hotkeyTokenFromEvent` (app.js:4031), so Shift+1 (which types
/// "!" on a US keyboard) still resolves to digit 1. The numeric keypad is its
/// own bank ("n1".."n0"), distinct from the number row, so numpad 1 and row 1
/// can drive different cameras.
String? _hotkeyTokenFromEvent(KeyEvent event) {
  final keys = HardwareKeyboard.instance;
  if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
    return null;
  }
  // Ctrl/Alt/Meta already returned above; the remaining guard is text focus.
  // Numpad bank first — its physical keys are distinct from the digit row.
  // (final, not const: PhysicalKeyboardKey overrides ==, disallowed as a
  // const map key.)
  final numpadKeys = {
    PhysicalKeyboardKey.numpad1: 'n1',
    PhysicalKeyboardKey.numpad2: 'n2',
    PhysicalKeyboardKey.numpad3: 'n3',
    PhysicalKeyboardKey.numpad4: 'n4',
    PhysicalKeyboardKey.numpad5: 'n5',
    PhysicalKeyboardKey.numpad6: 'n6',
    PhysicalKeyboardKey.numpad7: 'n7',
    PhysicalKeyboardKey.numpad8: 'n8',
    PhysicalKeyboardKey.numpad9: 'n9',
    PhysicalKeyboardKey.numpad0: 'n0',
  };
  final numpad = numpadKeys[event.physicalKey];
  if (numpad != null) return numpad;

  final digitKeys = {
    PhysicalKeyboardKey.digit1: '1',
    PhysicalKeyboardKey.digit2: '2',
    PhysicalKeyboardKey.digit3: '3',
    PhysicalKeyboardKey.digit4: '4',
    PhysicalKeyboardKey.digit5: '5',
    PhysicalKeyboardKey.digit6: '6',
    PhysicalKeyboardKey.digit7: '7',
    PhysicalKeyboardKey.digit8: '8',
    PhysicalKeyboardKey.digit9: '9',
    PhysicalKeyboardKey.digit0: '0',
  };
  final digit = digitKeys[event.physicalKey];
  if (digit == null) return null;
  return keys.isShiftPressed ? 's$digit' : digit;
}

/// Wraps [child] with the global number-key/HUD/snapshot/audio/escape
/// shortcuts, live for exactly as long as it is mounted. [cameras] should be
/// the current viewer-visible camera list (same list the wall builds tiles
/// from) — pass a live/rebuilt list so the auto hotkey assignment stays in
/// sync with `hotkeysAuto`.
///
/// Mount ONE of these per screen, and only on screens that are mutually
/// exclusive (Live / Playback / Clips are separate tabs, only one body is
/// built at a time) — two mounted at once means every key fires twice.
class GlobalHotkeysListener extends StatefulWidget {
  const GlobalHotkeysListener({
    super.key,
    required this.store,
    required this.cameras,
    required this.child,
    this.onGoToCamera,
    this.onHudToggle,
    this.onSnapshot,
    this.onToggleAudio,
    this.onEscape,
    this.onUndo,
    this.onRedo,
    this.shortcuts,
    this.options,
    this.fullscreen,
  });

  final HotkeyConfigStore store;
  final List<Camera> cameras;
  final Widget child;

  /// Remapped action-shortcut bindings (Keyboard Shortcuts settings). Read at
  /// key-press time; null → the hardcoded defaults (S / M / F8).
  final KeyboardShortcutsStore? shortcuts;

  /// The master "Enable keyboard shortcuts" toggle
  /// ([ClientOptionsStore.hotkeysEnabled]). When off, every shortcut here is
  /// inert EXCEPT Esc (leaving a maximized pane isn't a "shortcut" — trapping
  /// the user in a maximize would be worse). Null → shortcuts on.
  final ClientOptionsStore? options;

  /// Context-aware "go to camera N": on the Live wall this should maximize
  /// the camera (see [goToCameraOnLiveWall]); on Playback it should load
  /// that camera's timeline. The caller decides which behavior applies
  /// (e.g. based on which tab is currently active) — mirrors app.js
  /// `hotkeyGoToCamera`'s branch on `els.viewPlayback` visibility
  /// (app.js:4066-4073).
  final void Function(String cameraId)? onGoToCamera;

  /// F8 — toggle the live performance HUD footer. (app.js:4111.)
  final VoidCallback? onHudToggle;

  /// S — snapshot the active pane to a file. (app.js:4132-4135,
  /// `snapshotActivePane` at app.js:4154; needs a native save-file path —
  /// wire this to whatever plugin/FRB call the host screen uses.)
  final VoidCallback? onSnapshot;

  /// M — toggle audio for the active camera. (app.js:4138-4141; wire to
  /// `AudioFollowController.toggleAudio()`.)
  final VoidCallback? onToggleAudio;

  /// Esc — restore from maximize. Fires only when the OS window is NOT
  /// fullscreen: the old client left the fullscreen camera wall on the first
  /// Esc and un-maximized on the second (app.js:4113-4129), and [fullscreen]
  /// is how that order is preserved now that both handlers see every key.
  /// (app.js:4121-4129.)
  final VoidCallback? onEscape;

  /// The app's OS-window fullscreen state, used only for the Esc priority
  /// above. Null → this handler takes Esc unconditionally (fine on a screen
  /// that can't be fullscreen).
  final FullscreenController? fullscreen;

  /// Ctrl+Z / Ctrl+Y — undo/redo for the active overlay editor (issue #4).
  /// Only fire while an editor is open; null → no-op. Suppressed while a text
  /// field is focused (so the field gets native text undo).
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  @override
  State<GlobalHotkeysListener> createState() => _GlobalHotkeysListenerState();
}

class _GlobalHotkeysListenerState extends State<GlobalHotkeysListener> {
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

  /// Returns true only for the press it actually acted on; everything else
  /// (and every guarded case) falls through untouched.
  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    // Typing, a pushed route, or a mounted HotkeySuppressor (the Settings
    // panel / re-auth overlay) — nothing here fires, Esc included.
    if (hotkeyContextBlocked(context)) return false;

    final keys = HardwareKeyboard.instance;

    // Esc: restore from maximize. Checked BEFORE the master toggle — turning
    // shortcuts off must not make a maximized pane a trap.
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (widget.onEscape == null) return false;
      // Old-client priority (app.js:4113-4129): the fullscreen camera wall
      // exits first, un-maximize is the NEXT Esc. `FullscreenEscHandler` is a
      // focus-chain node that runs after the hardware handlers on the same
      // event, so standing down here is what hands it the key.
      if (widget.fullscreen?.isFullscreen ?? false) return false;
      widget.onEscape!();
      return true;
    }

    // Ctrl+Z / Ctrl+Y (and Ctrl+Shift+Z) — overlay-editor undo/redo. Editor
    // controls rather than "shortcuts", so they too ignore the master toggle;
    // the callbacks are null unless an editor is actually open.
    if (keys.isControlPressed && !keys.isAltPressed && !keys.isMetaPressed) {
      final isZ = event.logicalKey == LogicalKeyboardKey.keyZ;
      final isY = event.logicalKey == LogicalKeyboardKey.keyY;
      if (isZ && keys.isShiftPressed) {
        if (widget.onRedo != null) {
          widget.onRedo!();
          return true;
        }
      } else if (isZ) {
        if (widget.onUndo != null) {
          widget.onUndo!();
          return true;
        }
      } else if (isY) {
        if (widget.onRedo != null) {
          widget.onRedo!();
          return true;
        }
      }
    }

    // Master "Enable keyboard shortcuts" toggle: everything below — actions
    // AND camera number keys — is inert while it's off.
    if (shortcutsDisabled(widget.options)) return false;

    // The action keys are bare, unmodified presses; a Ctrl/Alt/Win chord
    // belongs to whoever owns that chord. (Shift is allowed — it's how the
    // 11-20 camera bank is reached, and a bare letter binding fires either
    // way.)
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      return false;
    }

    // Perf HUD toggle (default F8) — remappable via KeyboardShortcutsStore.
    if (event.logicalKey ==
        (widget.shortcuts?.keyFor(ShortcutAction.hudToggle) ??
            LogicalKeyboardKey.f8)) {
      if (widget.onHudToggle == null) return false;
      widget.onHudToggle!();
      return true;
    }

    // Snapshot the active pane (default S) — remappable. Null on every
    // current screen; the app-level SnapshotHotkey owns this key.
    if (event.logicalKey ==
        (widget.shortcuts?.keyFor(ShortcutAction.snapshot) ??
            LogicalKeyboardKey.keyS)) {
      if (widget.onSnapshot == null) return false;
      widget.onSnapshot!();
      return true;
    }

    // Toggle audio for the active camera (default M) — remappable.
    if (event.logicalKey ==
        (widget.shortcuts?.keyFor(ShortcutAction.toggleAudio) ??
            LogicalKeyboardKey.keyM)) {
      if (widget.onToggleAudio == null) return false;
      widget.onToggleAudio!();
      return true;
    }

    // Number keys: "go to" the assigned camera. Remappable via
    // HotkeyConfigStore / HotkeyRemapScreen.
    final token = _hotkeyTokenFromEvent(event);
    if (token != null) {
      final camId = widget.store.cameraForToken(widget.cameras, token);
      if (camId != null && widget.onGoToCamera != null) {
        widget.onGoToCamera!(camId);
        return true;
      }
      return false;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
