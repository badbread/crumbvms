// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Saved window bounds round-trip, and junk or tiny values are ignored.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/state/window_state.dart';

void main() {
  test('bounds round-trip', () {
    const r = Rect.fromLTWH(-1600, 40, 1440, 900);
    expect(decodeBounds(encodeBounds(r)), r);
  });

  test('malformed or tiny bounds are ignored', () {
    expect(decodeBounds(null), isNull);
    expect(decodeBounds(''), isNull);
    expect(decodeBounds('1,2,3'), isNull);
    expect(decodeBounds('a,b,c,d'), isNull);
    expect(decodeBounds('0,0,100,100'), isNull);
  });
}
