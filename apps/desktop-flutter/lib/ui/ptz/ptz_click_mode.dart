// Click-to-interact mode for PTZ video panes. Mirrors app.js's
// `options.ptzClickMode` ('center' | 'pan' | 'off') — see apps/desktop/src/app.js
// `applyPtzClickMode` (around line 5403). The human wiring this in should surface
// this as a per-app option (settings/menu) alongside the existing PTZ toggle.
enum PtzClickMode {
  /// Click anywhere on the video → a proportional recenter pulse toward that
  /// point (click near center = no-op; near an edge = a longer/faster pulse).
  center,

  /// Press-and-hold anywhere on the video → continuous pan/tilt toward the
  /// pointer (velocity proportional to offset from center); release to stop.
  /// Dragging while held re-steers.
  pan,

  /// No click/hold interaction — only the D-pad controls (and wheel-zoom, if
  /// enabled) drive PTZ.
  off,
}
