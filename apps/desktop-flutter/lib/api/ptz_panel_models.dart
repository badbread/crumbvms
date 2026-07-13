// Data model + geometry for user-composed PTZ control panels (per-camera,
// drag-laid-out button clusters drawn over the video). Ports the old
// client's `ptzPanels` shape (apps/desktop/src/app.js ~4917-5250:
// `LS_PTZ_PANELS`, `PTZ_PANEL_KINDS`, `ptzBtnSize`, `ptzPanelScale`,
// `ptzPanelBtnRect`) to plain Dart, rebuilt as real Flutter widgets instead
// of mpv ASS overlay text/shapes.
//
// Layout coordinates: button `x`/`y` are FRACTIONS (0..1) of the video pane
// so positions scale with the tile. Button `w`/`h` are BASE (unscaled) px;
// the rendered size is `base * paneScale(w,h)` (see [PtzPanelGeometry]), so
// the whole cluster looks identical whether arranged on a big maximized tile
// or viewed on a small grid tile (WYSIWYG, matches app.js's rationale).

/// One button kind in a custom panel. Mirrors `PTZ_PANEL_KINDS` in app.js.
enum PtzButtonKind {
  up,
  down,
  left,
  right,
  home,
  zoomIn,
  zoomOut,
  focusNear,
  focusFar,
  autoFocus,
  irisOpen,
  irisClose,
  irisAuto,
  preset,
  dpad;

  String get wire => name; // camelCase matches JSON key below (see toJson)

  static PtzButtonKind fromWire(String s) => PtzButtonKind.values.firstWhere(
    (k) => k.name == s,
    orElse: () => PtzButtonKind.home,
  );
}

/// Fixed base size + default label for each kind (`PTZ_PANEL_KINDS` in
/// app.js). Sizes are logical px at panel scale 1.0.
class PtzPanelKindSpec {
  const PtzPanelKindSpec({
    required this.w,
    required this.h,
    this.defaultLabel,
    this.arrow,
  });

  final double w;
  final double h;
  final String? defaultLabel;
  final String? arrow; // 'up'|'down'|'left'|'right' for arrow glyph buttons
}

const Map<PtzButtonKind, PtzPanelKindSpec> kPtzPanelKinds = {
  PtzButtonKind.up: PtzPanelKindSpec(w: 46, h: 32, arrow: 'up'),
  PtzButtonKind.down: PtzPanelKindSpec(w: 46, h: 32, arrow: 'down'),
  PtzButtonKind.left: PtzPanelKindSpec(w: 32, h: 46, arrow: 'left'),
  PtzButtonKind.right: PtzPanelKindSpec(w: 32, h: 46, arrow: 'right'),
  PtzButtonKind.home: PtzPanelKindSpec(w: 44, h: 32, defaultLabel: 'Home'),
  PtzButtonKind.zoomIn: PtzPanelKindSpec(w: 40, h: 32, defaultLabel: 'Z+'),
  PtzButtonKind.zoomOut: PtzPanelKindSpec(w: 40, h: 32, defaultLabel: 'Z−'),
  PtzButtonKind.focusNear: PtzPanelKindSpec(w: 46, h: 30, defaultLabel: 'F−'),
  PtzButtonKind.focusFar: PtzPanelKindSpec(w: 46, h: 30, defaultLabel: 'F+'),
  PtzButtonKind.autoFocus: PtzPanelKindSpec(w: 40, h: 30, defaultLabel: 'AF'),
  PtzButtonKind.irisOpen: PtzPanelKindSpec(w: 40, h: 30, defaultLabel: 'I+'),
  PtzButtonKind.irisClose: PtzPanelKindSpec(w: 40, h: 30, defaultLabel: 'I−'),
  PtzButtonKind.irisAuto: PtzPanelKindSpec(w: 40, h: 30, defaultLabel: 'IA'),
  PtzButtonKind.preset: PtzPanelKindSpec(w: 96, h: 30, defaultLabel: ''),
  PtzButtonKind.dpad: PtzPanelKindSpec(w: 120, h: 120),
};

/// Kinds whose rendered glyph is text (so support rename + show a label),
/// mirroring app.js's `LABELABLE` set in `ptzPanelEditorRender`.
const Set<PtzButtonKind> kPtzLabelableKinds = {
  PtzButtonKind.home,
  PtzButtonKind.zoomIn,
  PtzButtonKind.zoomOut,
  PtzButtonKind.focusNear,
  PtzButtonKind.focusFar,
  PtzButtonKind.autoFocus,
  PtzButtonKind.irisOpen,
  PtzButtonKind.irisClose,
  PtzButtonKind.irisAuto,
  PtzButtonKind.preset,
};

/// Arrow direction -> pan/tilt unit vector (`PTZ_ARROW_VEC` in app.js).
const Map<String, (double pan, double tilt)> kPtzArrowVec = {
  'up': (0, 1),
  'down': (0, -1),
  'left': (-1, 0),
  'right': (1, 0),
};

