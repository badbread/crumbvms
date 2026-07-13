// Deterministic per-camera color, ported from cameraMotionColor() /
// CAM_COLOR_PALETTE in apps/desktop/src/app.js. Cameras have no color field
// in the data model, so the color is derived from the camera's (stable) UUID
// via FNV-1a — same camera -> same color forever, independent of fetch/list
// order. Shared by the motion ribbons, the legend, and the hover hint so the
// three can never drift apart.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A hand-picked, MAXIMALLY-separated 12-color palette (not a raw hash->hue) so
/// adjacent cameras on the dark timeline are easy to tell apart — hues span the
/// wheel with big gaps and lightness alternates so even same-family hues
/// (blue/cyan/indigo, green/lime/teal) still read distinct. Deliberately
/// red-free: red reads as alarm/record on this timeline, not routine motion.
const List<Color> kCameraColorPalette = [
  Color(0xFF4C9AFF), // blue
  Color(0xFFFF8A3D), // orange
  Color(0xFF2FCF6F), // green
  Color(0xFFFFD23F), // yellow
  Color(0xFFB57BEF), // purple
  Color(0xFF17D5E6), // cyan (brighter/greener than the blue)
  Color(0xFFFF7FB2), // pink
  Color(0xFF9CD323), // lime
  Color(0xFF7C6CFF), // indigo
  Color(0xFF12B58A), // teal (darker, green-leaning)
  Color(0xFFE08A5A), // coral
  Color(0xFFD65DB1), // magenta
];

/// Extra colors offered ONLY in the manual color picker — kept SEPARATE from
/// [kCameraColorPalette] so adding them never changes the modulo that derives a
/// camera's default color. Chosen to fill the GAPS in the base palette (paler /
/// darker variants + off-hues) for more manual choice. Still red-free.
const List<Color> kExtraCameraColors = [
  Color(0xFF8FB3FF), // pale blue
  Color(0xFFC08A00), // dark gold
  Color(0xFF00A3A3), // dark teal
  Color(0xFFF06292), // rose
  Color(0xFFA5D6A7), // pale green
  Color(0xFFCE93D8), // pale purple
  Color(0xFFFFAB40), // amber
  Color(0xFF64B5F6), // sky
  Color(0xFF9575CD), // lavender
  Color(0xFF4DB6AC), // aqua
  Color(0xFFC6D64B), // olive-lime
  Color(0xFFBA68C8), // orchid
];

/// The full swatch set shown in the manual picker: the derived palette plus the
/// extras.
final List<Color> kCameraPickerPalette = [
  ...kCameraColorPalette,
  ...kExtraCameraColors,
];

/// FNV-1a 32-bit string hash — matches the old client's `fnv1a()` exactly so
/// a given camera id maps to the same palette index across clients.
int fnv1a32(String str) {
  var h = 0x811c9dc5;
  for (final unit in str.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

final Map<String, Color> _cache = {};

// ── user color overrides ────────────────────────────────────────────────────
// The operator can right-click a camera in the timeline legend to pick its
// motion color. Overrides win over the deterministic palette color and are
// persisted per-camera (client-only, like the old client's per-device prefs).

const String _kOverridesKey = 'crumb_cam_colors';
final Map<String, Color> _overrides = {};
bool _overridesLoaded = false;

/// Load persisted per-camera color overrides once. Safe to call repeatedly.
/// Degrades to in-memory-only if `shared_preferences` isn't available.
Future<void> loadCameraColorOverrides() async {
  if (_overridesLoaded) return;
  _overridesLoaded = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kOverridesKey);
    if (raw == null || raw.isEmpty) return;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    map.forEach((k, v) {
      if (v is int) _overrides[k] = Color(v);
    });
  } catch (_) {
    // in-memory only for this session
  }
}

/// Set (or clear, when [color] is null) a camera's motion-color override and
/// persist the full map. The next [cameraMotionColor] call reflects it.
Future<void> setCameraColorOverride(String cameraId, Color? color) async {
  if (color == null) {
    _overrides.remove(cameraId);
  } else {
    _overrides[cameraId] = color;
  }
  try {
    final prefs = await SharedPreferences.getInstance();
    final map = {
      for (final e in _overrides.entries) e.key: e.value.toARGB32(),
    };
    await prefs.setString(_kOverridesKey, jsonEncode(map));
  } catch (_) {
    // persistence best-effort; the override still applies in-memory
  }
}

/// True if [cameraId] has a user color override (vs the derived palette color).
bool hasCameraColorOverride(String cameraId) => _overrides.containsKey(cameraId);

/// Stable color for a camera id: a user override if set, else the deterministic
/// palette color (cached — the hash is deterministic anyway; caching just
/// avoids recomputing on every paint).
Color cameraMotionColor(String? cameraId) {
  if (cameraId == null || cameraId.isEmpty) {
    return const Color(0x804C9AFF); // faded fallback, matches TL.MOTION_FADED intent
  }
  final override = _overrides[cameraId];
  if (override != null) return override;
  return _cache.putIfAbsent(
    cameraId,
    () => kCameraColorPalette[fnv1a32(cameraId) % kCameraColorPalette.length],
  );
}
