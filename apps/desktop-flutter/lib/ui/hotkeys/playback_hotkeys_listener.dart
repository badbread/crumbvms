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
//
// THIS USED TO BE A `Focus.onKeyEvent` NODE, AND THAT IS WHY NONE OF IT
// WORKED. Flutter dispatches a key event to `primaryFocus` and its ANCESTORS
// only. On this app the app root (`FullscreenEscHandler`, `autofocus: true`,
// built first) permanently owns the route scope's `focusedChild` — a scope
// applies at most one autofocus request (`_Autofocus.applyIfValid` bails once
// `scope.focusedChild != null`) — so this widget's own `autofocus: true` was
// silently discarded and its node sat BELOW the focused one, off the
// dispatch chain. Nothing hands it focus later either: the playback tiles
// are `Listener`/`GestureDetector`, which take no keyboard focus. That is
// why Space/arrows/,/./Esc did nothing here, same root cause as the live
// wall's shortcuts (see global_hotkeys_listener.dart) and the H overlay
// toggle (ha_overlay_hotkey.dart).
//
// It is now a `HardwareKeyboard` handler (registered on mount, removed on
// dispose), the same mechanism every other always-fires hotkey in this app
// uses. The guards the focus chain used to provide are re-applied explicitly
// via [hotkeyContextBlocked] (hotkey_gate.dart) — deliberately including Esc,
// same rationale as the wall listener.
//
// ESC OVERLAP NOTE: while this screen is a clip-originated single-camera
// focus (`PlaybackScreen.onExitFocus` set), Esc-to-leave-focus is owned
// EXCLUSIVELY by main.dart's `_playbackFocusEscHandler` (registered at the
// app-shell level, with its own fullscreen-priority ordering). The playback
// screen's `onExitMaximize` callback is null in that case — see
// playback_screen.dart's `build()` — so the two handlers never both act on
// the same press.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';

/// Wraps [child] with the playback-transport shortcuts. Mount this only
/// while playback is the active tab/screen.
class PlaybackHotkeysListener extends StatefulWidget {
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

  /// Esc while a tile is maximized — restore the playback grid. Null while
  /// this screen is a clip-originated single-camera focus (see the ESC
  /// OVERLAP NOTE above): that case is handled entirely by main.dart instead.
  /// (app.js:8173-8178.)
  final VoidCallback? onExitMaximize;

  @override
  State<PlaybackHotkeysListener> createState() =>
      _PlaybackHotkeysListenerState();
}

class _PlaybackHotkeysListenerState extends State<PlaybackHotkeysListener> {
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

    // Typing, a pushed route (dialog/goto picker/dropdown), or a mounted
    // HotkeySuppressor (the Settings panel / re-auth overlay) — nothing here
    // fires, Esc included. Shared with every other hardware hotkey; see
    // hotkey_gate.dart.
    if (hotkeyContextBlocked(context)) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!widget.isMaximized || widget.onExitMaximize == null) return false;
      widget.onExitMaximize!();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (widget.onTogglePlay == null) return false;
      widget.onTogglePlay!();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (widget.onShiftWindow == null) return false;
      widget.onShiftWindow!(const Duration(seconds: -30));
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (widget.onShiftWindow == null) return false;
      widget.onShiftWindow!(const Duration(seconds: 30));
      return true;
    }

    // Comma/period carry frame-step (Shift) vs motion-jump (plain) on the
    // SAME physical key, exactly like app.js distinguishing ','/'.' from the
    // shifted '<'/'>' via `e.key`. HardwareKeyboard's shift state is checked
    // directly rather than relying on the shifted logical-key glyph, so this
    // works across keyboard layouts.
    final shiftDown = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.comma) {
      if (shiftDown) {
        if (widget.onFrameStep == null) return false;
        widget.onFrameStep!(false);
        return true;
      }
      if (widget.onPrevMotion == null) return false;
      widget.onPrevMotion!();
      return true;
    }

    if (event.logicalKey == LogicalKeyboardKey.period) {
      if (shiftDown) {
        if (widget.onFrameStep == null) return false;
        widget.onFrameStep!(true);
        return true;
      }
      if (widget.onNextMotion == null) return false;
      widget.onNextMotion!();
      return true;
    }

    // Snapshot (default S) — remappable; inert while the master "Enable
    // keyboard shortcuts" toggle is off, unlike the transport keys above.
    if (shortcutsDisabled(widget.options)) return false;
    if (event.logicalKey ==
        (widget.shortcuts?.keyFor(ShortcutAction.snapshot) ??
            LogicalKeyboardKey.keyS)) {
      if (widget.onSnapshot == null) return false;
      widget.onSnapshot!();
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
