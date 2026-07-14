// Persisted client-side preference: the Plates screen's last view mode
// (List / Gallery / Grouped-by-plate / Timeline feed). Restoring it means a
// tab switch or a fresh app launch reopens the plate browser in the layout the
// operator left, instead of resetting to the dense list every time.
//
// This is a purely local UI preference — it is never sent to the Crumb server
// and carries no camera/session data, so it is stored with shared_preferences
// rather than the DPAPI-backed secret store used for the session token. Mirrors
// `lib/ui/playback/playback_prefs.dart`; a missing/broken shared_preferences
// platform channel degrades gracefully to in-memory-only for the session.

import 'package:shared_preferences/shared_preferences.dart';

/// The four Plates layouts. Stored by [name] so adding a mode never renumbers
/// an existing persisted value.
enum PlatesViewMode { list, gallery, grouped, timeline }

/// Reads/writes the single "plates view mode" client preference.
class PlatesPrefs {
  PlatesPrefs._();

  static const String _kViewMode = 'crumb_plates_view_mode';

  /// The last-used view mode, or [PlatesViewMode.list] when the operator has
  /// never changed it (or persistence is unavailable).
  static Future<PlatesViewMode> getViewMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kViewMode);
      for (final m in PlatesViewMode.values) {
        if (m.name == raw) return m;
      }
    } catch (_) {
      /* fall through to the default */
    }
    return PlatesViewMode.list;
  }

  static Future<void> setViewMode(PlatesViewMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kViewMode, mode.name);
    } catch (_) {
      /* best-effort persistence, same as the other client-only pref stores */
    }
  }
}
