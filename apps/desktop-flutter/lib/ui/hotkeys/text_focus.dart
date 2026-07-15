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

import 'package:flutter/widgets.dart';

/// True when a text input currently holds keyboard focus.
bool textInputHasFocus() {
  final node = FocusManager.instance.primaryFocus;
  final ctx = node?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  var found = false;
  void visit(Element e) {
    if (found) return;
    if (e.widget is EditableText) {
      found = true;
      return;
    }
    e.visitChildren(visit);
  }

  ctx.visitChildElements(visit);
  return found;
}
