// Bottom status-bar message line + current-view label, ported from the old
// client's `setStatus` (apps/desktop/src/app.js:1525) and `currentViewLabel`
// (apps/desktop/src/app.js:312). Client-only, no server calls.
//
// The old client mutated a single DOM text node (`els.statusText`) from many
// call sites scattered across snapshot/export/views/error-handling code.
// This controller is the equivalent shared sink: a single instance is
// constructed once near the app root and threaded down to feature
// screens/controllers as a constructor parameter (the same pattern already
// used for `LayoutController` in this app — no Provider/InheritedWidget
// dependency), so any feature can call `statusBar.setStatus('...')` instead
// of inventing its own bottom-bar text state.
//
// `viewLabel` mirrors app.js's `currentViewLabel()`: the active saved view's
// name, or "All Cameras", or the raw layout preset label for an unsaved
// custom arrangement. Deliberately NOT derived here from LayoutController /
// SavedViewsScreen state directly (this file must stay decoupled from those
// features) — instead the wall/view-switching code calls `setViewLabel(...)`
// whenever the active view changes, exactly like it already calls
// `setStatus(...)` on other transitions.

import 'package:flutter/foundation.dart';

class StatusBarController extends ChangeNotifier {
  StatusBarController({String initialViewLabel = 'All Cameras'})
    : _viewLabel = initialViewLabel;

  String _message = '';

  /// Current status-bar message. Empty string means nothing to show.
  String get message => _message;

  String _viewLabel;

  /// Human label for the active view/layout (app.js `currentViewLabel()`),
  /// e.g. "All Cameras", a saved view's name, or a layout preset's label
  /// ("2×2", "1+5", ...) for an unsaved custom arrangement.
  String get viewLabel => _viewLabel;

  /// Set the status-bar message. Persists until overwritten by the next
  /// call — the old client never auto-cleared status text either.
  void setStatus(String msg) {
    if (_message == msg) return;
    _message = msg;
    notifyListeners();
  }

  void clearStatus() => setStatus('');

  /// Update the current-view label shown alongside the status message.
  /// Call this whenever the active saved view / layout preset / "All
  /// Cameras" selection changes.
  void setViewLabel(String label) {
    if (_viewLabel == label) return;
    _viewLabel = label;
    notifyListeners();
  }
}
