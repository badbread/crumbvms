// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Hover behaviour of the plate profile's 30-day bars and hour clock.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plate_desk_api.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plates_screen.dart';

PlateStats _stats() {
  final hours = List<int>.filled(24, 0)
    ..[14] = 37
    ..[3] = 5;
  final days = List<int>.filled(30, 0)
    ..[29] = 44
    ..[10] = 17;
  return PlateStats(
    plate: 'ABC123',
    total: 61,
    seen7d: 44,
    seen30d: 61,
    firstSeen: DateTime.now().subtract(const Duration(days: 20)),
    lastSeen: DateTime.now(),
    prevSeen: null,
    cameras: const [],
    hours: hours,
    days30: days,
  );
}

Future<void> _pumpProfile(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1300, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final focus = PlateRead(
    id: 'r',
    cameraId: 'cam',
    ts: DateTime.now(),
    plate: 'ABC123',
    plateRaw: 'ABC123',
    confidence: 0.9,
    region: 'CA',
    sourceId: 'crumb-alpr',
    eventId: null,
    snapshotUrl: null,
    displayName: null,
    bbox: const [0.4, 0.6, 0.1, 0.05],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: debugPlateProfile(focus: focus, stats: _stats()),
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

void main() {
  wideLayoutTest();
  testWidgets('hovering a day column shows its count, exit hides it', (
    tester,
  ) async {
    await _pumpProfile(tester);
    expect(find.text('61 reads'), findsOneWidget);

    final dayChart = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_DayBarsChart',
    );
    final box = tester.getRect(
      find
          .descendant(
            of: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_DayBarsChart',
            ),
            matching: find.byType(MouseRegion),
          )
          .first,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    // last column = today
    await mouse.moveTo(Offset(box.right - 2, box.center.dy));
    await tester.pumpAndSettle();
    final tip = find.descendant(of: dayChart, matching: find.text('44'));
    expect(tip, findsOneWidget);
    expect(find.text('Today'), findsNWidgets(2)); // tooltip + footer
    expect(find.text('61 reads'), findsNothing);

    await mouse.moveTo(Offset(box.left + 1, box.center.dy));
    await tester.pumpAndSettle();
    expect(tip, findsNothing);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('61 reads'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
  });

  testWidgets('hovering a wedge shows the hour in the centre, exit restores', (
    tester,
  ) async {
    await _pumpProfile(tester);
    expect(find.text('24 h'), findsOneWidget);
    expect(find.text('by hour'), findsOneWidget);
    expect(find.text('Peak 2 PM  ·  midnight at the top'), findsOneWidget);

    final rect = tester.getRect(
      find
          .descendant(
            of: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_HourClock',
            ),
            matching: find.byType(MouseRegion),
          )
          .first,
    );
    final c = rect.center;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    // 14:00 = 210 deg clockwise from the top; radius 80 (between disc and edge).
    // dx = r*sin(210deg) = -40, dy = -r*cos(210deg) = +69.28
    await mouse.moveTo(c + const Offset(-40, 69.28));
    await tester.pumpAndSettle();
    expect(find.text('2 PM'), findsOneWidget);
    expect(find.text('37 reads'), findsOneWidget);
    expect(find.text('2 PM to 3 PM'), findsOneWidget);
    expect(find.text('24 h'), findsNothing);

    // Inside the disc: no wedge.
    await mouse.moveTo(c);
    await tester.pumpAndSettle();
    expect(find.text('24 h'), findsOneWidget);
    expect(find.text('by hour'), findsOneWidget);
    expect(find.text('Peak 2 PM  ·  midnight at the top'), findsOneWidget);

    await mouse.moveTo(c + const Offset(-40, 69.28));
    await tester.pumpAndSettle();
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('24 h'), findsOneWidget);
  });
}

void wideLayoutTest() {
  for (final width in [1456.0, 1600.0, 1900.0]) {
    testWidgets('wide profile at $width: visits fill the row, rows do not clip', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PlateRead read(int i) => PlateRead(
        id: 'r$i',
        cameraId: 'cam',
        // Far apart so every read is its own visit.
        ts: DateTime.now().subtract(Duration(hours: 5 * i)),
        plate: 'ABC123',
        plateRaw: 'ABC123',
        confidence: 1.0,
        region: 'CA',
        sourceId: 'crumb-alpr',
        eventId: null,
        snapshotUrl: null,
        displayName: null,
        bbox: const [0.4, 0.6, 0.1, 0.05],
      );
      final reads = [for (var i = 0; i < 6; i++) read(i)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: debugPlateProfile(
              focus: reads.first,
              stats: _stats(),
              reads: reads,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      final hero = tester.getRect(find.byKey(const ValueKey('profile-hero')));
      final visits = tester.getRect(
        find.byKey(const ValueKey('profile-visits')),
      );
      expect(visits.left, greaterThanOrEqualTo(hero.right));
      expect(visits.top, closeTo(hero.top, 1));
      expect(visits.height, closeTo(hero.height, 1));
      expect(visits.width, greaterThanOrEqualTo(320));
      // 16:9 video, no letterbox: the box is as wide as the video needs.
      expect(hero.width / (hero.height - 34), closeTo(16 / 9, 0.02));
      // The hero row spans the same width as the stats cards below it.
      final hour = find.ancestor(
        of: find.text('HOUR OF DAY'),
        matching: find.byType(Container),
      );
      final cardRight = tester.getRect(hour.first).right;
      expect(visits.right, closeTo(cardRight, 1));
      // Visit meta ellipsizes or fits; it is never hard-clipped.
      final meta = find.textContaining(' read, 100%');
      expect(meta, findsWidgets);
      for (final e in meta.evaluate()) {
        final box = e.renderObject! as RenderBox;
        final r = box.localToGlobal(Offset.zero) & box.size;
        expect(r.right, lessThanOrEqualTo(visits.right));
      }
    });
  }
}
