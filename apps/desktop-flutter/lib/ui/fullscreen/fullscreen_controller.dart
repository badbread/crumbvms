// Chrome-less fullscreen "camera wall" — port of the Tauri client's
// cameras-only fullscreen (apps/desktop/src/app.js `setCamerasFullscreen` /
// `toggleCamerasFullscreen`, backed by the Rust `set_window_fullscreen`
// command in apps/desktop/src-tauri/src/lib.rs:1262, which just called
// `window.set_fullscreen(on)`).
//
// In the Tauri client this toggled the OS window's fullscreen state AND
// hid the app's own top bar + toolbar chrome, leaving only the camera
// tiles filling the screen; Esc exited fullscreen before anything else
// bound to Esc (see `handleKeyDown`, app.js:4114). The Flutter port keeps
// the same split: `FullscreenController` owns ONLY the OS-window
// fullscreen state (via window_manager, the Flutter equivalent of the
// Tauri `window.set_fullscreen` call) and exposes it as a `ChangeNotifier`
// so a screen can drive its own chrome show/hide off `isFullscreen`.
//
// This file intentionally does not touch server state — fullscreen is a
// pure client/window concern, same as the old client.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Owns the OS-window fullscreen ("camera wall") state for the desktop
/// client and keeps it in sync if the window leaves fullscreen through a
/// path we didn't initiate (OS shortcut, window-manager gesture, etc.).
///
/// Usage: create one instance near the app root (it must outlive any
/// screen that reads it), call [attach] once `window_manager` is
/// initialized, and feed [isFullscreen] to whatever screen hides its own
/// chrome (top bar / toolbar) when true — mirroring the old client's
/// `document.body.classList.toggle('cameras-fullscreen', on)`.
class FullscreenController extends ChangeNotifier with WindowListener {
  bool _isFullscreen = false;
  bool _attached = false;

  bool get isFullscreen => _isFullscreen;

  /// Start listening for OS-driven fullscreen changes. Safe to call once;
  /// no-op on repeat calls.
  void attach() {
    if (_attached) return;
    _attached = true;
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (_attached) windowManager.removeListener(this);
    super.dispose();
  }

  /// Sets the OS window's fullscreen state and hides/restores chrome.
  /// Equivalent to the old client's `setCamerasFullscreen(on)`.
  Future<void> setFullscreen(bool on) async {
    if (on == _isFullscreen) return;
    _isFullscreen = on;
    notifyListeners();
    try {
      await windowManager.setFullScreen(on);
    } catch (_) {
      // Best-effort, same as the old client's `.catch(() => {})` around the
      // `invoke('set_window_fullscreen', ...)` call — never let a window-
      // manager failure crash the wall.
    }
    if (!on) {
      // Robust exit (#86). On Windows, `setFullScreen(false)` can leave the
      // window OFF the taskbar and without focus — an uninteractable "ghost"
      // the user can't recover without Win+D or killing the process
      // (reported after launch-into-fullscreen + Esc). Force the window back
      // to a normal, visible, focused, taskbar-present state. Each step is
      // independently best-effort so one failing plugin call can't re-strand
      // the window: getting even one of show/focus/taskbar through is enough
      // to avoid the ghost.
      for (final step in <Future<void> Function()>[
        () => windowManager.setSkipTaskbar(false),
        () => windowManager.show(),
        () => windowManager.focus(),
      ]) {
        try {
          await step();
        } catch (_) {
          /* best-effort — keep trying the remaining steps */
        }
      }
    }
  }

  Future<void> toggle() => setFullscreen(!_isFullscreen);

  // ── WindowListener callbacks ────────────────────────────────────────────
  // Keep our notion of fullscreen in sync if the OS/window manager takes the
  // window out of fullscreen behind our back (e.g. a native fullscreen
  // shortcut). The old client never needed this because Tauri's
  // `set_window_fullscreen` was the only path in or out; window_manager on
  // desktop can have others.
  @override
  void onWindowEnterFullScreen() {
    if (!_isFullscreen) {
      _isFullscreen = true;
      notifyListeners();
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    if (_isFullscreen) {
      _isFullscreen = false;
      notifyListeners();
    }
  }
}

/// Wraps [child] so pressing Esc exits the camera-wall fullscreen — mirrors
/// `handleKeyDown`'s top-priority Esc handler (app.js:4114): "leave the
/// fullscreen camera wall first (before un-maximizing)". Put this ABOVE any
/// other Esc handling (e.g. exiting a maximized tile) in the widget tree so
/// fullscreen wins first, matching the old client's ordering.
///
/// Ignores Esc while focus is inside a text field, same as the old client's
/// `if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;`
/// guard (Flutter's focus system handles routing text-field keys to the
/// field itself before this reaches a Shortcuts/Actions boundary higher up,
/// but the explicit check here keeps the intent obvious and matches the old
/// client's early-return shape).
class FullscreenEscHandler extends StatelessWidget {
  const FullscreenEscHandler({
    super.key,
    required this.controller,
    required this.child,
  });

  final FullscreenController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey != LogicalKeyboardKey.escape) {
              return KeyEventResult.ignored;
            }
            final focused = FocusManager.instance.primaryFocus;
            if (focused?.context?.widget is EditableText) {
              return KeyEventResult.ignored;
            }
            if (!controller.isFullscreen) return KeyEventResult.ignored;
            controller.setFullscreen(false);
            return KeyEventResult.handled;
          },
          child: child,
        );
      },
    );
  }
}

/// Toolbar button mirroring `toolbar-fullscreen-btn` (app.js): toggles the
/// camera-wall fullscreen and shows an "active" state while engaged.
class FullscreenToggleButton extends StatelessWidget {
  const FullscreenToggleButton({super.key, required this.controller});

  final FullscreenController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final on = controller.isFullscreen;
        return IconButton(
          tooltip: on ? 'Exit fullscreen' : 'Fullscreen camera wall',
          icon: Icon(on ? Icons.fullscreen_exit : Icons.fullscreen),
          color: on ? Colors.cyanAccent : Colors.white70,
          onPressed: controller.toggle,
        );
      },
    );
  }
}
