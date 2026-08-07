// Shared "thing placed on a video pane" abstraction used by the generic
// drag-to-place overlay editor (`overlay_editor_controller.dart` /
// `overlay_editor_layer.dart`, issue #170 §3.3). Two concrete implementations
// exist: HA on-video badges (`ha_overlay/ha_overlay_controller.dart`'s
// `HaOverlayBadgeItem`, video-frame-anchored) and custom PTZ panel buttons
// (`ptz/ptz_panel_controller.dart`'s `PtzOverlayButtonItem`, pane-anchored —
// the P1 port that retired the PTZ builder's private drag/snap code).

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

  /// Current BASE (unscaled) size in logical px at pane-scale 1.0 — item
  /// space. Everything that reasons about an item's size independently of the
  /// pane it happens to be on (the editor bar's readout, [setBaseSize]'s
  /// round-trip, group/align math) works in these units.
  ///
  /// It is `renderedSize(1.0)` by definition, so the item still reads the same
  /// on a small grid tile and a maximized pane (WYSIWYG, matches the PTZ
  /// panel's rationale).
  (double w, double h) baseSize();

  /// Size in RENDERED px on a pane of scale [paneScale]
  /// (`OverlayGeometry.paneScale`). For almost every item this is simply
  /// `baseSize()` scaled — `(w * paneScale, h * paneScale)`, which is what an
  /// implementation should return unless it has the reason below.
  ///
  /// The reason exists for one item: an HA badge drawn as a PILL, whose chip
  /// clamps its own icon/font/padding to floors and ceilings at the height it
  /// is drawn at, so its CONTENT width is not linear in its height. Scaling a
  /// base width linearly then hands a small badge a box narrower than the text
  /// it must draw (the label ellipsizes) and a large one a box wider than it
  /// needs (dead space). Such an item measures itself at the rendered height
  /// instead; see `ha_overlay_controller.dart`'s `HaOverlayBadgeItem`.
  ///
  /// `OverlayGeometry.rectFor` is the ONE caller — position and hit-testing
  /// therefore agree with what is painted, for free.
  (double w, double h) renderedSize(double paneScale);

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

  /// Group membership: items sharing a non-null group id select, move and
  /// resize as one unit in the editor (`OverlayEditorController`'s selection
  /// expands to whole groups). `null` = ungrouped. Persistence is up to the
  /// host: PTZ buttons persist it in their JSON (`PtzPanelButton.group`); HA
  /// badges keep it session-only (the placement PUT has no group field —
  /// grouping badges is a layout-time convenience).
  String? get groupId;
  set groupId(String? v);

  /// Rendered opacity (0.05..1.0, 1 = fully opaque), applied to the item's
  /// visual in both edit and view mode. Persistence is host-owned: PTZ
  /// buttons store it in their JSON (`PtzPanelButton.opacity`), HA badges in
  /// the `overlay_opacity` placement column (migration 0060).
  double get opacity;
  set opacity(double v);

  /// Opaque snapshot of this item's mutable editor state (position, size,
  /// group, opacity, and any host-specific style) for the controller's
  /// undo/redo stack. Round-trips through [restoreState]; the controller
  /// never inspects it, so implementations pick any convenient shape (a
  /// record, a small holder class, …).
  Object captureState();
  void restoreState(Object state);
}
