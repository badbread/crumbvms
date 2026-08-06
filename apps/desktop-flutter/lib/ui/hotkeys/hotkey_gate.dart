// The single "should a bare-key global shortcut stand down right now?" gate,
// plus an EXPLICIT suppression mechanism for the cases focus introspection
// cannot see.
//
// ── Why introspection alone is not enough ───────────────────────────────────
// `text_focus.dart`'s `textInputHasFocus()` answers the question by walking
// the focus tree, and it works — for a field that actually holds focus. The
// failure it cannot catch is the inverse one: a text field the operator is
// TYPING AT that never received focus in the first place. Then no guard fires,
// the key bubbles all the way up, and a bare-letter shortcut eats the
// keystroke. That is exactly what happened to the HA badge popover's icon
// search box: typing "spotlights" lost the leading "s" to the snapshot hotkey
// (issue: PR #495 live test).
//
// So a widget that owns a text field can declare the suppression itself rather
// than hoping the focus tree reads correctly:
//
//   SuppressHotkeysWhileFocused(child: TextField(...))
//
// which holds a process-wide suppression for exactly as long as that subtree
// holds focus, and releases it on dispose no matter how the widget goes away.
// Belt and suspenders: the focus check still runs, and either one blocking is
// enough.
//
// Every bare-key handler in the app routes through [hotkeyContextBlocked] —
// the snapshot key, the wall's number/M/F8 keys, the HA-overlay H key, and the
// playback transport keys — so there is one place to reason about, and one
// place to add the next exception.

import 'package:flutter/widgets.dart';

import 'text_focus.dart';

/// Active explicit suppressions. A counter, not a flag: two text fields can
/// briefly overlap during a focus handoff, and the second one releasing must
/// not un-suppress while the first is still typing.
int _suppressions = 0;

/// True while any [SuppressHotkeysWhileFocused] (or [pushHotkeySuppression])
/// is holding the keyboard.
bool get hotkeysExplicitlySuppressed => _suppressions > 0;

/// Take a suppression directly. Returns the release callback — call it exactly
/// once. Prefer [SuppressHotkeysWhileFocused], which cannot leak.
VoidCallback pushHotkeySuppression() {
  _suppressions++;
  var released = false;
  return () {
    if (released) return;
    released = true;
    if (_suppressions > 0) _suppressions--;
  };
}

/// Visible for tests: drop every outstanding suppression.
@visibleForTesting
void resetHotkeySuppressionForTest() => _suppressions = 0;

/// The gate every bare-key global shortcut consults before acting.
///
/// Blocked when:
/// * something explicitly suppressed the keyboard (a text field declaring
///   itself — see the file doc); or
/// * the focus tree says a text input has focus; or
/// * `context` is given and a route is pushed over the app (a dialog, a
///   picker, the bookmarks/config screens own the keyboard while up).
bool hotkeyContextBlocked([BuildContext? context]) {
  if (hotkeysExplicitlySuppressed) return true;
  if (textInputHasFocus()) return true;
  if (context != null && (Navigator.maybeOf(context)?.canPop() ?? false)) {
    return true;
  }
  return false;
}

/// Holds a hotkey suppression for as long as anything in [child] has focus.
///
/// Wrap a TEXT FIELD (not a whole panel): the wrapper's own [FocusNode] cannot
/// take focus itself, but `hasFocus` is true whenever a DESCENDANT holds it,
/// so wrapping just the field keeps the suppression precise — clicking a
/// button elsewhere in the same panel does not silence the keyboard.
class SuppressHotkeysWhileFocused extends StatefulWidget {
  const SuppressHotkeysWhileFocused({super.key, required this.child});

  final Widget child;

  @override
  State<SuppressHotkeysWhileFocused> createState() =>
      _SuppressHotkeysWhileFocusedState();
}

class _SuppressHotkeysWhileFocusedState
    extends State<SuppressHotkeysWhileFocused> {
  VoidCallback? _release;

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
    // Release on the way out even if focus never reported leaving (the field
    // can be disposed while focused — the popover closing on Done, say).
    _release?.call();
    _release = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: _onFocusChange,
        child: widget.child,
      );
}
