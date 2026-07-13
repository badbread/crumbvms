// Centralized 401 handling + in-place re-auth, mirroring the old client's
// `handleUnauthorized` / `reauthOpen` / `reauthSubmit` (apps/desktop/src/app.js).
//
// A 401 mid-session (expired/revoked token) used to tear the whole wall down
// to the login screen — for an unattended camera wall that meant every video
// pane got destroyed just because a token lapsed. Instead, this controller
// flags `needsReauth` and keeps the current [Session] (server base, last-known
// token) in place; the app shell and every native video pane keep running
// underneath a modal re-auth overlay (see
// lib/ui/reauth/reauth_overlay.dart). On successful sign-in the fresh
// [Session] replaces the old one in place — nothing else reloads.
//
// One [SessionController] should be created right after login and live for
// the process lifetime of being signed in (same scope as the
// [MediaTokenCache] it's normally paired with).

import 'package:flutter/foundation.dart';

import '../api/crumb_api.dart';
import '../api/models.dart';

class SessionController extends ChangeNotifier {
  SessionController({
    required CrumbApi api,
    required Session initialSession,
    String? username,
  }) : _api = api,
       _session = initialSession,
       _username = username;

  final CrumbApi _api;
  Session _session;
  String? _username;
  bool _needsReauth = false;
  String? _reauthError;
  bool _reauthing = false;

  Session get session => _session;

  /// Best-effort username to prefill the re-auth dialog with. Callers should
  /// set this from whatever they used to sign in originally (e.g. after
  /// `_onLoggedIn` in main.dart).
  String? get username => _username;

  /// True while a re-auth prompt should be shown over the (still-running)
  /// app shell.
  bool get needsReauth => _needsReauth;

  /// Error text from the last failed re-auth attempt, if any.
  String? get reauthError => _reauthError;

  /// True while a re-auth submission is in flight (disable the form).
  bool get reauthing => _reauthing;

  /// Call this whenever ANY authenticated request against [session] comes
  /// back 401 (the bearer JWT expired or was revoked). Idempotent — repeated
  /// 401s while the prompt is already up are a no-op, matching the old
  /// client's `reauthShown` guard (don't stack overlays).
  ///
  /// Callers that also hold a `MediaTokenCache` should clear it themselves
  /// here or wire it as that cache's `onUnauthorized` callback — a stale
  /// principal's scoped media tokens must never be reused by whoever signs
  /// back in.
  void handleUnauthorized() {
    if (_needsReauth) return;
    _needsReauth = true;
    _reauthError = null;
    notifyListeners();
  }

  /// Re-POST /auth/login with the SAME server base, swap in the fresh
  /// [Session], and close the prompt. Does not touch cameras/layout/panes —
  /// only the token changes.
  Future<void> reauth(
    String username,
    String password, {
    bool remember = true,
  }) async {
    if (username.trim().isEmpty) {
      _reauthError = 'Username is required.';
      notifyListeners();
      return;
    }
    _reauthing = true;
    _reauthError = null;
    notifyListeners();
    try {
      final fresh = await _api.login(
        _session.base,
        username.trim(),
        password,
        remember: remember,
      );
      _session = fresh;
      _username = username.trim();
      _needsReauth = false;
    } on CrumbApiException catch (e) {
      _reauthError = e.message;
    } catch (e) {
      _reauthError = 'Sign-in failed: $e';
    } finally {
      _reauthing = false;
      notifyListeners();
    }
  }
}
