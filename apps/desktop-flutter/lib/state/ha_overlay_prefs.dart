// The global "hide Home Assistant overlays" quick-toggle.
//
// One operator-facing switch that suppresses EVERY on-video HA badge (icons,
// pills, pinned captions, the tap-to-open state card) across every live pane —
// wall tiles and the maximized pane alike. It is purely a DISPLAY gate: linking
// entities, badge placement, the right-click menu items and the HA polling all
// carry on exactly as before, so flipping it back restores the previous
// overlay setup untouched. Default = overlays SHOWN.
//
// Persisted through `shared_preferences` (key [_kHiddenKey]) so the choice
// survives a restart, degrading to in-memory-only for the session when the
// plugin is unavailable — the same contract as the other client stores in this
// directory (`stream_prefs.dart`, `keyboard_shortcuts.dart`).
//
// WHY A SINGLETON, when the sibling stores are constructed at the app root and
// injected: this flag is WRITTEN from the live wall's toolbar (main.dart's
// ViewSelectorBar) and the global hotkey, but READ two widget layers deep, at
// the leaf HA overlay layers inside `wall_screen.dart`'s tile and maximized
// pane. Threading it through those constructors would touch a lot of unrelated
// call sites for a single app-wide bool; a `ChangeNotifier` singleton keeps the
// wall diff to the two lines that actually gate the badges. Call [load] once
// during app start-up ([_loadStores] in main.dart); reads before that simply
// see the default.

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kHiddenKey = 'crumb.ha_overlays_hidden';

/// App-wide visibility of the on-video Home Assistant badge layer. Listen to it
/// to rebuild when the operator toggles overlays on/off.
class HaOverlayPrefs extends ChangeNotifier {
  HaOverlayPrefs._();

  /// The one instance — see the file header for why this is a singleton.
  static final HaOverlayPrefs instance = HaOverlayPrefs._();

  SharedPreferences? _prefs;
  bool _hidden = false;

  /// True when the operator has hidden every HA overlay. Default false
  /// (overlays shown), including when the prefs plugin is unavailable.
  bool get hidden => _hidden;

  set hidden(bool value) {
    if (_hidden == value) return;
    _hidden = value;
    unawaited(_prefs?.setBool(_kHiddenKey, value));
    notifyListeners();
  }

  /// Flip the toggle — what the toolbar button and the hotkey both call.
  void toggle() => hidden = !_hidden;

  /// Read the persisted value. Safe to call more than once; a failure to reach
  /// `shared_preferences` leaves the store in-memory-only for this session.
  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      _prefs = null; // plugin unavailable — in-memory only, per-session
      return;
    }
    final stored = _prefs?.getBool(_kHiddenKey) ?? false;
    if (stored != _hidden) {
      _hidden = stored;
      notifyListeners();
    }
  }
}
