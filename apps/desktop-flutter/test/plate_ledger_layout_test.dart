// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Layout tests for the plate desk list (plate_ledger.dart): every Density, at
// narrow and wide list widths, with the worst-case marks (NEW + WATCHLIST +
// Nx TODAY + UNUSUAL HOUR + a long name), grouped heads and expanded child
// rows, must lay out without a RenderFlex overflow. Headless CI cannot look
// at the page, so this is the guard against a row that only breaks at one
// width. Reads carry no event id, so nothing touches the network.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plate_desk_api.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_collapse.dart';
import 'package:crumb_desktop/ui/plates/plate_desk_logic.dart';
import 'package:crumb_desktop/ui/plates/plates_screen.dart';

PlateRead _read(String plate, {String? name, int minAgo = 0}) => PlateRead(
  id: '$plate-$minAgo',
  cameraId: 'cam',
  ts: DateTime.now().subtract(Duration(minutes: minAgo)),
  plate: plate,
  plateRaw: plate,
  confidence: 0.93,
  region: 'CA',
  sourceId: 'crumb-alpr',
  eventId: null,
  snapshotUrl: null,
  displayName: name,
  bbox: const [0.4, 0.6, 0.1, 0.05],
);

PlateStats _busyStats() {
  // New today, 4 reads today, and an hour histogram that makes any hour but
  // 17 unusual.
  final hours = List<int>.filled(24, 0)..[17] = 40;
  final days = List<int>.filled(30, 0)..[29] = 44;
  return PlateStats(
    plate: 'WWWWWWWWWW',
    total: 44,
    seen7d: 44,
    seen30d: 44,
    firstSeen: DateTime.now().subtract(const Duration(hours: 3)),
    lastSeen: DateTime.now(),
    prevSeen: null,
    cameras: const [],
    hours: hours,
    days30: days,
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1800, 900));
  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        color: Colors.black,
        child: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final long = _read(
    'WWWWWWWWWW',
    name: 'A very long operator name for the delivery van from next door',
  );
  final group = PlateGroup(long, [long, _read('WWWWWWWWWW', minAgo: 1)]);
  final bundleGroups = [
    group,
    PlateGroup(_read('WWWWWWWWWW', minAgo: 40), [
      _read('WWWWWWWWWW', minAgo: 40),
    ]),
  ];
  final head = flattenLedger(bundleGroups, groupByPlate: true).first;
  final child = flattenLedger(
    bundleGroups,
    groupByPlate: true,
    expanded: {'WWWWWWWWWW'},
  )[1];

  for (final density in PlateDensity.values) {
    for (final width in [560.0, 760.0, 980.0, 1600.0]) {
      testWidgets('${density.name} row at $width px lays out', (tester) async {
        for (final entry in [LedgerEntry(group: group), head, child]) {
          for (final stats in [_busyStats(), null]) {
            await _pump(
              tester,
              debugLedgerRow(
                entry: entry,
                density: density,
                width: width,
                stats: stats,
                watched: true,
                selected: true,
                statsUnsupported: stats == null,
              ),
            );
            expect(tester.takeException(), isNull);
          }
        }
        await tester.binding.setSurfaceSize(null);
      });
    }
  }

  for (final width in [560.0, 760.0, 1200.0]) {
    testWidgets('header and column titles at $width px lay out', (
      tester,
    ) async {
      final o = LprOverview.fromJson({
        'day': '2026-10-29',
        'tz': 'UTC',
        'reads_today': 123456,
        'unique_today': 8765,
        'new_today': 4321,
        'watchlist_hits_today': 99,
        'split': {'regulars': 3000, 'returning': 1444, 'first_time': 4321},
        'regular_min_reads_30d': 5,
      });
      await _pump(tester, debugDeskHeader(o, width: width));
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });
  }

  test('optional columns drop crop last, frame first', () {
    final l = densityMetrics(PlateDensity.large);
    final wide = ledgerColumns(l, 1600);
    expect(wide.frame && wide.crop && wide.spark, isTrue);
    final mid = ledgerColumns(l, 900);
    expect(mid.crop, isTrue);
    expect(mid.frame, isFalse);
    final c = ledgerColumns(densityMetrics(PlateDensity.compact), 1600);
    expect(c.frame || c.crop, isFalse);
    expect(c.spark, isTrue);
  });
}
