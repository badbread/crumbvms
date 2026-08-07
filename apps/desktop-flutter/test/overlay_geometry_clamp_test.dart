// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression test for the tag-blocking desktop crash where an oversized HA
// pill badge threw out of `OverlayGeometry.rectFor`.
//
// `rectFor` positions a badge's rendered box inside its anchor "field" with
// `pos.clamp(fx, fx + fw - bw)`. When the rendered box is WIDER than the field
// (`bw > fw`) the upper limit `fx + fw - bw` falls below the lower limit `fx`,
// and Dart's `num.clamp` throws `ArgumentError` for `lowerLimit > upperLimit`.
// Because every consumer (view-mode tiles, captions, edit mode, marquee/align)
// routes through `rectFor`, an affected wall tile rendered Flutter's red error
// widget every frame — and since the placement is server-stored, a small grid
// tile could not be recovered from the broken tile.
//
// Both `wide` (8x height) mode and large `overlay_size` are legal/shipped
// (migration 0078). PR #534's larger pill widths made `bw > fw` readily
// reachable. The same inverted-clamp latent bug also applies to the Y axis for
// a very tall badge. The fix pins an oversized box to the field origin on the
// affected axis instead of inverting the clamp — the pill already ellipsizes,
// so field-edge is the correct visual degrade.
//
// These are pure, headless, deterministic assertions.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_controller.dart';
import 'package:crumb_desktop/ui/overlay_editor/overlay_geometry.dart';

HaOverlayBadgeItem _pill({
  required double size,
  String? widthMode,
  String label = 'Floodlight Garage',
  double x = 0.46,
  double y = 0.46,
}) {
  return HaOverlayBadgeItem(
    HaLink(
      id: 'test-link',
      entityId: 'binary_sensor.floodlight',
      role: 'sensor',
      sortOrder: 0,
      overlaySize: size,
      overlayShape: 'pill',
      overlayPillWidth: widthMode,
      overlayX: x,
      overlayY: y,
      label: label,
    ),
  );
}

HaOverlayBadgeItem _dot({
  required double size,
  double x = 0.46,
  double y = 0.46,
}) {
  return HaOverlayBadgeItem(
    HaLink(
      id: 'test-dot',
      entityId: 'binary_sensor.floodlight',
      role: 'sensor',
      sortOrder: 0,
      overlaySize: size,
      overlayShape: 'dot',
      overlayX: x,
      overlayY: y,
    ),
  );
}

