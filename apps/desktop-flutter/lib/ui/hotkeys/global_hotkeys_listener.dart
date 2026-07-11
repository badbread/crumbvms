// Global keyboard shortcuts: F8 (perf HUD), S (snapshot), M (toggle audio),
// Esc (restore maximize), and the 1-9/0 + Shift+1-9/0 "go to camera" keys.
//
// Port of app.js `handleKeyDown` (app.js:4106-4151). Follows the same
// Focus/onKeyEvent shape already established by
// lib/ui/fullscreen/fullscreen_controller.dart's `FullscreenEscHandler` —
// put THAT widget ABOVE this one in the tree (fullscreen-exit must win over
// un-maximize on Esc, same ordering as app.js:4113-4129) and this one around
// whatever body hosts the live wall. All callbacks are optional so a screen
// that doesn't support a given action (e.g. no snapshot plugin wired up yet)
// can simply omit it — the key is then a no-op instead of a crash.
//
// Ignores every key while a text field has focus, matching app.js's
// `e.target.tagName === 'INPUT' || 'TEXTAREA'` guard (app.js:4108).
//
// NOTE on overlap: `S` and `M` already have dedicated, independently-ported
// widgets elsewhere in this app — lib/ui/snapshot/snapshot_hotkey.dart
// (`SnapshotHotkey` -> `SnapshotService.captureActivePane`) and
// lib/ui/audio/audio_toggle_button.dart (`AudioHotkeyListener` ->
// `AudioFollowController.toggleAudio()`). If those are already wired into
// the screen, leave [onSnapshot] / [onToggleAudio] null here so the key
// isn't handled twice by two separate Focus nodes — this widget's S/M hooks
// exist only so a screen that has NOT adopted those dedicated widgets still
// gets S/M as part of one unified listener alongside F8/Esc/digits.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';

/// A keydown -> hotkey token ("3", "s3"), or null. Plain digit or
/// Shift+digit only, using the PHYSICAL key (independent of layout/shift
/// symbol) — the Flutter equivalent of app.js's `e.code`-based
/// `hotkeyTokenFromEvent` (app.js:4031), so Shift+1 (which types "!" on a US
/// keyboard) still resolves to digit 1.
String? _hotkeyTokenFromEvent(KeyEvent event) {
  final keys = HardwareKeyboard.instance;
  if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
    return null;
  }
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

bool _focusedIsTextField() {
  final focused = FocusManager.instance.primaryFocus;
  return focused?.context?.widget is EditableText;
}

/// Wraps [child] with the global number-key/HUD/snapshot/audio/escape
/// shortcuts. [cameras] should be the current viewer-visible camera list
/// (same list the wall builds tiles from) — pass a live/rebuilt list so the
/// auto hotkey assignment stays in sync with `hotkeysAuto`.
class GlobalHotkeysListener extends StatelessWidget {
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
    this.autofocus = false,
  });

  final HotkeyConfigStore store;
  final List<Camera> cameras;
  final Widget child;

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

  /// Esc — restore from maximize (only reached if nothing above this widget
  /// in the tree — e.g. `FullscreenEscHandler` — already consumed the Esc).
  /// (app.js:4121-4129.)
  final VoidCallback? onEscape;

  /// Whether this Focus node should grab focus immediately. Leave false if
  /// an ancestor `Focus`/`FullscreenEscHandler` already autofocuses — only
  /// one autofocus is needed per screen.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (_focusedIsTextField()) return KeyEventResult.ignored;

        // F8: toggle the live performance HUD footer.
        if (event.logicalKey == LogicalKeyboardKey.f8) {
          if (onHudToggle != null) {
            onHudToggle!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Esc: restore from maximize.
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          if (onEscape != null) {
            onEscape!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // S: snapshot the active pane.
        if (event.logicalKey == LogicalKeyboardKey.keyS) {
          if (onSnapshot != null) {
            onSnapshot!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // M: toggle audio for the active camera.
        if (event.logicalKey == LogicalKeyboardKey.keyM) {
          if (onToggleAudio != null) {
            onToggleAudio!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Number keys: "go to" the assigned camera. Remappable via
        // HotkeyConfigStore / HotkeyRemapScreen.
        final token = _hotkeyTokenFromEvent(event);
        if (token != null) {
          final camId = store.cameraForToken(cameras, token);
          if (camId != null && onGoToCamera != null) {
            onGoToCamera!(camId);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
