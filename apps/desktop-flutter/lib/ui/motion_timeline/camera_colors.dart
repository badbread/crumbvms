// Deterministic per-camera color, ported from cameraMotionColor() /
// CAM_COLOR_PALETTE in apps/desktop/src/app.js. Cameras have no color field
// in the data model, so the color is derived from the camera's (stable) UUID
// via FNV-1a — same camera -> same color forever, independent of fetch/list
// order. Shared by the motion ribbons, the legend, and the hover hint so the
// three can never drift apart.

import 'package:flutter/material.dart';

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

/// Stable color for a camera id. Cached (the hash is deterministic anyway;
/// caching just avoids recomputing on every paint).
Color cameraMotionColor(String? cameraId) {
  if (cameraId == null || cameraId.isEmpty) {
    return const Color(0x804C9AFF); // faded fallback, matches TL.MOTION_FADED intent
  }
  return _cache.putIfAbsent(
    cameraId,
    () => kCameraColorPalette[fnv1a32(cameraId) % kCameraColorPalette.length],
  );
}
