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
      expect(folderNameError('icons'), isNull);
      expect(folderNameError('console'), isNull);
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
    test(
      'rejects Windows reserved device names, with or without extension',
      () {
        expect(folderNameError('CON'), isNotNull);
        expect(folderNameError('nul'), isNotNull);
        expect(folderNameError('com1'), isNotNull);
        expect(folderNameError('LPT9.txt'), isNotNull);
        expect(folderNameError('COM10'), isNull);
      },
    );
  });

  testWidgets('New folder creates the folder and opens it', (tester) async {
    final root = Directory.systemTemp.createTempSync('crumb_picker_');
    addTearDown(() => root.deleteSync(recursive: true));

    // The picker does real directory IO, which the fake test clock never
    // advances, and the name field's blinking cursor never settles. So
    // alternate real waits with frame pumps until [done] holds.
    Future<void> pumpUntil(bool Function() done) async {
      for (var i = 0; i < 50 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(done(), isTrue);
    }

    String? picked;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await pickFolderInApp(context, initialPath: root.path);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await pumpUntil(
      () => find.text('No sub-folders here.').evaluate().isNotEmpty,
    );

    await tester.tap(find.text('New folder'));
    await pumpUntil(() => find.text('Create').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField).last, 'Front yard');
    await tester.tap(find.text('Create'));

    final created = Directory(
      '${root.path}${Platform.pathSeparator}Front yard',
    );
    // Created, stepped into (the path line shows it), and empty.
    await pumpUntil(
      () =>
          find.text('Use: ${created.path}').evaluate().isNotEmpty &&
          find.text('No sub-folders here.').evaluate().isNotEmpty,
    );
    expect(created.existsSync(), isTrue);

    await tester.tap(find.text('Use this folder'));
    await pumpUntil(() => closed);
    expect(picked, created.path);
  });
}
