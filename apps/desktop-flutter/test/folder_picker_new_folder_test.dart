// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The export folder picker's New folder action: name validation, and creating
// a folder in the open directory then stepping into it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/folder_picker_dialog.dart';

void main() {
  group('folderNameError', () {
    test('accepts ordinary names', () {
      expect(folderNameError('Driveway 2026-10-29'), isNull);
      expect(folderNameError('  exports  '), isNull);
      expect(folderNameError('con.d'), isNull);
    });
    test('rejects empty and dot names', () {
      expect(folderNameError(''), isNotNull);
      expect(folderNameError('   '), isNotNull);
      expect(folderNameError('.'), isNotNull);
      expect(folderNameError('..'), isNotNull);
      expect(folderNameError('clip.'), isNotNull);
    });
    test('rejects characters Windows forbids', () {
      for (final c in ['<', '>', ':', '"', '/', r'\', '|', '?', '*', '\t']) {
        expect(folderNameError('a${c}b'), isNotNull, reason: 'char $c');
      }
    });
    test('rejects Windows reserved device names, with or without extension', () {
      expect(folderNameError('CON'), isNotNull);
      expect(folderNameError('nul'), isNotNull);
      expect(folderNameError('com1'), isNotNull);
      expect(folderNameError('LPT9.txt'), isNotNull);
      expect(folderNameError('COM10'), isNull);
    });
  });

  testWidgets('New folder creates the folder and opens it', (tester) async {
    final root = Directory.systemTemp.createTempSync('crumb_picker_');
    addTearDown(() => root.deleteSync(recursive: true));

    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                picked = await pickFolderInApp(context, initialPath: root.path),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // Directory listing is real IO; let it finish outside the fake clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Front yard');
    await tester.tap(find.text('Create'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    final created = Directory('${root.path}${Platform.pathSeparator}Front yard');
    expect(created.existsSync(), isTrue);

    await tester.tap(find.text('Use this folder'));
    await tester.pumpAndSettle();
    expect(picked, created.path);
  });
}
