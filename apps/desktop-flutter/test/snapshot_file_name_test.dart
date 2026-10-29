// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Snapshots are saved as "<camera> <local date> <time>.jpg", safe on Windows,
// and never overwrite each other.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/services/snapshot_service.dart';

void main() {
  test('camera name and local frame time', () {
    final at = DateTime(2026, 10, 29, 13, 45, 7);
    expect(
      snapshotFileName('.08 Front Yard', at),
      '.08 Front Yard 2026-10-29 13.45.07.jpg',
    );
  });

  test('a UTC instant is named in local time', () {
    final utc = DateTime.utc(2026, 10, 29, 20, 45, 7);
    expect(
      snapshotFileName('Gate', utc),
      snapshotFileName('Gate', utc.toLocal()),
    );
  });

  test('forbidden characters are replaced', () {
    final at = DateTime(2026, 1, 2, 3, 4, 5);
    expect(
      snapshotFileName(r'Side/Gate: "east"', at),
      'Side_Gate_ _east_ 2026-01-02 03.04.05.jpg',
    );
    expect(snapshotFileName('   ', at), 'Camera 2026-01-02 03.04.05.jpg');
  });

  test('a second snapshot in the same second gets a number', () {
    final dir = Directory.systemTemp.createTempSync('crumb_snap_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sep = Platform.pathSeparator;
    expect(uniqueSnapshotPath(dir.path, 'a.jpg'), '${dir.path}${sep}a.jpg');
    File('${dir.path}${sep}a.jpg').writeAsStringSync('x');
    expect(uniqueSnapshotPath(dir.path, 'a.jpg'), '${dir.path}${sep}a (2).jpg');
  });
}
