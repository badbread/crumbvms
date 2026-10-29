// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Export downloads are saved under readable names that are safe on Windows,
// and never overwrite an earlier export.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/export/export_screen.dart';

void main() {
  group('safeFileName', () {
    test('keeps a readable name as-is', () {
      expect(
        safeFileName('Front Yard 2026-10-29 12.47.02-12.48.40.mp4'),
        'Front Yard 2026-10-29 12.47.02-12.48.40.mp4',
      );
    });
    test('replaces separators and forbidden characters', () {
      expect(safeFileName(r'a/b\c:d*e?.mp4'), 'a_b_c_d_e_.mp4');
      expect(safeFileName(r'..\..\evil.mp4'), '.._.._evil.mp4');
    });
    test('trims trailing dots and spaces, collapses whitespace', () {
      expect(safeFileName('  Side   gate . '), 'Side gate');
    });
    test('guards Windows reserved names', () {
      expect(safeFileName('CON.mp4'), '_CON.mp4');
      expect(safeFileName('nul'), '_nul');
    });
    test('never returns empty', () {
      expect(safeFileName('...'), 'export');
    });
  });

  test('uniquePath numbers a clash instead of overwriting', () {
    final dir = Directory.systemTemp.createTempSync('crumb_export_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sep = Platform.pathSeparator;
    expect(uniquePath(dir.path, 'clip.mp4'), '${dir.path}${sep}clip.mp4');
    File('${dir.path}${sep}clip.mp4').writeAsStringSync('x');
    expect(uniquePath(dir.path, 'clip.mp4'), '${dir.path}${sep}clip (2).mp4');
    File('${dir.path}${sep}clip (2).mp4').writeAsStringSync('x');
    expect(uniquePath(dir.path, 'clip.mp4'), '${dir.path}${sep}clip (3).mp4');
  });
}
