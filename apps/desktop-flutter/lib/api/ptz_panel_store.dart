// Client-side persistence for custom PTZ panels, keyed by camera id. Ports
// app.js's `LS_PTZ_PANELS` / `savePtzPanels` / `ptzPanelFor`
// (apps/desktop/src/app.js:4923-4926) from `localStorage` to
// `shared_preferences` (this is a desktop app; SharedPreferences on Windows
// persists to a local file, same "client-only, never touches the server"
// semantics as the old client's localStorage). Panels are a per-*device*
// layout preference, not account data, so this intentionally does not call
// any Crumb server endpoint.
//
// Requires the `shared_preferences` package (not yet a pubspec dependency —
// see the human integration notes returned alongside this feature).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'ptz_panel_models.dart';

const _prefsKey = 'crumb_ptz_panels';

/// Loads/saves the map of camera id -> button list. One instance should be
/// shared by the editor controller and any view-mode overlay so writes are
/// serialized through a single in-memory copy.
class PtzPanelStore {
  Map<String, List<PtzPanelButton>>? _cache;

  /// In-flight first load, memoized so two concurrent callers (e.g.
  /// `loadForView` + an edit-session prepare fired back-to-back) share ONE
  /// load and ONE cache map — the old check-then-act version let each build
  /// a fresh map with the last assignment winning, orphaning any mutations
  /// made against the loser (the PTZ builder's D4 cold-store race).
  Future<Map<String, List<PtzPanelButton>>>? _loading;

  Future<Map<String, List<PtzPanelButton>>> _load() {
    if (_cache != null) return Future.value(_cache!);
    return _loading ??= _loadFresh();
  }

  Future<Map<String, List<PtzPanelButton>>> _loadFresh() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final out = <String, List<PtzPanelButton>>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((camId, list) {
          if (list is List) {
            out[camId] = list
                .whereType<Map<String, dynamic>>()
                .map(PtzPanelButton.fromJson)
                .toList();
          }
        });
      } catch (_) {
        // Corrupt/old-shape prefs blob: start clean rather than crash.
      }
    }
    _cache = out;
    _loading = null; // done — later calls short-circuit on _cache
    return out;
  }

  Future<void> _persist() async {
    if (_cache == null) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      _cache!.map((camId, btns) => MapEntry(camId, btns.map((b) => b.toJson()).toList())),
    );
    await prefs.setString(_prefsKey, encoded);
  }

  /// The panel for `cameraId`, or null if none has ever been created
  /// (`ptzPanelFor` in app.js — distinct from an explicitly-emptied `[]`
  /// panel, which is falsy-but-present in app.js; here we just return the
  /// list, empty or not, once it exists).
  Future<List<PtzPanelButton>?> panelFor(String cameraId) async {
    final map = await _load();
    return map[cameraId];
  }

  /// Replace `cameraId`'s panel wholesale and persist.
  ///
  /// (The old `panelForEdit`/`panelForEditSync` mutate-the-cache-in-place
  /// editing API is gone: the shared overlay editor session owns its own
  /// working copy and hands the final list back through here on save —
  /// see `ui/ptz/ptz_panel_controller.dart`.)
  Future<void> save(String cameraId, List<PtzPanelButton> buttons) async {
    final map = await _load();
    map[cameraId] = buttons;
    await _persist();
  }

  /// Clear `cameraId`'s panel (back to no custom panel) and persist.
  Future<void> clear(String cameraId) async {
    final map = await _load();
    map[cameraId] = [];
    await _persist();
  }
}
