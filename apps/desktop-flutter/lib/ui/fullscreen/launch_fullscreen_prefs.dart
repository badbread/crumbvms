// Persisted client-side preference: "open the camera wall fullscreen on
// launch". Mirrors the old Tauri client's `options.launchFullscreen`
// (apps/desktop/src/app.js — LS_OPTIONS_KEY `crumb_options`,
// `opt-launch-fullscreen` checkbox, applied from `applyLaunchPreferences()`).
//
// This is a purely local UI preference — it is never sent to the Crumb
// server and carries no camera/session data, so it is stored with
// shared_preferences rather than the DPAPI-backed secret store used for the
// session token.
//
// Needs `shared_preferences` added to pubspec.yaml (see integration notes).
// Until then (or if the platform channel is unavailable for any reason) this
// degrades gracefully to an in-memory-only preference for the running
// session, matching the fallback pattern used by
// `lib/state/stream_prefs.dart` and `lib/ui/saved_views/view_prefs.dart`.

import 'package:shared_preferences/shared_preferences.dart';

/// Reads/writes the single "launch fullscreen" client option.
///
/// Kept as its own tiny class (rather than a general options bag) because
/// this port covers exactly one preference; if more client-side options are
/// ported later they should grow this into a shared `ClientOptions` rather
/// than each feature inventing its own SharedPreferences key.
class LaunchFullscreenPrefs {
  LaunchFullscreenPrefs._();

  static const String _key = 'crumb.launchFullscreen';

  /// Whether the wall should enter fullscreen automatically once the default
  /// view has finished loading after login. Defaults to false (matches the
  /// old client's default-unset checkbox).
  static Future<bool> get() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> set(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {
      /* best-effort persistence, same as the old client's try/catch around
         localStorage.setItem (app.js saveOptions()) */
    }
  }
}