/// 3x3 d-pad cell (row-major, index = row*3+col) -> pan/tilt vector; the
/// centre cell (index 4) is Home. Mirrors `PTZ_DPAD_VEC` in app.js.
const List<(double pan, double tilt)?> kPtzDpadVec = [
  (-0.71, 0.71), (0, 1), (0.71, 0.71),
  (-1, 0), null, (1, 0),
  (-0.71, -0.71), (0, -1), (0.71, -0.71),
];

const double kPtzBtnMin = 4;
const double kPtzBtnMax = 320;

/// One placed button in a camera's custom panel.
class PtzPanelButton {
  PtzPanelButton({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    this.w,
    this.h,
    this.label,
    this.presetToken,
    this.presetName,
  });

  final String id;
  final PtzButtonKind kind;

  /// Fraction (0..1) of the pane width/height — top-left anchor.
  double x;
  double y;

  /// User-resized BASE size (unscaled px), or null to use the kind's default.
  double? w;
  double? h;

  /// User rename (labelable kinds only); null = use kind default / preset name.
  String? label;

  /// ONVIF preset token + display name (kind == preset only).
  String? presetToken;
  String? presetName;

  /// Effective base size honoring a user resize + kind bounds/defaults
  /// (`ptzBtnSize` in app.js). D-pad is always square.
  (double w, double h) baseSize() {
    final spec = kPtzPanelKinds[kind]!;
    double clamp(double? v, double d) =>
        (v == null || v.isNaN) ? d : v.clamp(kPtzBtnMin, kPtzBtnMax).toDouble();
    final bw = clamp(w, spec.w);
    final bh = kind == PtzButtonKind.dpad ? bw : clamp(h, spec.h);
    return (bw, bh);
  }

  /// Display label (`ptzBtnLabel` in app.js): custom rename wins, else
  /// preset name, else the kind's default label.
  String displayLabel() {
    if (label != null && label!.isNotEmpty) return label!;
    if (kind == PtzButtonKind.preset) {
      return (presetName != null && presetName!.isNotEmpty)
          ? presetName!
          : 'Preset ${presetToken ?? ''}';
    }
    return kPtzPanelKinds[kind]?.defaultLabel ?? '';
  }

  PtzPanelButton copyWith({double? x, double? y, double? w, double? h}) =>
      PtzPanelButton(
        id: id,
        kind: kind,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        label: label,
        presetToken: presetToken,
        presetName: presetName,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.wire,
    'x': x,
    'y': y,
    if (w != null) 'w': w,
    if (h != null) 'h': h,
    if (label != null) 'label': label,
    if (presetToken != null) 'preset': presetToken,
    if (presetName != null) 'preset_name': presetName,
  };

  factory PtzPanelButton.fromJson(Map<String, dynamic> j) => PtzPanelButton(
    id: j['id'] as String,
    kind: PtzButtonKind.fromWire((j['kind'] as String?) ?? 'home'),
    x: (j['x'] as num?)?.toDouble() ?? 0,
    y: (j['y'] as num?)?.toDouble() ?? 0,
    w: (j['w'] as num?)?.toDouble(),
    h: (j['h'] as num?)?.toDouble(),
    label: j['label'] as String?,
    presetToken: j['preset'] as String?,
    presetName: j['preset_name'] as String?,
  );
}

/// Geometry helpers shared by the overlay renderer and its hit-testing —
/// pure functions so both edit and view mode agree pixel-for-pixel.
class PtzPanelGeometry {
  /// Reference tile short-side (`PTZ_PANEL_REF` in app.js) at which base
  /// button sizes render 1:1.
  static const double refShortSide = 320;

  /// Whole-cluster scale factor for a `w`x`h` pane (`ptzPanelScale`).
  static double paneScale(double w, double h) {
    final s = (w < h ? w : h) / refShortSide;
    return s.clamp(0.5, 3.0).toDouble();
  }

  /// Rendered pixel rect (x, y, w, h) of a button within a `w`x`h` pane
  /// (`ptzPanelBtnRect` in app.js). Floors rendered size at 8px so a
  /// shrunk button never disappears; clamps inside the pane bounds.
  static (double x, double y, double w, double h) rectFor(
    PtzPanelButton btn,
    double paneW,
    double paneH,
  ) {
    final (baseW, baseH) = btn.baseSize();
    final s = paneScale(paneW, paneH);
    final bw = (baseW * s).clamp(8, double.infinity).toDouble();
    final bh = (baseH * s).clamp(8, double.infinity).toDouble();
    final x = (btn.x * paneW).clamp(0, paneW - bw).toDouble();
    final y = (btn.y * paneH).clamp(0, paneH - bh).toDouble();
    return (x, y, bw, bh);
  }
}
