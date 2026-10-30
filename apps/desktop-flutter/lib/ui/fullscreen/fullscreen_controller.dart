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

import 'dart:async' show scheduleMicrotask;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:crumb_desktop/ui/hotkeys/text_focus.dart';

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

  /// The native transition currently in flight, if any. On Windows a single
  /// `setFullScreen` is a SEQUENCE of window resizes (window_manager maximizes,
  /// then restyles + repositions; leaving restores, restyles, repositions and
  /// refreshes the child view), and the Flutter embedder blocks the platform
  /// thread on each of them until a frame of the new size is presented. A
  /// second request landing mid-sequence (F11 bounce, double-click on the
  /// toolbar button, Esc right after F11) would interleave two of those
  /// sequences; they are serialized here instead.
  Future<void>? _transition;

  /// Sets the OS window's fullscreen state and hides/restores chrome.
  /// Equivalent to the old client's `setCamerasFullscreen(on)`.
  ///
  /// The Flutter-side state (and the chrome show/hide it drives) flips at once;
  /// the OS window follows. Requests are applied in order, one native
  /// transition at a time.
  Future<void> setFullscreen(bool on) async {
    if (on == _isFullscreen) return;
    _isFullscreen = on;
    notifyListeners();
    final previous = _transition;
    final mine = _applyNative(previous, on);
    _transition = mine;
    await mine;
    if (identical(_transition, mine)) _transition = null;
  }

  Future<void> _applyNative(Future<void>? previous, bool on) async {
    if (previous != null) await previous;
    // Superseded while queued (toggled back before the window moved): the
    // later request's own transition applies the final state; skip this one.
    if (on != _isFullscreen) return;
    try {
      await windowManager.setFullScreen(on);
    } catch (_) {
      // Best-effort, same as the old client's `.catch(() => {})` around the
      // `invoke('set_window_fullscreen', ...)` call — never let a window-
      // manager failure crash the wall. (Do NOT chain extra window_manager
      // calls like setSkipTaskbar/show/focus right after setFullScreen(false):
      // an earlier attempt to do that closed the app on Esc-exit from a
      // launch-fullscreen wall — a native crash during the exit transition
      // that a Dart try/catch can't stop. The real launch white-box fix lives
      // in applyLaunchFullscreenPreference, not here.)
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
class FullscreenEscHandler extends StatefulWidget {
  const FullscreenEscHandler({
    super.key,
    required this.controller,
    required this.child,
  });

  final FullscreenController controller;
  final Widget child;

  @override
  State<FullscreenEscHandler> createState() => _FullscreenEscHandlerState();
}

class _FullscreenEscHandlerState extends State<FullscreenEscHandler> {
  @override
  void initState() {
    super.initState();
    // The Focus.onKeyEvent below only sees keys while primary focus is this
    // node or a DESCENDANT. Clicking the toolbar's fullscreen button and then
    // hiding the toolbar disposes the focused button, which parks primary
    // focus on the route's FocusScope, an ANCESTOR of this node, so Esc never
    // reached it and the operator was trapped in fullscreen. A HardwareKeyboard
    // handler fires regardless of focus (see hotkey_gate.dart).
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    final key = event.logicalKey;
    final isEsc = key == LogicalKeyboardKey.escape;
    final isF11 = key == LogicalKeyboardKey.f11;
    if (!isEsc && !isF11) return false;
    // Typing owns the keyboard (Esc / F11 in a field is the field's).
    if (textInputHasFocus()) return false;
    // A dialog / menu on top owns its own Esc.
    if (isEsc && (Navigator.maybeOf(context)?.canPop() ?? false)) return false;
    final c = widget.controller;
    if (isEsc && !c.isFullscreen) return false;
    // Deferred to a microtask so other handlers for this same key press (the
    // wall's / Playback's own Esc, which check `isFullscreen` to give leaving
    // fullscreen priority) still see the state as it was. Not consumed.
    scheduleMicrotask(() {
      if (isF11) {
        c.toggle();
      } else if (c.isFullscreen) {
        c.setFullscreen(false);
      }
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
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
            if (textInputHasFocus()) {
              return KeyEventResult.ignored;
            }
            if (!controller.isFullscreen) return KeyEventResult.ignored;
            controller.setFullscreen(false);
            return KeyEventResult.handled;
          },
          child: widget.child,
        );
      },
    );
  }
}

/// A safety-net exit control for the fullscreen wall: invisible until the
/// pointer enters the top-right corner, then a button that leaves fullscreen.
/// Place it in a [Stack] over the wall; renders nothing when not fullscreen.
class FullscreenExitCorner extends StatefulWidget {
  const FullscreenExitCorner({super.key, required this.controller});

  final FullscreenController controller;

  @override
  State<FullscreenExitCorner> createState() => _FullscreenExitCornerState();
}

class _FullscreenExitCornerState extends State<FullscreenExitCorner> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (!widget.controller.isFullscreen) return const SizedBox.shrink();
        return Positioned(
          top: 0,
          right: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: SizedBox(
              key: const ValueKey('fullscreen-exit-corner'),
              width: 72,
              height: 56,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: _hover ? 1 : 0,
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Material(
                      color: Colors.black87,
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Exit fullscreen (Esc / F11)',
                        icon: const Icon(
                          Icons.fullscreen_exit,
                          color: Colors.white,
                        ),
                        onPressed: _hover
                            ? () => widget.controller.setFullscreen(false)
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
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
