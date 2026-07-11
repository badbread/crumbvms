// Speaker toggle button + M-hotkey wiring for play-on-focus audio on the live
// wall. Ports app.js `updateAudioButton` (app.js:3482) and the `M` case in
// `handleKeyDown` (app.js:4137-4141), both of which just call
// `toggleActiveAudio()` (app.js:3471) against the shared
// AudioFollowController state machine in
// lib/services/audio_follow_controller.dart.

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/services/audio_follow_controller.dart';

/// Speaker icon button. Tap toggles master audio for the active (maximized
/// else selected) camera. Mirrors `updateAudioButton`'s icon/label swap —
///🔊 vs 🔇 there, `volume_up`/`volume_off` here since this is a native
/// Flutter icon button rather than an emoji glyph.
class AudioToggleButton extends StatelessWidget {
  const AudioToggleButton({
    super.key,
    required this.controller,
    this.onNoActiveCamera,
  });

  final AudioFollowController controller;

  /// Called when a toggle attempt is rejected because the active tile has no
  /// playable camera — mirrors app.js's `setStatus('No camera in the
  /// selected tile')` (app.js:3474). Wire this to your own status/toast UI.
  final VoidCallback? onNoActiveCamera;

  Future<void> _toggle() async {
    final ok = await controller.toggleAudio();
    if (!ok) onNoActiveCamera?.call();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final on = controller.audioOn;
        return Tooltip(
          message: on
              ? 'Audio on (M to mute) — follows selected camera'
              : 'Audio off (M to unmute selected camera)',
          child: Material(
            color: on
                ? Colors.cyanAccent.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.55),
            shape: const CircleBorder(),
            child: IconButton(
              icon: Icon(
                on ? Icons.volume_up : Icons.volume_off,
                color: on ? Colors.cyanAccent : Colors.white70,
              ),
              iconSize: 20,
              tooltip: null, // Tooltip widget above already provides this
              onPressed: _toggle,
            ),
          ),
        );
      },
    );
  }
}

/// Wraps [child] with a focus node that handles the `M` hotkey to toggle
/// audio for the active camera. Mirrors `handleKeyDown`'s guard of ignoring
/// keystrokes while an `<input>`/`<textarea>` has focus (app.js:4108) — here
/// that's approximated by ignoring `M` while an [EditableText] (any
/// TextField/TextFormField) holds primary focus.
///
/// Place this once near the root of the live-wall screen (it should wrap the
/// whole wall, not an individual tile) so `M` works regardless of which
/// child widget last had focus.
class AudioHotkeyListener extends StatelessWidget {
  const AudioHotkeyListener({
    super.key,
    required this.controller,
    required this.child,
    this.onNoActiveCamera,
    this.autofocus = true,
  });

  final AudioFollowController controller;
  final Widget child;
  final VoidCallback? onNoActiveCamera;

  /// Whether this node should grab keyboard focus itself. Set to false if
  /// something else in the tree already autofocuses (only one autofocus
  /// root should exist per screen).
  final bool autofocus;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final focused = FocusManager.instance.primaryFocus;
    final focusedContext = focused?.context;
    if (focusedContext != null &&
        focusedContext.widget is EditableText) {
      return KeyEventResult.ignored; // typing in a text field — app.js:4108
    }

    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      unawaited(_toggle());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _toggle() async {
    final ok = await controller.toggleAudio();
    if (!ok) onNoActiveCamera?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: autofocus,
      onKeyEvent: _handleKey,
      child: child,
    );
  }
}