void main() {
  group('rectFor never throws for an oversized badge (PR #534 crash)', () {
    test('wide pill @ overlay_size 4.0 on a 250x140 tile does not throw', () {
      final item = _pill(size: 4.0, widthMode: 'wide');
      const paneW = 250.0, paneH = 140.0;
      const vw = 1920, vh = 1080;

      // Confirm this really is the oversized (bw > fw) case the crash needs.
      final (rw, _) = item.renderedSize(OverlayGeometry.paneScale(paneW, paneH));
      final (fx, fy, fw, fh) =
          OverlayGeometry.fieldRect(item.anchor, paneW, paneH, videoW: vw, videoH: vh);
      expect(rw, greaterThan(fw),
          reason: 'test must exercise bw > fw to be a real regression guard');

      late (double, double, double, double) r;
      expect(
        () => r = OverlayGeometry.rectFor(item, paneW, paneH, videoW: vw, videoH: vh),
        returnsNormally,
      );
      final (rx, ry, rbw, rbh) = r;
      // All finite, size preserved (only position is clamped, not the box).
      expect(rx.isFinite && ry.isFinite && rbw.isFinite && rbh.isFinite, isTrue);
      // Oversized on X -> pinned to the field's left edge.
      expect(rx, closeTo(fx, 1e-9));
      // Y is normal-sized -> stays within the field span.
      expect(ry, greaterThanOrEqualTo(fy));
      expect(ry, lessThanOrEqualTo(fy + fh));
    });

    test('auto pill @ overlay_size 8.0 on a 320x180 tile does not throw', () {
      final item = _pill(size: 8.0, widthMode: null); // null == 'auto'
      const paneW = 320.0, paneH = 180.0;
      const vw = 1920, vh = 1080;

      final (rw, _) = item.renderedSize(OverlayGeometry.paneScale(paneW, paneH));
      final (fx, fy, fw, fh) =
          OverlayGeometry.fieldRect(item.anchor, paneW, paneH, videoW: vw, videoH: vh);
      expect(rw, greaterThan(fw),
          reason: 'test must exercise bw > fw to be a real regression guard');

      late (double, double, double, double) r;
      expect(
        () => r = OverlayGeometry.rectFor(item, paneW, paneH, videoW: vw, videoH: vh),
        returnsNormally,
      );
      final (rx, ry, _, _) = r;
      expect(rx.isFinite && ry.isFinite, isTrue);
      expect(rx, closeTo(fx, 1e-9)); // pinned to left edge
      expect(ry, greaterThanOrEqualTo(fy));
      expect(ry, lessThanOrEqualTo(fy + fh));
    });

    test('a very TALL badge does not throw on the Y axis (same latent bug)', () {
      // A wide-aspect video letterboxes to a SHORT field, so a square dot's
      // rendered height exceeds the field height (bh > fh) while its width
      // still fits (bw < fw) — isolating the Y-axis inversion.
      final item = _dot(size: 2.0);
      const paneW = 400.0, paneH = 400.0;
      const vw = 1920, vh = 120; // very wide -> short letterbox

      final s = OverlayGeometry.paneScale(paneW, paneH);
      final (rw, rh) = item.renderedSize(s);
      final (fx, fy, fw, fh) =
          OverlayGeometry.fieldRect(item.anchor, paneW, paneH, videoW: vw, videoH: vh);
      expect(rh, greaterThan(fh),
          reason: 'test must exercise bh > fh (tall badge)');
      expect(rw, lessThan(fw), reason: 'width must still fit to isolate the Y axis');

      late (double, double, double, double) r;
      expect(
        () => r = OverlayGeometry.rectFor(item, paneW, paneH, videoW: vw, videoH: vh),
        returnsNormally,
      );
      final (rx, ry, _, _) = r;
      expect(ry, closeTo(fy, 1e-9)); // oversized on Y -> pinned to top edge
      expect(rx, greaterThanOrEqualTo(fx)); // width fits -> normal X clamp
      expect(rx, lessThanOrEqualTo(fx + fw));
    });
  });

  test('a normal-sized badge is positioned exactly as before the fix', () {
    // For a box that fits (bw < fw, bh < fh) the new order-safe clamp must be
    // byte-identical to the old `pos.clamp(fx, fx + fw - bw)`. Recompute that
    // pre-fix expression independently and assert rectFor matches it.
    final item = _dot(size: 1.0, x: 0.5, y: 0.5);
    const paneW = 320.0, paneH = 180.0;
    const vw = 1280, vh = 720;

    final s = OverlayGeometry.paneScale(paneW, paneH);
    final (rw, rh) = item.renderedSize(s);
    final bw = rw.clamp(OverlayGeometry.minRenderedPx, double.infinity).toDouble();
    final bh = rh.clamp(OverlayGeometry.minRenderedPx, double.infinity).toDouble();
    final (fx, fy, fw, fh) =
        OverlayGeometry.fieldRect(item.anchor, paneW, paneH, videoW: vw, videoH: vh);
    // Sanity: this really is the normal (fits) case.
    expect(bw, lessThan(fw));
    expect(bh, lessThan(fh));

    final expectedX = (fx + item.x * fw).clamp(fx, fx + fw - bw).toDouble();
    final expectedY = (fy + item.y * fh).clamp(fy, fy + fh - bh).toDouble();

    final (rx, ry, rbw, rbh) =
        OverlayGeometry.rectFor(item, paneW, paneH, videoW: vw, videoH: vh);
    expect(rx, closeTo(expectedX, 1e-12));
    expect(ry, closeTo(expectedY, 1e-12));
    expect(rbw, closeTo(bw, 1e-12));
    expect(rbh, closeTo(bh, 1e-12));
  });
}
