// Shared "is a text input focused?" guard for every single-key global
// shortcut (number/keypad camera-switch, S snapshot, M audio, F8 HUD). When a
// text field has focus, single-key shortcuts must stand down so typing a size
// number in the overlay editor doesn't switch cameras and "M" in a badge label
// doesn't maximize (issue #2). Modified shortcuts (Ctrl+Z/…) are unaffected —
// they carry a modifier and the digit/letter guards skip them anyway.
//
// The bare `primaryFocus.context.widget is EditableText` check that the
// listeners used misses fields whose FocusNode is attached ABOVE the
// EditableText, so this also walks the focused element's subtree for an
// EditableText. Cheap: only the focused widget's (small) subtree is visited,
// and only on a key-down.
//
// ── KNOWN LIMIT, and why this deliberately stays a heuristic ────────────────
// It does NOT see a field given an explicit `focusNode:` in every arrangement:
// `EditableText` attaches such a node to a `Focus` widget it builds INSIDE
// itself, so the focused element is a DESCENDANT of the EditableText and a
// downward walk finds nothing. That is the shape of the HA badge popover's
// icon-search box, and it is why bare-letter shortcuts kept firing while the
// operator typed into it (PR #495 live test: typing "spotlights" lost its "s"
// to the snapshot key).
//
// Walking UP as well was tried and REJECTED: from a focus node that lands
// mid-teardown it reports a text field that is no longer there, which leaves
// every single-key shortcut in the app dead until focus moves again. Trading a
// "shortcut fires while typing" bug for a "shortcuts stop working" bug is a bad
// deal, and this helper is shared by the wall, playback, audio and snapshot
// keys.
//
// So: this stays a cheap best-effort signal, and anything that must be CERTAIN
// it owns the keyboard declares it explicitly with `hotkey_gate.dart`'s
// `HotkeySuppressor.whileFocused`. The gate treats either signal as blocking.

import 'package:flutter/widgets.dart';

/// True when a text input currently holds keyboard focus. See the file doc's
/// KNOWN LIMIT before relying on this alone.
bool textInputHasFocus() {
  final node = FocusManager.instance.primaryFocus;
  final ctx = node?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  // A SCOPE holding primary focus means nothing in particular is focused
  // (focus fell back after a widget was disposed or explicitly unfocused).
  // Walking down from it would sweep the entire scope's subtree and report
  // "a text field is focused" because SOME field exists somewhere in it —
  // which killed every single-key shortcut for as long as a panel containing
  // any text field was on screen (the HA badge popover always has one).
  if (node is FocusScopeNode) return false;
  // The usual real-field shape: the focused node is the Focus that EditableText
  // builds INSIDE itself, so the field is an ANCESTOR of the focused element.
  // (The earlier downward-only walk missed this entirely and only "worked"
  // because the app root's plain Focus, which holds primary focus whenever no
  // field is actually focused, has the whole app below it.) Guarded: a node
  // that is mid-teardown may have a defunct context.
  try {
    if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) return true;
  } catch (_) {
    return false;
  }
  var found = false;
  void visit(Element e) {
    if (found) return;
    final w = e.widget;
    if (w is EditableText) {
      // Only a field that is itself in the focus chain counts. The app root's
      // autofocused `Focus` (FullscreenEscHandler) is a plain node whose
      // subtree is the WHOLE app, so "some EditableText exists below primary
      // focus" is true on any tab that shows a search box (Plates), and every
      // hardware hotkey on that tab went dead (Esc / Space / j / k).
      if (w.focusNode.hasFocus) found = true;
      return;
    }
    e.visitChildren(visit);
  }

  ctx.visitChildElements(visit);
  return found;
}
