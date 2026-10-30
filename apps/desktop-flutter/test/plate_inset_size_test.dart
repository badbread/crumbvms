// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The LPR grid's plate inset takes the crop's own shape, so the crop fills
// it with no black bars beside the plate.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/plates/plates_prefs.dart';
import 'package:crumb_desktop/ui/plates/plates_screen.dart';

void main() {
  test('inset matches the crop aspect', () {
    for (final aspect in [1.6, 2.0, 2.4, 3.5]) {
      for (final size in PlateCropSize.values) {
        final s = plateInsetSize(
          cardWidth: 236,
          frameHeight: 140,
          size: size,
          aspect: aspect,
        );
        expect(s.width / s.height, closeTo(aspect, 0.01), reason: '$size $aspect');
      }
    }
  });

  test('larger size steps are larger', () {
    double area(PlateCropSize s) {
      final r = plateInsetSize(cardWidth: 236, frameHeight: 140, size: s, aspect: 2.2);
      return r.width * r.height;
    }

    expect(area(PlateCropSize.medium), greaterThan(area(PlateCropSize.small)));
    expect(area(PlateCropSize.large), greaterThan(area(PlateCropSize.medium)));
  });

  test('unknown aspect falls back to a plate-like shape within bounds', () {
    final s = plateInsetSize(cardWidth: 236, frameHeight: 140, size: PlateCropSize.large, aspect: null);
    expect(s.width, lessThanOrEqualTo(236 * 0.62 + 0.01));
    expect(s.height, lessThanOrEqualTo(140 * 0.46 + 0.01));
  });
}
