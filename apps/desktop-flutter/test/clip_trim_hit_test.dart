// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Which part of the clip trim timeline a press grabs.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/export/clip_trim_timeline.dart';

void main() {
  TrimTarget hit(double dx) => trimHitTest(dx: dx, startX: 100, endX: 300);

  test('presses near an edge grab that handle', () {
    expect(hit(100), TrimTarget.start);
    expect(hit(92), TrimTarget.start); // on the bar, just outside the edge
    expect(hit(111), TrimTarget.start);
    expect(hit(300), TrimTarget.end);
    expect(hit(308), TrimTarget.end);
  });

  test('presses elsewhere move the playhead', () {
    expect(hit(50), TrimTarget.playhead);
    expect(hit(200), TrimTarget.playhead);
    expect(hit(400), TrimTarget.playhead);
  });

  test('a very short selection still lets both handles be grabbed', () {
    TrimTarget h(double dx) => trimHitTest(dx: dx, startX: 200, endX: 206);
    expect(h(195), TrimTarget.start);
    expect(h(211), TrimTarget.end);
    expect(h(202), TrimTarget.start);
    expect(h(204), TrimTarget.end);
  });
}
