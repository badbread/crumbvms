// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Plates filter bar is ONE 48 px row at every width: captions and full
// labels when wide, icon toggles with tooltips when narrow, and never a wrap
// or a RenderFlex overflow (headless CI cannot look at the page, so this is
// the guard).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/ui/plates/plate_desk_logic.dart';
import 'package:crumb_desktop/ui/plates/plates_prefs.dart';
import 'package:crumb_desktop/ui/plates/plates_screen.dart';

Future<Size> _pump(
  WidgetTester tester,
  double width, {
  PlatesViewMode view = PlatesViewMode.list,
  DeskFilter filter = DeskFilter.all,
  bool anchored = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 300));
  await tester.pumpWidget(
    MaterialApp(
      // Flutter's test font (Ahem) is a square 1 em per glyph, ~1.8x wider
      // than the UI font, so scale text down to a realistic width.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(0.55)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const Key('bar'),
            width: width,
            child: debugPlatesFilterBar(
              viewMode: view,
              deskFilter: filter,
              anchored: anchored,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.getSize(find.byKey(const Key('bar')));
}

void main() {
  for (final width in [1100.0, 1280.0, 1500.0, 1760.0, 1900.0]) {
    for (final view in PlatesViewMode.values) {
      testWidgets('one row, no overflow at $width px (${view.name})', (
        tester,
      ) async {
        final size = await _pump(tester, width, view: view);
        expect(tester.takeException(), isNull);
        expect(size.height, 48);
        await tester.binding.setSurfaceSize(null);
      });
    }

    testWidgets('anchored range + active filter at $width px', (tester) async {
      final size = await _pump(
        tester,
        width,
        filter: DeskFilter.watchlist,
        anchored: true,
      );
      expect(tester.takeException(), isNull);
      expect(size.height, 48);
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets('wide: captions and labelled toggles', (tester) async {
    await _pump(tester, 1900);
    for (final cap in ['MATCH', 'WHEN', 'VIEW', 'SIZE']) {
      expect(find.text(cap), findsOneWidget);
    }
    expect(find.text('Group by plate'), findsOneWidget);
    expect(find.text('Merge duplicates'), findsOneWidget);
    expect(find.text('Hide regulars'), findsOneWidget);
    expect(find.text('Watchlist (2)'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('narrow: captions drop, toggles become icon toggles', (
    tester,
  ) async {
    await _pump(tester, 1100);
    for (final cap in ['MATCH', 'WHEN', 'VIEW', 'SIZE']) {
      expect(find.text(cap), findsNothing);
    }
    expect(find.text('Group by plate'), findsNothing);
    expect(find.byTooltip('Hide regulars'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.call_merge), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('density and merge are list-only', (tester) async {
    await _pump(tester, 1900, view: PlatesViewMode.gallery);
    expect(find.text('SIZE'), findsNothing);
    expect(find.text('Merge duplicates'), findsNothing);
    expect(find.text('Group by plate'), findsOneWidget);
    await _pump(tester, 1900, view: PlatesViewMode.grouped);
    expect(find.text('Group by plate'), findsNothing);
    expect(find.text('Hide regulars'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
