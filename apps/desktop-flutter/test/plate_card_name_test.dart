// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Grid cards: a known name sits on its own line under the plate (accent tag
// icon + name). Only that line scrolls, and only when the name overflows;
// unnamed cards keep their own height even in a slot that reserves the line.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_collapse.dart';
import 'package:crumb_desktop/ui/plates/plate_desk_logic.dart';
import 'package:crumb_desktop/ui/plates/plates_screen.dart';

PlateRead _read({String? name}) => PlateRead(
  id: 'r1',
  cameraId: 'cam',
  ts: DateTime.now(),
  plate: 'GIF2GAB',
  plateRaw: 'GIF2GAB',
  confidence: 0.97,
  region: 'CA',
  sourceId: 'crumb-alpr',
  eventId: null,
  snapshotUrl: null,
  displayName: name,
  bbox: const [0.4, 0.6, 0.1, 0.05],
);

Future<void> _pump(WidgetTester tester, Widget card) async {
  await tester.binding.setSurfaceSize(const Size(900, 600));
  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        color: Colors.black,
        child: Align(alignment: Alignment.topLeft, child: card),
      ),
    ),
  );
  await tester.pump();
}

LedgerEntry _entry(String? name) {
  final r = _read(name: name);
  return LedgerEntry(group: PlateGroup(r, [r]));
}

/// The plate in the card footer (15 px; the inset tile also spells it).
Finder get _footerPlate => find.byWidgetPredicate(
  (w) => w is Text && w.data == 'GIF2GAB' && w.style?.fontSize == 15,
);

void main() {
  const long = 'Charles · white Tesla Model Y from next door';

  testWidgets('short name: own line, no scrolling', (tester) async {
    await _pump(tester, debugSheetCard(entry: _entry('Charles'), width: 260));
    expect(find.text('Charles'), findsOneWidget);
    expect(find.byIcon(Icons.sell_outlined), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('long name scrolls; the plate does not move', (tester) async {
    await _pump(tester, debugSheetCard(entry: _entry(long), width: 260));
    expect(find.byType(ShaderMask), findsOneWidget);
    final plateX = tester.getTopLeft(_footerPlate).dx;
    final nameX = tester.getTopLeft(find.text(long)).dx;
    await tester.pump(const Duration(seconds: 5));
    expect(tester.getTopLeft(_footerPlate).dx, plateX);
    expect(tester.getTopLeft(find.text(long)).dx, lessThan(nameX));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('unnamed card has no name line and keeps its height', (
    tester,
  ) async {
    await _pump(tester, debugSheetCard(entry: _entry(null), width: 260));
    expect(find.byIcon(Icons.sell_outlined), findsNothing);
    final plain = tester.getSize(find.byKey(const ValueKey('sheet-card-body')));

    // Same card in a slot that reserves the name line (a named neighbour).
    await _pump(
      tester,
      debugSheetCard(entry: _entry(null), width: 260, reserveNameLine: true),
    );
    final reserved = tester.getSize(
      find.byKey(const ValueKey('sheet-card-body')),
    );
    expect(reserved, plain);

    // A named card is exactly one name line taller.
    await _pump(tester, debugSheetCard(entry: _entry('Charles'), width: 260));
    final named = tester.getSize(find.byKey(const ValueKey('sheet-card-body')));
    expect(named.height - plain.height, 18);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}
