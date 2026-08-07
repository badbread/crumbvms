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
//
// ── TWO WAYS TO BLOCK, because focus introspection is not always enough ─────
// [textInputHasFocus] answers by walking Flutter's focus tree, and it has a
// documented blind spot (see text_focus.dart): a field given an explicit
// `focusNode:` puts the focused element INSIDE its own `EditableText`, so a
// downward walk finds nothing. That is the shape of the HA badge editor's
// icon-search box, and with the snapshot key now a hardware handler the
// consequence was that typing "spotlights" into it BOTH inserted the text and
// fired a snapshot (PR #495 live test).
//
// So a widget may also DECLARE that it owns the keyboard, via
// [HotkeySuppressor], instead of hoping the focus tree reads correctly. Two
// shapes, one primitive:
//
//   HotkeySuppressor(child: …)                    // while MOUNTED
//   HotkeySuppressor.whileFocused(child: …)       // while the subtree has focus
//
// The first is for an in-tree overlay that owns the keyboard for as long as it
// is up (the floating Settings panel's shortcut-capture box, the re-auth
// prompt). The second wraps an individual TEXT FIELD whose focus the tree walk
// cannot see. Either way the gate treats the declaration and the focus check
// as independent reasons to block — whichever notices first wins.

import 'package:flutter/widgets.dart';

import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/ui/hotkeys/text_focus.dart';

/// Outstanding suppressions. A DEPTH COUNTER, not a bool, so nested and
/// overlapping suppressors compose — two text fields briefly overlap during a
/// focus handoff, and the one letting go must not un-suppress while the other
/// is still typing.
int _suppressDepth = 0;

/// True while any [HotkeySuppressor] is holding the keyboard.
bool get hotkeysSuppressed => _suppressDepth > 0;

/// Take a suppression directly. Returns its release callback, which is
/// idempotent — calling it twice cannot underflow the counter. Prefer
/// [HotkeySuppressor], which cannot leak one.
VoidCallback pushHotkeySuppression() {
  _suppressDepth++;
  var released = false;
  return () {
    if (released) return;
    released = true;
    if (_suppressDepth > 0) _suppressDepth--;
  };
}

/// Visible for tests: drop every outstanding suppression, so one test's
/// teardown cannot leak into the next.
@visibleForTesting
void resetHotkeySuppressionForTest() => _suppressDepth = 0;

/// Declares that this subtree owns the keyboard, so no hardware hotkey fires
/// while it does.
///
/// The default constructor suppresses for as long as the widget is MOUNTED —
/// for an in-tree overlay that is not a pushed route, and so is invisible to
/// the `Navigator.canPop()` check: the floating Settings panel and the re-auth
/// overlay, both of which render in a `Stack` over the still-mounted Live tab
/// (the wall's hotkeys are still registered underneath them). Without this,
/// pressing a key in the Keyboard Shortcuts capture box would both record the
/// binding AND fire the shortcut behind the panel.
///
/// [HotkeySuppressor.whileFocused] instead suppresses only while something in
/// the subtree holds focus — for wrapping a TEXT FIELD the focus-tree walk
/// cannot see. Wrap the field itself, not the whole panel: the wrapper's own
/// node cannot take focus, but `hasFocus` is true whenever a DESCENDANT holds
/// it, so wrapping tightly keeps the suppression precise (clicking a button
/// elsewhere in the same panel must not silence the keyboard).
class HotkeySuppressor extends StatefulWidget {
  const HotkeySuppressor({super.key, required this.child})
      : whileFocused = false;

  const HotkeySuppressor.whileFocused({super.key, required this.child})
      : whileFocused = true;

  final Widget child;

  /// False: suppress from mount to dispose. True: only while focused.
  final bool whileFocused;

  @override
  State<HotkeySuppressor> createState() => _HotkeySuppressorState();
}

class _HotkeySuppressorState extends State<HotkeySuppressor> {
  VoidCallback? _release;

  @override
  void initState() {
    super.initState();
    if (!widget.whileFocused) _release = pushHotkeySuppression();
  }

  void _onFocusChange(bool hasFocus) {
    if (hasFocus) {
      _release ??= pushHotkeySuppression();
    } else {
      _release?.call();
      _release = null;
    }
  }

  @override
  void dispose() {
    // Release on the way out even if focus never reported leaving — a field
    // can be disposed while still holding focus (the HA badge popover's icon
    // grid collapsing, say).
    _release?.call();
    _release = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.whileFocused) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      child: widget.child,
    );
  }
}

/// True when NO hotkey may fire right now, Esc included: a text input holds
/// focus (typing must never drive the wall), a route is pushed on top (a
/// dialog/picker/full-screen settings surface owns the keyboard), or a
/// [HotkeySuppressor] is mounted/focused.
///
/// Deliberately covers Esc too. The focus-chain listeners this replaces
/// checked Esc *before* their text-focus guard, but they could afford to: a
/// focused field saw the key first and swallowed it. A hardware handler has no
/// such ordering, so exempting Esc would steal it from the field/dropdown that
/// wants it. Nothing is trapped by this: the field loses focus and the next
/// Esc lands.
///
/// [context] is optional ONLY so a caller with no element of its own (a test,
/// or a non-widget guard) can still ask the other two questions; omitting it
/// skips the pushed-route check. Every real hotkey handler has a context and
/// passes it.
bool hotkeyContextBlocked([BuildContext? context]) {
  if (hotkeysSuppressed) return true;
  if (textInputHasFocus()) return true;
  if (context != null && (Navigator.maybeOf(context)?.canPop() ?? false)) {
    return true;
  }
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
