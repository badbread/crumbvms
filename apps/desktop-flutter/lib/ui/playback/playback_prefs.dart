// Persisted client-side preference: the Playback timeline's last zoom span
// (visible window duration, in ms). Restoring it means returning to Playback —
// on a tab switch or a fresh app launch — reopens at the scale the operator
// left, instead of resetting to the controller's default 1 h window.
//
// This is a purely local UI preference — it is never sent to the Crumb server
// and carries no camera/session data, so it is stored with shared_preferences
// rather than the DPAPI-backed secret store used for the session token.
//
// Kept as its own tiny class (matching `lib/ui/fullscreen/launch_fullscreen_
// prefs.dart`) because it is a single preference. Like every other client-only
// pref store here, a missing/broken `shared_preferences` platform channel
// degrades gracefully to in-memory-only (no persistence) for the running
// session rather than throwing.

import 'package:shared_preferences/shared_preferences.dart';

/// Reads/writes the single "playback timeline zoom span" client preference
/// (visible window duration in milliseconds).
class PlaybackPrefs {
  PlaybackPrefs._();

  static const String _kSpanMs = 'crumb_playback_span_ms';

  /// The last-used timeline span in ms, or null when the operator has never
  /// changed the zoom (callers fall back to the controller's default span).
  static Future<int?> getSpanMs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_kSpanMs);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setSpanMs(int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSpanMs, value);
    } catch (_) {
      /* best-effort persistence, same as the old client's try/catch around
         localStorage.setItem (app.js saveOptions()) */
    }
  }
}
