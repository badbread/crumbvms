// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Add/Edit clip dialog shows the clip range in LOCAL time. The playback
// screen hands it UTC instants, which it used to print as-is: an operator in
// San Francisco saw 19:49 for footage the camera stamped 12:49.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/export/export_builder_dialog.dart';

void main() {
  test('a UTC instant is shown in local time', () {
    final utc = DateTime.utc(2026, 10, 29, 19, 49, 18);
    final l = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    expect(
      fmtClipDateTime(utc),
      '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}:${two(l.second)}',
    );
    // UTC and local values for the same instant print identically.
    expect(fmtClipDateTime(utc), fmtClipDateTime(l));
  });

  test('clip durations', () {
    expect(fmtClipDuration(const Duration(seconds: 102)), '1m 42s');
    expect(fmtClipDuration(const Duration(seconds: 46)), '46s');
    expect(fmtClipDuration(Duration.zero), '0s');
    expect(fmtClipDuration(const Duration(minutes: 5)), '5m');
    expect(fmtClipDuration(const Duration(hours: 1, minutes: 2)), '1h 2m');
  });
}
