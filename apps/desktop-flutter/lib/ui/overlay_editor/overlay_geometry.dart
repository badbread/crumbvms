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

  /// Rendered pixel rect (x, y, w, h) of `item` within a `paneW`x`paneH`
  /// pane, honoring its [OverlayItem.anchor] (`ptzPanelBtnRect`/
  /// `PtzPanelGeometry.rectFor` lifted + anchor-aware). Floors rendered size
  /// at [minRenderedPx] so a shrunk item never disappears; clamps inside its
  /// anchor field.
  static (double x, double y, double w, double h) rectFor(
    OverlayItem item,
    double paneW,
    double paneH, {
    int? videoW,
    int? videoH,
  }) {
    final (baseW, baseH) = item.baseSize();
    final s = paneScale(paneW, paneH);
    final bw = (baseW * s).clamp(minRenderedPx, double.infinity).toDouble();
    final bh = (baseH * s).clamp(minRenderedPx, double.infinity).toDouble();
    final (fx, fy, fw, fh) = fieldRect(
      item.anchor,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    final x = (fx + item.x * fw).clamp(fx, fx + fw - bw).toDouble();
    final y = (fy + item.y * fh).clamp(fy, fy + fh - bh).toDouble();
    return (x, y, bw, bh);
  }
}
