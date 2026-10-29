// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the plate desk logic (plate_desk_logic.dart) and the plate
// desk API parsing (plate_desk_api.dart): stats parsing and classification,
// density metrics, hint rules, group-by-plate flattening, history text, the
// batched 60 s stats cache, and the Density migration from the retired list
// prefs.

import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plate_desk_api.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_collapse.dart';
import 'package:crumb_desktop/ui/plates/plate_desk_logic.dart';
import 'package:crumb_desktop/ui/plates/plates_prefs.dart';

final _t0 = DateTime.utc(2026, 10, 29, 20, 0, 0);

PlateRead _read(String plate, {required int minAgo, String camera = 'cam-A'}) {
  return PlateRead(
    id: '$plate-$camera-$minAgo',
    cameraId: camera,
    ts: _t0.subtract(Duration(minutes: minAgo)),
    plate: plate,
    plateRaw: plate,
    confidence: 0.9,
    region: null,
    sourceId: 'frigate',
    eventId: null,
    snapshotUrl: null,
    displayName: null,
    bbox: null,
  );
}

PlateGroup _g(PlateRead r) => PlateGroup(r, [r]);

PlateStats _stats({
  int total = 10,
  int seen30d = 6,
  List<int>? days30,
  List<int>? hours,
  DateTime? prev,
  DateTime? first,
}) {
  final d = days30 ?? (List<int>.filled(30, 0)..[29] = 1);
  return PlateStats(
    plate: 'ABC123',
    total: total,
    seen7d: 0,
    seen30d: seen30d,
    firstSeen: first ?? DateTime.utc(2026, 6, 3, 17),
    lastSeen: _t0,
    prevSeen: prev,
    cameras: const [],
    hours: hours ?? List<int>.filled(24, 0),
    days30: d,
  );
}

