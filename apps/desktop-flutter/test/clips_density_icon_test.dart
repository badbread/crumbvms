// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Clips tile-size button shows the current size (it used to be a fixed
// grid icon whatever the setting).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/clips/clips_screen.dart';

void main() {
  test('each tile size has its own icon and label', () {
    final icons = ClipsDensity.values.map(clipsDensityIcon).toSet();
    expect(icons.length, ClipsDensity.values.length);
    expect(clipsDensityIcon(ClipsDensity.compact), Icons.apps);
    expect(clipsDensityIcon(ClipsDensity.normal), Icons.grid_view);
    expect(clipsDensityIcon(ClipsDensity.large), Icons.crop_square);
    expect(clipsDensityLabel(ClipsDensity.compact), 'small');
    expect(clipsDensityLabel(ClipsDensity.large), 'large');
  });
}
