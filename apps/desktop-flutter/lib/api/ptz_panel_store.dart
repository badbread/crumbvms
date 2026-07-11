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

  Future<Map<String, List<PtzPanelButton>>> _load() async {
    if (_cache != null) return _cache!;
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

  /// Get-or-create the (possibly empty) mutable button list for `cameraId`,
  /// for the editor to mutate in place before calling [save]. Call this once
  /// (e.g. on entering edit mode) to prime the in-memory cache, then use
  /// [panelForEditSync] for the synchronous per-gesture-tick access an
  /// active drag/resize needs.
  Future<List<PtzPanelButton>> panelForEdit(String cameraId) async {
    final map = await _load();
    return map.putIfAbsent(cameraId, () => []);
  }

  /// Synchronous access to the mutable button list for `cameraId`, valid
  /// only after [panelForEdit] (or any other load-triggering call) has
  /// resolved at least once in this store's lifetime. Returns null if the
  /// cache isn't warm yet or the camera has no entry — callers that need a
  /// list unconditionally should await [panelForEdit] first.
  List<PtzPanelButton>? panelForEditSync(String cameraId) => _cache?[cameraId];

  /// Replace `cameraId`'s panel wholesale and persist.
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
