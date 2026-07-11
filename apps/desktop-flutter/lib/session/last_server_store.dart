// Remembers the last-used server URL + username for login-form prefill —
// NOT the session token. Mirrors the old client's `localStorage` keys
// (`LS_SERVER_KEY` = 'crumb_server', `LS_USER_KEY`) in apps/desktop/src/app.js:
// on sign-in both are saved unconditionally; on sign-out
// (`handleSignOut`, app.js:3844) they are deliberately KEPT so the login form
// re-opens prefilled — only the bearer token is dropped.
//
// Uses shared_preferences (plain string prefs, no secrets) rather than
// flutter_rust_bridge/DPAPI — the DPAPI-backed `secret` module
// (apps/desktop-flutter/rust/src/api/secret.rs) is for the actual session
// token and stays untouched by this feature.

import 'package:shared_preferences/shared_preferences.dart';

class LastServerStore {
  LastServerStore._();

  static const _kServer = 'crumb_last_server';
  static const _kUsername = 'crumb_last_username';

  /// Save the server URL + username used for a successful login (or kept
  /// across a sign-out). Either may be omitted to leave that field alone.
  static Future<void> save({String? server, String? username}) async {
    final prefs = await SharedPreferences.getInstance();
    if (server != null) await prefs.setString(_kServer, server);
    if (username != null) await prefs.setString(_kUsername, username);
  }

  /// The last-remembered server URL, or `null` if none is saved yet.
  static Future<String?> loadServer() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kServer);
  }

  /// The last-remembered username, or `null` if none is saved yet.
  static Future<String?> loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kUsername);
  }
}
