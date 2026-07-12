// Playback-specific keyboard shortcuts: Space (play/pause), Left/Right arrow
// (shift the visible window +/- 30s), , / . (jump to previous/next motion
// event), Shift+, / Shift+. (frame step back/forward), S (snapshot), Esc
// (exit a maximized playback tile).
//
// Port of app.js `pbHandleKey` (app.js:8165-8203). Only wire this widget
// where playback is actually the active view (e.g. inside the Playback
// tab's screen) — it has no notion of "is playback visible" itself, unlike
// the old client's single global listener that checked
// `els.viewPlayback.classList.contains('hidden')` up front (app.js:8167);
// here that's just "is this widget in the tree", so mount/unmount it with
// the tab instead of gating on a boolean.
//
// All callbacks are optional; a key with no matching callback is a no-op
// (ignored, so it still bubbles for anything above/below to use).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';

bool _focusedIsTextField() {
  final focused = FocusManager.instance.primaryFocus;
  return focused?.context?.widget is EditableText;
}

/// Wraps [child] with the playback-transport shortcuts. Mount this only
/// while playback is the active tab/screen.
class PlaybackHotkeysListener extends StatelessWidget {
  const PlaybackHotkeysListener({
    super.key,
    required this.child,
    this.isMaximized = false,
    this.onTogglePlay,
    this.onShiftWindow,
    this.onPrevMotion,
    this.onNextMotion,
    this.onFrameStep,
    this.onSnapshot,
    this.onExitMaximize,
    this.autofocus = false,
    this.shortcuts,
    this.options,
  });

  final Widget child;

  /// Remapped action-shortcut bindings — only the snapshot key applies here
  /// (the transport keys are inherent, not remappable). Null → default S.
  final KeyboardShortcutsStore? shortcuts;

  /// Master "Enable keyboard shortcuts" toggle: gates the snapshot ACTION
  /// key. The transport keys (Space/arrows/,/. and Esc) are inherent playback
  /// controls, not shortcuts, and stay live. Null → shortcuts on.
  final ClientOptionsStore? options;

  /// Whether a playback tile is currently maximized — controls what Esc
  /// does (app.js:8173-8178: only handled while a tile is maximized).
  final bool isMaximized;

  /// Space — play/pause. (app.js:8179-8181, `pbTogglePlay`.)
  final VoidCallback? onTogglePlay;

  /// Left/Right arrow — shift the visible window by the given signed
  /// duration (-30s / +30s). (app.js:8182-8187, `pbShiftWindow`.)
  final void Function(Duration by)? onShiftWindow;

  /// , (comma) — jump to the previous motion event. (app.js:8188-8189,
  /// `pbPrevMotion`.)
  final VoidCallback? onPrevMotion;

  /// . (period) — jump to the next motion event. (app.js:8190-8191,
  /// `pbNextMotion`.)
  final VoidCallback? onNextMotion;

  /// Shift+, / Shift+. — step one frame back/forward. `forward` is true
  /// for Shift+. (app.js:8192-8199, `pbFrameStep`.)
  final void Function(bool forward)? onFrameStep;

  /// S — snapshot the active pane. (app.js:8200-8202, shared with the
  /// global `snapshotActivePane`.)
  final VoidCallback? onSnapshot;

  /// Esc while a tile is maximized — restore the playback grid.
  /// (app.js:8173-8178.)
  final VoidCallback? onExitMaximize;

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (_focusedIsTextField()) return KeyEventResult.ignored;

        if (event.logicalKey == LogicalKeyboardKey.escape) {
          if (isMaximized && onExitMaximize != null) {
            onExitMaximize!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        if (event.logicalKey == LogicalKeyboardKey.space) {
          if (onTogglePlay != null) {
            onTogglePlay!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          if (onShiftWindow != null) {
            onShiftWindow!(const Duration(seconds: -30));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (onShiftWindow != null) {
            onShiftWindow!(const Duration(seconds: 30));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Comma/period carry frame-step (Shift) vs motion-jump (plain) on
        // the SAME physical key, exactly like app.js distinguishing ','/'.'
        // from the shifted '<'/'>' via `e.key`. HardwareKeyboard's shift
        // state is checked directly rather than relying on the shifted
        // logical-key glyph, so this works across keyboard layouts.
        final shiftDown = HardwareKeyboard.instance.isShiftPressed;
        if (event.logicalKey == LogicalKeyboardKey.comma) {
          if (shiftDown) {
            if (onFrameStep != null) {
              onFrameStep!(false);
              return KeyEventResult.handled;
            }
          } else if (onPrevMotion != null) {
            onPrevMotion!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        if (event.logicalKey == LogicalKeyboardKey.period) {
          if (shiftDown) {
            if (onFrameStep != null) {
              onFrameStep!(true);
              return KeyEventResult.handled;
            }
          } else if (onNextMotion != null) {
            onNextMotion!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        // Snapshot (default S) — remappable; inert while the master
        // "Enable keyboard shortcuts" toggle is off.
        if (event.logicalKey ==
            (shortcuts?.keyFor(ShortcutAction.snapshot) ??
                LogicalKeyboardKey.keyS)) {
          if (onSnapshot != null && (options?.hotkeysEnabled ?? true)) {
            onSnapshot!();
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
