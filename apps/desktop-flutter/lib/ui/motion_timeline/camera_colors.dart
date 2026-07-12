// Deterministic per-camera color, ported from cameraMotionColor() /
// CAM_COLOR_PALETTE in apps/desktop/src/app.js. Cameras have no color field
// in the data model, so the color is derived from the camera's (stable) UUID
// via FNV-1a — same camera -> same color forever, independent of fetch/list
// order. Shared by the motion ribbons, the legend, and the hover hint so the
// three can never drift apart.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A hand-picked, well-separated 12-color palette (not a raw hash->hue) so
/// adjacent indices never land on muddy/near-identical hues on a dark
/// timeline background. Deliberately red-free: red reads as alarm/record on
/// this timeline, not routine per-camera motion.
const List<Color> kCameraColorPalette = [
  Color(0xFF4C9AFF), // azure
  Color(0xFFF2994A), // orange
  Color(0xFF6FCF97), // green
  Color(0xFFF2C94C), // yellow
  Color(0xFFBB6BD9), // purple
  Color(0xFF56CCF2), // cyan
  Color(0xFFF783AC), // pink
  Color(0xFFA9DC76), // lime
  Color(0xFF9B8AFB), // indigo
  Color(0xFFFFB86B), // amber
  Color(0xFF5FE3C0), // teal
  Color(0xFF7AA2F7), // periwinkle
];

/// Extra colors offered ONLY in the manual color picker — kept SEPARATE from
/// [kCameraColorPalette] so adding them never changes the modulo that derives a
/// camera's default color (existing cameras keep their color). Still red-free
/// (red reads as alarm/record on the timeline).
const List<Color> kExtraCameraColors = [
  Color(0xFF2D9CDB), // strong blue
  Color(0xFF27AE60), // emerald
  Color(0xFFE2B93B), // gold
  Color(0xFFEB7BC0), // rose
  Color(0xFF8E7CFF), // violet
  Color(0xFF4ECDC4), // turquoise
  Color(0xFFB2D235), // chartreuse
  Color(0xFFFF9F43), // tangerine
  Color(0xFF9B59B6), // amethyst
  Color(0xFF00B8A9), // jade
  Color(0xFF6C8EAD), // slate blue
  Color(0xFFD6A2E8), // orchid
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
