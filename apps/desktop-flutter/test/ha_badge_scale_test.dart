// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression test for the HA badge "pill size-down balloons" bug.
//
// The overlay editor stores each item's geometry as a (w, h) box and, on some
// interactions (notably a dot<->pill shape switch), round-trips it through
// `baseSize()` -> `setBaseSize()`. A pill's baseSize width is much wider than
// its height, so the old `setBaseSize` (which took `max(w, h)`) multiplied the
// persisted scale by the pill's width factor on EVERY round trip — the badge
// ballooned, and a "shrink" could actually enlarge it. The fix derives scale
// from HEIGHT (the shape-invariant): `scale = h / baseRefPx`.
//
// These are pure, headless, deterministic assertions on that math.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_controller.dart';

HaOverlayBadgeItem _badge({
  required String shape,
  double scale = 1.0,
  String label = 'Garage',
}) {
  return HaOverlayBadgeItem(
    HaLink(
      id: 'test-link',
      entityId: 'binary_sensor.garage_door',
      role: 'sensor',
      sortOrder: 0,
      overlaySize: scale,
      overlayShape: shape,
      label: label,
    ),
  );
}

void main() {
  group('HA badge scale is height-derived (pill no longer balloons)', () {
    for (final shape in ['dot', 'pill']) {
      test('$shape: setBaseSize(baseSize()) is a fixed point', () {
        final item = _badge(shape: shape, scale: 1.3);
        final (w, h) = item.baseSize();
        item.setBaseSize(w, h);
        // A no-op geometry round-trip (e.g. a shape switch) must leave the
        // persisted scale exactly as it was. The old max(w,h) code failed this
        // for pills (scale grew every round trip) — the balloon bug.
        expect(item.scale, closeTo(1.3, 1e-9));
      });

      test('$shape: halving the box halves the scale (shrinks, never grows)',
          () {
        final item = _badge(shape: shape, scale: 2.0);
        final (w, h) = item.baseSize();
        item.setBaseSize(w * 0.5, h * 0.5);
        expect(item.scale, closeTo(1.0, 1e-9));
        expect(item.scale, lessThan(2.0));
      });
    }

    test('a pill baseSize is wider than tall (why max(w,h) ballooned it)', () {
      final (w, h) = _badge(shape: 'pill', label: 'Front Door').baseSize();
      expect(w, greaterThan(h));
    });
  });
}