void main() {
  group('stats parsing', () {
    test('parses the full response, keyed by plate', () {
      final days = List<int>.generate(
        30,
        (i) => i == 29 ? 2 : (i == 10 ? 3 : 0),
      );
      final hours = List<int>.generate(24, (i) => i == 17 ? 4 : 0);
      final m = parsePlateStatsResponse({
        'tz': 'America/Los_Angeles',
        'today': '2026-10-29',
        'regular_min_reads_30d': 5,
        'plates': [
          {
            'plate': '9WSL517',
            'total': 14,
            'seen_7d': 2,
            'seen_30d': 5,
            'first_seen': '2026-06-03T17:02:00Z',
            'last_seen': '2026-10-29T19:02:00Z',
            'prev_seen': '2026-10-27T18:00:00Z',
            'cameras': [
              {'camera_id': 'cam-1', 'n': 10},
              {'camera_id': 'cam-2', 'n': 4},
            ],
            'hours': hours,
            'days30': days,
          },
        ],
      });
      final s = m['9WSL517']!;
      expect(s.total, 14);
      expect(s.seen7d, 2);
      expect(s.seen30d, 5);
      expect(s.firstSeen, DateTime.utc(2026, 6, 3, 17, 2));
      expect(s.prevSeen, DateTime.utc(2026, 10, 27, 18));
      expect(s.cameras.map((c) => c.cameraId), ['cam-1', 'cam-2']);
      expect(s.cameras.first.n, 10);
      expect(s.hours[17], 4);
      expect(s.days30, days);
      expect(s.today, 2);
      expect(s.isNew, isFalse);
      expect(s.isRegular, isTrue);
    });

    test('tolerates missing and short arrays, null prev_seen', () {
      final m = parsePlateStatsResponse({
        'plates': [
          {
            'plate': 'X1',
            'total': 1,
            'first_seen': '2026-10-29T10:00:00Z',
            'last_seen': '2026-10-29T10:00:00Z',
            'prev_seen': null,
            'hours': [1, 2],
            'days30': null,
          },
          {'total': 3}, // no plate: dropped
          'junk',
        ],
      });
      expect(m.keys, ['X1']);
      final s = m['X1']!;
      expect(s.prevSeen, isNull);
      expect(s.hours.length, 24);
      expect(s.hours.take(3), [1, 2, 0]);
      expect(s.days30.length, 30);
      expect(s.regularMinReads30d, 5);
    });

    test('overview parsing', () {
      final o = LprOverview.fromJson({
        'day': '2026-10-29',
        'tz': 'UTC',
        'reads_today': 214,
        'unique_today': 87,
        'new_today': 12,
        'watchlist_hits_today': 3,
        'split': {'regulars': 31, 'returning': 44, 'first_time': 12},
        'regular_min_reads_30d': 5,
      });
      expect(o.readsToday, 214);
      expect(o.split.total, 87);
      expect(o.split.firstTime, o.newToday);
    });
  });

  group('classification', () {
    test('new = every read is today', () {
      final s = _stats(
        total: 2,
        seen30d: 2,
        days30: List<int>.filled(30, 0)..[29] = 2,
      );
      expect(s.isNew, isTrue);
      expect(s.isRegular, isFalse);
      expect(plateRail(watched: false, stats: s), PlateRail.newPlate);
    });

    test('regular = seen before today with 5+ in 30 days', () {
      final s = _stats(total: 40, seen30d: 5);
      expect(s.isRegular, isTrue);
      expect(plateRail(watched: false, stats: s), PlateRail.regular);
      expect(_stats(total: 40, seen30d: 4).isReturning, isTrue);
    });

    test('watchlist wins the rail; no stats means no rail', () {
      expect(plateRail(watched: true, stats: _stats()), PlateRail.watchlist);
      expect(plateRail(watched: false), PlateRail.none);
    });

    test('filters', () {
      final reg = _stats(total: 40, seen30d: 9);
      expect(deskFilterMatches(DeskFilter.all, watched: false), isTrue);
      expect(
        deskFilterMatches(DeskFilter.regulars, watched: false, stats: reg),
        isTrue,
      );
      expect(
        deskFilterMatches(DeskFilter.returning, watched: false, stats: reg),
        isFalse,
      );
      expect(deskFilterMatches(DeskFilter.firstTime, watched: false), isFalse);
      expect(deskFilterMatches(DeskFilter.watchlist, watched: true), isTrue);
    });
  });

  group('density', () {
    test('compact is text only and every step grows', () {
      final c = densityMetrics(PlateDensity.compact);
      final s = densityMetrics(PlateDensity.standard);
      final l = densityMetrics(PlateDensity.large);
      expect(c.showImages, isFalse);
      expect(s.showImages && l.showImages, isTrue);
      expect(c.rowExtent < s.rowExtent && s.rowExtent < l.rowExtent, isTrue);
      expect(c.plateFont < s.plateFont && s.plateFont < l.plateFont, isTrue);
      // The crop is obviously bigger, not a few pixels.
      expect(l.cropWidth / s.cropWidth, greaterThan(1.5));
      expect(l.cropHeight / s.cropHeight, greaterThan(1.5));
      // Images fit inside the fixed row height.
      expect(s.frameHeight, lessThan(s.rowExtent));
      expect(l.cropHeight, lessThan(l.rowExtent));
    });

    test('migrates from the retired crop-size pref', () {
      expect(densityFromLegacy('large'), PlateDensity.large);
      expect(densityFromLegacy('small'), PlateDensity.standard);
      expect(densityFromLegacy(null), PlateDensity.standard);
    });
  });

  group('hints', () {
    test('unusual hour needs 10+ reads and a bucket under 3%', () {
      final hours = List<int>.filled(24, 0)..[17] = 40;
      expect(isUnusualHour(hours, 2), isTrue); // 0 of 40
      expect(isUnusualHour(hours, 17), isFalse);
      hours[2] = 2; // 2 of 42 = 4.8%
      expect(isUnusualHour(hours, 2), isFalse);
      final few = List<int>.filled(24, 0)..[17] = 9;
      expect(isUnusualHour(few, 2), isFalse, reason: 'under 10 reads');
      expect(isUnusualHour(hours, 24), isFalse);
    });

    test('Nx TODAY from the second read today, NEW from stats', () {
      final s = _stats(
        total: 4,
        seen30d: 4,
        days30: List<int>.filled(30, 0)..[29] = 4,
      );
      final h = plateHints(s, _t0);
      expect(h.isNew, isTrue);
      expect(h.todayCount, 4);
      expect(h.showToday, isTrue);
      expect(plateHints(_stats(), _t0).showToday, isFalse);
      expect(plateHints(null, _t0).isNew, isFalse);
    });
  });

  group('group by plate', () {
    final groups = [
      _g(_read('AAA', minAgo: 1)),
      _g(_read('BBB', minAgo: 5)),
      _g(_read('AAA', minAgo: 30)),
      _g(_read('', minAgo: 31)),
      _g(_read('AAA', minAgo: 90)),
      _g(_read('', minAgo: 95)),
    ];

    test('bundles keep newest-first order; blank plates stay alone', () {
      final b = bundleByPlate(groups);
      expect(b.map((x) => x.plate), ['AAA', 'BBB', '', '']);
      expect(b.first.passCount, 3);
      expect(b.first.head.representative.id, groups.first.representative.id);
    });

    test('flatten: one row per pass without grouping', () {
      final e = flattenLedger(groups, groupByPlate: false);
      expect(e.length, groups.length);
      expect(e.every((x) => x.bundle == null && !x.isChild), isTrue);
    });

    test('flatten: grouped heads, children only when expanded', () {
      final collapsed = flattenLedger(groups, groupByPlate: true);
      expect(collapsed.length, 4);
      expect(collapsed.first.bundle!.passCount, 3);
      final open = flattenLedger(groups, groupByPlate: true, expanded: {'AAA'});
      expect(open.length, 6);
      expect(open[1].isChild && open[2].isChild, isTrue);
      expect(
        open[1].group.representative.ts.isAfter(
          open[2].group.representative.ts,
        ),
        isTrue,
      );
      expect(open[3].group.representative.plate, 'BBB');
      // Keys stay unique so rows keep their state.
      expect(open.map((x) => x.key).toSet().length, open.length);
    });
  });

  group('text', () {
    test('ago and short dates', () {
      expect(
        fmtAgo(_t0.subtract(const Duration(seconds: 20)), _t0),
        'just now',
      );
      expect(
        fmtAgo(_t0.subtract(const Duration(minutes: 12)), _t0),
        '12 min ago',
      );
      expect(fmtAgo(_t0.subtract(const Duration(hours: 3)), _t0), '3 h ago');
      expect(
        fmtAgo(_t0.subtract(const Duration(days: 2, hours: 1)), _t0),
        '2 d ago',
      );
      final now = DateTime(2026, 10, 29, 12);
      expect(fmtShortDate(DateTime(2026, 6, 3, 9), now), 'Jun 3');
      expect(fmtShortDate(DateTime(2025, 6, 3, 9), now), 'Jun 3, 2025');
      expect(fmtShortDate(DateTime(2026, 10, 29, 1), now), 'today');
      expect(fmtHour(0), '12 AM');
      expect(fmtHour(17), '5 PM');
      expect(fmtHour(12), '12 PM');
    });

    test('history cell', () {
      final now = DateTime(2026, 10, 29, 12);
      final s = _stats(
        total: 14,
        prev: now.subtract(const Duration(days: 2)),
        first: DateTime(2026, 6, 3, 9),
      );
      expect(historyCellText(s, now), (
        '14x seen',
        'prev 2 d ago, first Jun 3',
      ));
      final n = _stats(total: 1, seen30d: 1);
      expect(historyCellText(n, now).$2, 'first seen today');
      expect(historyCellText(null, now), ('-', ''));
    });
  });

  group('stats cache', () {
    test('batches, de-duplicates, honours the TTL', () async {
      var clock = DateTime(2026, 10, 29, 12);
      final calls = <List<String>>[];
      final cache = PlateStatsCache((plates) async {
        calls.add(plates);
        return {for (final p in plates) p: _stats()};
      }, clock: () => clock);
      cache.want(['B', 'A', 'A', '']);
      cache.want(['A']);
      await cache.flush();
      expect(calls, [
        ['A', 'B'],
      ]);
      expect(cache['A'], isNotNull);
      expect(cache.isResolved('B'), isTrue);

      cache.want(['A', 'B']); // fresh: nothing to do
      await cache.flush();
      expect(calls.length, 1);

      clock = clock.add(const Duration(seconds: 61));
      cache.want(['A']);
      await cache.flush();
      expect(calls.length, 2);
      expect(calls.last, ['A']);
      cache.dispose();
    });

    test('splits large requests into 200-plate batches', () async {
      final sizes = <int>[];
      final cache = PlateStatsCache((plates) async {
        sizes.add(plates.length);
        return const {};
      });
      cache.want([for (var i = 0; i < 450; i++) 'P$i']);
      await cache.flush();
      expect(sizes, [200, 200, 50]);
      cache.dispose();
    });

    test('an older server latches unsupported and stops asking', () async {
      var calls = 0;
      final cache = PlateStatsCache((plates) async {
        calls++;
        return null;
      });
      var notified = 0;
      cache.addListener(() => notified++);
      cache.want(['A']);
      await cache.flush();
      expect(cache.unsupported, isTrue);
      expect(notified, 1);
      cache.want(['B']);
      await cache.flush();
      expect(calls, 1);
      cache.dispose();
    });

    test('a failed fetch is not retried until the TTL passes', () async {
      var clock = DateTime(2026, 10, 29, 12);
      var calls = 0;
      final cache = PlateStatsCache((plates) async {
        calls++;
        throw Exception('boom');
      }, clock: () => clock);
      cache.want(['A']);
      await cache.flush();
      cache.want(['A']);
      await cache.flush();
      expect(calls, 1);
      expect(cache.unsupported, isFalse);
      clock = clock.add(const Duration(minutes: 2));
      cache.want(['A']);
      await cache.flush();
      expect(calls, 2);
      cache.dispose();
    });

    test('invalidate drops results that land afterwards', () async {
      final cache = PlateStatsCache((plates) async {
        return {for (final p in plates) p: _stats()};
      });
      cache.want(['A']);
      final f = cache.flush();
      cache.invalidate();
      await f;
      expect(cache['A'], isNull);
      cache.dispose();
    });
  });
}
