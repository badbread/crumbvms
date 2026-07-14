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

/// Which image(s) a plate preview shows: both the full camera frame and the
/// cropped plate region, only the full frame, or only the crop. Stored by
/// [name]. When both are shown, the layout depends on the view — the crop is
/// pinned to a corner of the full frame in the compact/gallery thumbs, and set
/// side-by-side in the list rows (which have the horizontal room).
enum PlateImageDisplay { both, fullOnly, cropOnly }

/// Where the plate crop is pinned over the full frame (compact/gallery thumbs),
/// when both images are shown. Ignored in the side-by-side list layout.
enum PlateCropCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Reads/writes the Plates screen client preferences (view mode + how plate
/// previews display their image(s)). All are purely local UI prefs, never sent
/// to the server; a missing/broken shared_preferences channel degrades to the
/// defaults for the session.
class PlatesPrefs {
  PlatesPrefs._();

  static const String _kViewMode = 'crumb_plates_view_mode';
  static const String _kImageDisplay = 'crumb_plates_image_display';
  static const String _kCropCorner = 'crumb_plates_crop_corner';

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

  /// Which image(s) plate previews show. Defaults to [PlateImageDisplay.both].
  static Future<PlateImageDisplay> getImageDisplay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kImageDisplay);
      for (final m in PlateImageDisplay.values) {
        if (m.name == raw) return m;
      }
    } catch (_) {
      /* fall through to the default */
    }
    return PlateImageDisplay.both;
  }

  static Future<void> setImageDisplay(PlateImageDisplay mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kImageDisplay, mode.name);
    } catch (_) {
      /* best-effort persistence */
    }
  }

  /// Where the crop pins over the full frame. Defaults to
  /// [PlateCropCorner.bottomRight].
  static Future<PlateCropCorner> getCropCorner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCropCorner);
      for (final c in PlateCropCorner.values) {
        if (c.name == raw) return c;
      }
    } catch (_) {
      /* fall through to the default */
    }
    return PlateCropCorner.bottomRight;
  }

  static Future<void> setCropCorner(PlateCropCorner corner) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCropCorner, corner.name);
    } catch (_) {
      /* best-effort persistence */
    }
  }
}
