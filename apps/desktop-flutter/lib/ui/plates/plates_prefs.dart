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

import 'package:crumb_desktop/ui/plates/plate_desk_logic.dart';

/// The four Plates layouts. Stored by [name] so adding a mode never renumbers
/// an existing persisted value.
enum PlatesViewMode { list, gallery, grouped, timeline }

/// Gallery cards: show the plate crop as an inset over the frame ([both]) or
/// the frame alone ([fullOnly]). Stored by [name]. The list no longer reads
/// this: its one display control is [PlateDensity]. [cropOnly] is a retired
/// value from the old "Show" menu, read back as [both].
enum PlateImageDisplay { both, fullOnly, cropOnly }

/// Gallery cards: the corner the plate inset is pinned to.
enum PlateCropCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Gallery cards: how large the plate inset renders.
enum PlateCropSize { small, medium, large }

/// Reads/writes the Plates screen client preferences (view mode + how plate
/// previews display their image(s)). All are purely local UI prefs, never sent
/// to the server; a missing/broken shared_preferences channel degrades to the
/// defaults for the session.
class PlatesPrefs {
  PlatesPrefs._();

  static const String _kViewMode = 'crumb_plates_view_mode';
  static const String _kImageDisplay = 'crumb_plates_image_display';
  static const String _kCropCorner = 'crumb_plates_crop_corner';
  static const String _kCropSize = 'crumb_plates_crop_size';
  static const String _kCollapse = 'crumb_plates_collapse_dupes';
  static const String _kShowWatchlist = 'crumb_plates_show_watchlist';
  static const String _kDensity = 'crumb_plates_density';
  static const String _kGroupByPlate = 'crumb_plates_group_by_plate';

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
      // The retired "crop only" mode has no gallery equivalent: show the
      // inset (the plate is still the point of the card).
      if (raw == PlateImageDisplay.cropOnly.name) return PlateImageDisplay.both;
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

  /// How large the plate crop renders. Defaults to [PlateCropSize.medium].
  static Future<PlateCropSize> getCropSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCropSize);
      for (final s in PlateCropSize.values) {
        if (s.name == raw) return s;
      }
    } catch (_) {
      /* fall through to the default */
    }
    return PlateCropSize.medium;
  }

  static Future<void> setCropSize(PlateCropSize size) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCropSize, size.name);
    } catch (_) {
      /* best-effort persistence */
    }
  }

  /// Whether the list collapses duplicate reads of one car (both engines +
  /// Frigate's own OCR refinements) into a single row. Defaults to true — the
  /// clutter it removes is almost never wanted raw; operators comparing the two
  /// engines can turn it off to see every read.
  static Future<bool> getCollapseDuplicates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kCollapse) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setCollapseDuplicates(bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCollapse, on);
    } catch (_) {
      /* best-effort persistence */
    }
  }

  /// Whether the watchlist side panel is open. Defaults to true (open) the
  /// first time, matching the panel's original default; thereafter it remembers
  /// the operator's last choice, so closing it and switching tabs (which rebuilds
  /// the Plates screen from scratch — there is no keep-alive) no longer springs
  /// the panel back open. Purely local UI state, like the other plate prefs.
  static Future<bool> getShowWatchlist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kShowWatchlist) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setShowWatchlist(bool show) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowWatchlist, show);
    } catch (_) {
      /* best-effort persistence */
    }
  }

  /// The list's Density. When the operator never picked one, it is migrated
  /// once from the retired list prefs: a "large" crop size becomes Large,
  /// anything else Standard. Defaults to [PlateDensity.standard].
  static Future<PlateDensity> getDensity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDensity);
      for (final d in PlateDensity.values) {
        if (d.name == raw) return d;
      }
      final migrated = densityFromLegacy(prefs.getString(_kCropSize));
      await prefs.setString(_kDensity, migrated.name);
      return migrated;
    } catch (_) {
      return PlateDensity.standard;
    }
  }

  static Future<void> setDensity(PlateDensity d) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDensity, d.name);
    } catch (_) {
      /* best-effort persistence */
    }
  }

  /// Whether the list groups reads of the same plate into one row. Defaults
  /// to false (one row per pass, newest first).
  static Future<bool> getGroupByPlate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kGroupByPlate) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setGroupByPlate(bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kGroupByPlate, on);
    } catch (_) {
      /* best-effort persistence */
    }
  }
}

/// One-time migration from the retired list "Crop size" pref to Density.
PlateDensity densityFromLegacy(String? cropSize) =>
    cropSize == PlateCropSize.large.name
    ? PlateDensity.large
    : PlateDensity.standard;
