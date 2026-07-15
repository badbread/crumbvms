// Shared "thing placed on a video pane" abstraction used by the generic
// drag-to-place overlay editor (`overlay_editor_controller.dart` /
// `overlay_editor_layer.dart`, issue #170 §3.3). One concrete implementation
// exists today: HA on-video badges (`ha_overlay/ha_overlay_controller.dart`'s
// `HaOverlayBadgeItem`, video-frame-anchored). A PTZ custom-panel-button
// adapter (`PtzPanelButton` implementing this) is a later follow-up per the
// desktop P0 plan §3.3/§5 P1 — NOT part of this change; `PtzPanelButton`
// (`api/ptz_panel_models.dart`) keeps its own pane-fraction geometry for now.

/// What an item's normalized x/y is a fraction OF.
enum OverlayAnchor {
  /// Fraction of the whole rendered pane (the PTZ custom-panel convention).
  pane,

  /// Fraction of the DISPLAYED (`BoxFit.contain` letterboxed) video frame
  /// within the pane — stays pinned to the same physical point in frame
  /// regardless of tile aspect/letterboxing (HA badge placement, issue #170
  /// §4.2). Requires the decoded video's pixel size to render/hit-test —
  /// see `overlay_geometry.dart`'s `fieldRect`.
  videoFrame,
}

/// One item placed on the overlay. Mutable — the editor controller mutates
/// `x`/`y`/size in place during a drag/resize, and the host reads the final
/// state back from `OverlayEditorController.endEdit()`.
abstract class OverlayItem {
  /// Stable identity within an edit session (e.g. the HA link's uuid).
  String get id;

  /// Normalized position (0..1 each), a fraction of [anchor]'s field —
  /// TOP-LEFT anchor of the rendered rect (matches the PTZ button convention
  /// this abstraction was lifted from, `ptz_panel_models.dart`).
  double get x;
  set x(double v);
  double get y;
  set y(double v);

  OverlayAnchor get anchor;

  /// Current BASE (unscaled) size in logical px at pane-scale 1.0 — the
  /// rendered size is `base * OverlayGeometry.paneScale(...)`, so the item
  /// reads the same on a small grid tile and a maximized pane (WYSIWYG,
  /// matches the PTZ panel's rationale).
  (double w, double h) baseSize();

  /// Apply a new base size — already the result of a drag-resize delta (or
  /// the editor bar's +/- stepper) divided back to base units.
  /// Implementations own their own clamping/aspect rules (e.g. a PTZ d-pad
  /// stays square; an HA badge is always square and stores a scale
  /// multiplier, not raw px).
  void setBaseSize(double w, double h);

  /// Whether the on-canvas drag-resize handle appears when this item is
  /// selected in edit mode. `false` items (HA badges) are still resizable
  /// via the editor bar's size stepper, which calls [setBaseSize] directly —
  /// this flag ONLY gates the drag handle, not resizability in general.
  bool get resizable;
}
