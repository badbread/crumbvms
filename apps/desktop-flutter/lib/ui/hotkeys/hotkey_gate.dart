// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The shared guard rails for every "always fires" hotkey in this app — the
// ones registered on `HardwareKeyboard.addHandler` rather than a
// `Focus.onKeyEvent` node.
//
// WHY THIS EXISTS. Flutter dispatches a key event to `primaryFocus` and its
// ANCESTORS only. On this app the app root (`FullscreenEscHandler`,
// `autofocus: true`, built first) permanently owns the route scope's
// `focusedChild` — a scope applies at most one autofocus request
// (`_Autofocus.applyIfValid` bails once `scope.focusedChild != null`) — so any
// `Focus.onKeyEvent` listener mounted BELOW it is off the dispatch chain and
// its handler never runs. That is what made the whole live-wall shortcut set
// (S / M / F8 / the camera number banks / Esc) inert in the shipped client.
// The repair is to register on `HardwareKeyboard`, which invokes every
// registered handler for every key event, independent of focus.
//
// The cost of leaving the focus chain is that its natural guards leave with
// it, so each handler has to re-apply them itself — and, because
// `KeyEventManager` runs the focus dispatch *unconditionally* after the
// hardware handlers (`_dispatchKeyMessage` is not gated on the handlers'
// return value, hardware_keyboard.dart), returning true does NOT stop a
// focused text field from also receiving the key. The text-focus check below
// is therefore the ONLY thing standing between an operator typing a camera
// name and the wall jumping cameras under them. Every hardware hotkey calls
// [hotkeyContextBlocked] first; nothing else is a substitute.

import 'package:flutter/widgets.dart';

import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/ui/hotkeys/text_focus.dart';

/// Number of [HotkeySuppressor]s currently mounted. A depth counter, not a
/// bool, so nested/overlapping suppressors compose.
int _suppressDepth = 0;

/// True while any [HotkeySuppressor] is mounted.
bool get hotkeysSuppressed => _suppressDepth > 0;

/// Mount around an in-tree overlay that owns the keyboard while it is up but
/// is NOT a pushed route — the floating Settings panel and the re-auth
/// overlay, both of which render in a `Stack` over the still-mounted Live tab
/// (so the wall's hotkeys are still registered underneath them, and
/// `Navigator.canPop()` is false).
///
/// Without this, pressing a key in the Keyboard Shortcuts capture box would
/// both record the binding AND fire the shortcut behind the panel.
class HotkeySuppressor extends StatefulWidget {
  const HotkeySuppressor({super.key, required this.child});

  final Widget child;

  @override
  State<HotkeySuppressor> createState() => _HotkeySuppressorState();
}

class _HotkeySuppressorState extends State<HotkeySuppressor> {
  @override
  void initState() {
    super.initState();
    _suppressDepth++;
  }

  @override
  void dispose() {
    _suppressDepth--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// True when NO hotkey may fire right now, Esc included: a text input holds
/// focus (typing must never drive the wall), a route is pushed on top (a
/// dialog/picker/full-screen settings surface owns the keyboard), or a
/// [HotkeySuppressor] is mounted.
///
/// Deliberately covers Esc too. The focus-chain listeners this replaces
/// checked Esc *before* their text-focus guard, but they could afford to: a
/// focused field saw the key first and swallowed it. A hardware handler has no
/// such ordering, so exempting Esc would steal it from the field/dropdown that
/// wants it. Nothing is trapped by this: the field loses focus and the next
/// Esc lands.
bool hotkeyContextBlocked(BuildContext context) {
  if (hotkeysSuppressed) return true;
  if (textInputHasFocus()) return true;
  if (Navigator.maybeOf(context)?.canPop() ?? false) return true;
  return false;
}

/// The master "Enable keyboard shortcuts" switch
/// ([ClientOptionsStore.hotkeysEnabled]), read live at key-press time. Null →
/// shortcuts on.
///
/// Checked SEPARATELY from [hotkeyContextBlocked] because the two aren't the
/// same question: Esc (restore from maximize) and the overlay editors' Ctrl+Z
/// deliberately ignore this switch — they're escape hatches and editor
/// controls, not "shortcuts", and turning them off would trap the user.
bool shortcutsDisabled(ClientOptionsStore? options) =>
    !(options?.hotkeysEnabled ?? true);
