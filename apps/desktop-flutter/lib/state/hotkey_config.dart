// Per-camera "go to" number-key assignments (1-9, 0 = camera 10, Shift+digit
// = 11-20) + the remap override persisted across launches.
//
// Ported from app.js:4020-4063 (`HOTKEY_TOKENS`, `hotkeyLabel`,
// `hotkeyTokenFromEvent`, `hotkeysAuto`, `hotkeysConfigured`,
// `hotkeysEffective`, `hotkeyForCamera`, `cameraForHotkey`) and the Settings
// remap UI backing it (app.js:11052-11090, `srvRenderHotkeys` /
// `srvHotkeyChanged` / `srvHotkeyReset`), which this file's [setMapping] /
// [reset] mirror one-for-one (assign a token to a camera by first freeing
// that token from whoever holds it AND freeing any token that camera already
// held — "steal", never a token pointing at two cameras).
//
// Persistence: the old client stored `options.hotkeys` in its own local
// options blob. This port uses `SharedPreferences`, matching the pattern
// already established by lib/state/stream_prefs.dart — `shared_preferences`
// needs to be added to pubspec.yaml (see integration notes); until then this
// degrades gracefully to an in-memory-only mapping for the running session.

import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:crumb_desktop/api/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plain digit tokens "1".."9","0" (cameras 1-10), then shifted "s1".."s0"
/// (cameras 11-20). Order matches app.js's `HOTKEY_TOKENS` exactly — it's
/// also the auto-assignment order.
const List<String> hotkeyTokens = [
  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
  's1', 's2', 's3', 's4', 's5', 's6', 's7', 's8', 's9', 's0',
];

/// Human label for a token: "1".."0" plain, "⇧1".."⇧0" shifted.
/// (app.js `hotkeyLabel`.)
String hotkeyLabel(String token) =>
    token.startsWith('s') ? '⇧${token.substring(1)}' : token;

const String _kHotkeysKey = 'crumb_hotkeys';

/// Holds the saved per-camera hotkey override map (token -> cameraId) and
/// resolves the effective (auto-fallback) assignment for a given camera list.
/// One instance is enough for the whole app; construct via [load] once near
/// the app root (or lazily in whatever screen owns the wall) and pass it down
/// to [GlobalHotkeysListener] and [HotkeyRemapScreen].
class HotkeyConfigStore {
  HotkeyConfigStore._(this._prefs, this._overrides, this._enabled);

  final SharedPreferences? _prefs;
  final Map<String, String> _overrides; // token -> cameraId
  bool _enabled;

  static Future<HotkeyConfigStore> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // package not wired up yet — fall back to in-memory only
    }
    final overrides = <String, String>{};
    final raw = prefs?.getString(_kHotkeysKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in j.entries) {
          if (hotkeyTokens.contains(entry.key) && entry.value is String) {
            overrides[entry.key] = entry.value as String;
          }
        }
      } catch (_) {
        /* corrupt/legacy value — start clean */
      }
    }
    final enabled = prefs?.getBool('${_kHotkeysKey}_enabled') ?? true;
    return HotkeyConfigStore._(prefs, overrides, enabled);
  }

  /// Master on/off for the number-key "go to camera" hotkeys. When false,
  /// [effective] returns an empty map — suppresses both the keydown handler
  /// AND any tile-badge UI in one place, same as app.js `hotkeysEffective`.
  bool get enabled => _enabled;
  set enabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    unawaited(_prefs?.setBool('${_kHotkeysKey}_enabled', v));
  }

  /// Auto assignment by camera order: token[i] -> cameras[i].id, first 20.
  /// (app.js `hotkeysAuto`.)
  Map<String, String> auto(List<Camera> cameras) {
    final map = <String, String>{};
    final n = cameras.length < hotkeyTokens.length
        ? cameras.length
        : hotkeyTokens.length;
    for (var i = 0; i < n; i++) {
      map[hotkeyTokens[i]] = cameras[i].id;
    }
    return map;
  }

  /// Configured token -> cameraId map: the saved override if non-empty, else
  /// pure auto. IGNORES [enabled] — used by the remap UI, which always shows
  /// the map regardless of whether hotkeys are currently active. (app.js
  /// `hotkeysConfigured`.)
  Map<String, String> configured(List<Camera> cameras) =>
      _overrides.isNotEmpty ? Map.unmodifiable(_overrides) : auto(cameras);

  /// The EFFECTIVE map for live use: empty when hotkeys are disabled.
  /// (app.js `hotkeysEffective`.)
  Map<String, String> effective(List<Camera> cameras) =>
      _enabled ? configured(cameras) : const {};

  /// Reverse lookup: cameraId -> token, or null. (app.js `hotkeyForCamera`.)
  String? tokenForCamera(List<Camera> cameras, String cameraId) {
    final map = effective(cameras);
    for (final e in map.entries) {
      if (e.value == cameraId) return e.key;
    }
    return null;
  }

  /// Resolve a token to a live camera id (must still be in [cameras]), or
  /// null. (app.js `cameraForHotkey`.)
  String? cameraForToken(List<Camera> cameras, String token) {
    final id = effective(cameras)[token];
    if (id == null) return null;
    return cameras.any((c) => c.id == id) ? id : null;
  }

  /// Reassign `token` to `cameraId`, stealing it from whoever holds it and
  /// freeing any OTHER token `cameraId` already held (a token maps to at
  /// most one camera, a camera to at most one token). Pass `token: null` to
  /// just clear whatever token `cameraId` currently has (no replacement).
  /// (app.js `srvHotkeyChanged`.)
  void setMapping(List<Camera> cameras, String cameraId, String? token) {
    final map = {...configured(cameras)}; // make the effective map explicit
    map.removeWhere((_, id) => id == cameraId);
    if (token != null) {
      map.remove(token); // free the token, then assign it here
      map[token] = cameraId;
    }
    _overrides
      ..clear()
      ..addAll(map);
    unawaited(_persist());
  }

  /// Reset hotkeys to pure auto (clear the saved override). (app.js
  /// `srvHotkeyReset`.)
  void reset() {
    _overrides.clear();
    unawaited(_persist());
  }

  Future<void> _persist() async {
    if (_prefs == null) return;
    await _prefs.setString(_kHotkeysKey, jsonEncode(_overrides));
  }
}
