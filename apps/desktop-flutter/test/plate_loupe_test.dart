// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Hovering a grid card's frame with the loupe on shows the round magnifier.

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_collapse.dart';
import 'package:crumb_desktop/ui/plates/plate_desk_logic.dart';
import 'package:crumb_desktop/ui/plates/plates_screen.dart';

// 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('hovering the frame shows the loupe', (tester) async {
    debugSeedSnapshot('ev1', _png);
    final read = PlateRead(
      id: 'r1',
      cameraId: 'cam',
      ts: DateTime.now(),
      plate: 'ABC123',
      plateRaw: 'ABC123',
      confidence: 0.9,
      region: 'CA',
      sourceId: 'crumb-alpr',
      eventId: 'ev1',
      snapshotUrl: null,
      displayName: null,
      bbox: const [0.4, 0.6, 0.1, 0.05],
    );
    final entry = LedgerEntry(group: PlateGroup(read, [read]));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: debugSheetCard(entry: entry, width: 300),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ClipOval), findsNothing);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(400, 400));
    await gesture.moveTo(const Offset(150, 70));
    await tester.pump();
    await gesture.moveTo(const Offset(160, 80));
    await tester.pump();
    expect(find.byType(ClipOval), findsOneWidget);
    await gesture.removePointer();
  });
}
