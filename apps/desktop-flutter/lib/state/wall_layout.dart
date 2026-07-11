// Layout presets + slot geometry for the managed live wall.
//
// Ported from the Tauri client's LAYOUTS table (apps/desktop/src/app.js:126)
// and the "All Cameras" auto-grid (applyAllCamerasView, app.js:2060). The old
// client also supported arbitrary saved-view geometry (custom rows/cols,
// hotspots, carousels) fetched from a server-side `/views` API — that whole
// server-backed "Saved Views" system is a separate, larger feature and is
// NOT ported here. This file only covers the fixed built-in presets
// (1/4/6/9/16-up) plus the client-only "All Cameras" auto-fit grid, which is
// everything the wall-layouts-slot-management feature needs.

import 'dart:math' as math;

/// One built-in layout preset: a fixed tile count + the grid it renders as.
/// `crossAxisCount` and `mainAxisCount` describe a plain rectangular grid,
/// except `oneplus5` which needs bespoke geometry (one big pane + 5 small).
class LayoutPreset {
  const LayoutPreset({
    required this.id,
    required this.label,
    required this.tiles,
    required this.crossAxisCount,
  });

  final String id;
  final String label;
  final int tiles;

  /// Columns for a plain rectangular grid. Ignored by '1plus5', which lays
  /// itself out explicitly (see [WallLayoutGrid]).
  final int crossAxisCount;

  bool get isOnePlusFive => id == '1plus5';
}

/// Mirrors app.js's `LAYOUTS` (app.js:126-132) — id, label, tile count.
const List<LayoutPreset> kLayoutPresets = [
  LayoutPreset(id: '1x1', label: '1×1', tiles: 1, crossAxisCount: 1),
  LayoutPreset(id: '2x2', label: '2×2', tiles: 4, crossAxisCount: 2),
  LayoutPreset(id: '1plus5', label: '1+5', tiles: 6, crossAxisCount: 3),
  LayoutPreset(id: '3x3', label: '3×3', tiles: 9, crossAxisCount: 3),
  LayoutPreset(id: '4x4', label: '4×4', tiles: 16, crossAxisCount: 4),
];

LayoutPreset layoutById(String id) =>
    kLayoutPresets.firstWhere((l) => l.id == id, orElse: () => kLayoutPresets.first);

/// Auto-sized square-ish grid for "All Cameras" (app.js `applyAllCamerasView`:
/// `cols = ceil(sqrt(n))`, `rows = ceil(n/cols)`).
class AutoGrid {
  const AutoGrid({required this.cols, required this.rows});
  final int cols;
  final int rows;

  int get tiles => cols * rows;

  factory AutoGrid.forCount(int n) {
    final count = math.max(1, n);
    final cols = math.sqrt(count).ceil();
    final rows = (count / cols).ceil();
    return AutoGrid(cols: cols, rows: rows);
  }
}
