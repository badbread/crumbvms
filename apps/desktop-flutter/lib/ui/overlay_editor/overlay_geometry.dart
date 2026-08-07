// Pure geometry for the shared drag-to-place overlay editor — lifted from
// `api/ptz_panel_models.dart`'s `PtzPanelGeometry` (`paneScale`/`rectFor`)
// plus the contain-fit video-rect math lifted from
// `ui/wall_screen.dart`'s `_MaximizedPane._normOffset`, so pane-anchored
// (PTZ) and video-frame-anchored (HA badges) items share ONE pure geometry
// layer used identically by rendering and hit-testing/drag math (issue #170
// §3.3/§4.2). No Flutter/widget dependency — safe to unit test directly.

import 'dart:math' as math;

import 'overlay_item.dart';

class OverlayGeometry {
  const OverlayGeometry._(); // no instances — static namespace only

  /// Reference tile short-side (`PTZ_PANEL_REF` in the old client /
  /// `PtzPanelGeometry.refShortSide`) at which base item sizes render 1:1.
  static const double refShortSide = 320;

  /// Rendered items never shrink below this (logical px), so a heavily
  /// scaled-down item never fully disappears.
  static const double minRenderedPx = 8;

  /// Whole-cluster scale factor for a `paneW`x`paneH` pane
  /// (`PtzPanelGeometry.paneScale`).
  static double paneScale(double paneW, double paneH) {
    final s = (paneW < paneH ? paneW : paneH) / refShortSide;
    return s.clamp(0.5, 3.0).toDouble();
  }

  /// The anchor "field" rect (origin + size, in pane-local px) that an
  /// item's normalized x/y is a fraction OF.
  ///
  /// `OverlayAnchor.pane` -> the whole pane, origin (0,0).
  ///
  /// `OverlayAnchor.videoFrame` -> the DISPLAYED (`BoxFit.contain`
  /// letterboxed) video rect within the pane, computed from the decoded
  /// video's pixel size (`videoW`/`videoH`) — mirrors
  /// `_MaximizedPane._normOffset`'s contain-rect math (wall_screen.dart) so
  /// placement/hit-test agree with what's actually on screen regardless of
  /// tile aspect ratio. Falls back to the whole pane when the video's pixel
  /// size isn't known yet — callers should gate rendering on known
  /// dimensions instead of relying on this fallback (see
  /// `overlay_editor_layer.dart`, which skips `videoFrame`-anchored items
  /// entirely until both are known).
  static (double x, double y, double w, double h) fieldRect(
    OverlayAnchor anchor,
    double paneW,
    double paneH, {
    int? videoW,
    int? videoH,
  }) {
    if (anchor == OverlayAnchor.pane) return (0, 0, paneW, paneH);
    final w = videoW, h = videoH;
    if (w == null || h == null || w <= 0 || h <= 0) {
      return (0, 0, paneW, paneH);
    }
    final s = math.min(paneW / w, paneH / h);
    final fw = w * s;
    final fh = h * s;
    return ((paneW - fw) / 2, (paneH - fh) / 2, fw, fh);
  }

  /// Clamp a rendered box's TOP-LEFT [pos] on one axis so the box stays inside
  /// the `[origin, origin + field]` field span, given the box's [box] extent
  /// on that axis. Order-safe by construction: when [box] is at least as large
  /// as [field] the naive upper limit (`origin + field - box`) falls at or
  /// below [origin], so `num.clamp(origin, hi)` would get `lowerLimit > hi`
  /// and THROW an `ArgumentError`. That is exactly the oversized-badge case (a
  /// `wide` or large-`overlay_size` HA pill whose rendered width exceeds the
  /// letterboxed video field, or a very tall badge on the Y axis); we pin such
  /// a box to [origin] instead — the pill already ellipsizes its label, so
  /// degrading a too-big badge to the field's edge is the right, non-throwing
  /// behavior. For a normal box ([box] < [field]) this is byte-identical to
  /// `pos.clamp(origin, origin + field - box)` — including the `box == field`
  /// boundary, where both yield [origin].
  static double _clampAxis(double pos, double origin, double field, double box) {
    final hi = origin + field - box;
    if (hi <= origin) return origin;
    return pos.clamp(origin, hi).toDouble();
  }

  /// Rendered pixel rect (x, y, w, h) of `item` within a `paneW`x`paneH`
  /// pane, honoring its [OverlayItem.anchor] (`ptzPanelBtnRect`/
  /// `PtzPanelGeometry.rectFor` lifted + anchor-aware). Floors rendered size
  /// at [minRenderedPx] so a shrunk item never disappears; clamps inside its
  /// anchor field.
  ///
  /// Size comes from [OverlayItem.renderedSize] rather than `baseSize() * s`
  /// so an item whose content does not scale linearly with its box (the HA
  /// pill badge) gets the box it actually needs at this pane scale. This is
  /// the ONE place base → rendered happens, so rendering, hit-testing and the
  /// editor's drag/snap math all move together.
  ///
  /// Position clamping runs through [_clampAxis] on BOTH axes so a badge whose
  /// rendered box is larger than its anchor field (an oversized `wide`/large
  /// pill horizontally, or a very tall badge vertically) pins to the field
  /// edge instead of inverting `num.clamp`'s range and throwing — the crash
  /// that turned an affected wall tile into a persistent red error widget.
  static (double x, double y, double w, double h) rectFor(
    OverlayItem item,
    double paneW,
    double paneH, {
    int? videoW,
    int? videoH,
  }) {
    final s = paneScale(paneW, paneH);
    final (rw, rh) = item.renderedSize(s);
    final bw = rw.clamp(minRenderedPx, double.infinity).toDouble();
    final bh = rh.clamp(minRenderedPx, double.infinity).toDouble();
    final (fx, fy, fw, fh) = fieldRect(
      item.anchor,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    final x = _clampAxis(fx + item.x * fw, fx, fw, bw);
    final y = _clampAxis(fy + item.y * fh, fy, fh, bh);
    return (x, y, bw, bh);
  }
}
