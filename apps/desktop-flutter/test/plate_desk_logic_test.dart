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

  group('visits', () {
    PlateRead r(String cam, int minAgo, {double conf = 0.9}) => PlateRead(
      id: '$cam-$minAgo',
      cameraId: cam,
      ts: _t0.subtract(Duration(minutes: minAgo)),
      plate: 'ABC123',
      plateRaw: 'ABC123',
      confidence: conf,
      region: null,
      sourceId: 'frigate',
      eventId: null,
      snapshotUrl: null,
      displayName: null,
      bbox: null,
    );

    test('reads within 5 min on one camera are one visit', () {
      final v = collapseVisits([
        r('A', 0),
        r('A', 3, conf: 0.99),
        r('A', 7), // 4 min after the previous read: same visit
        r('A', 20), // 13 min gap: new visit
        r('B', 1), // other camera: its own visit
      ]);
      expect(v.length, 3);
      expect(v[0].cameraId, 'A');
      expect(v[0].count, 3);
      expect(v[0].best.id, 'A-3');
      expect(v[0].start, _t0.subtract(const Duration(minutes: 7)));
      expect(v[0].end, _t0);
      expect(v[1].cameraId, 'B');
      expect(v[2].count, 1);
      expect(v[2].reads.single.id, 'A-20');
    });

    test('input order does not matter', () {
      final a = collapseVisits([r('A', 20), r('A', 0), r('A', 3)]);
      expect(a.map((v) => v.count), [2, 1]);
      expect(collapseVisits(const []), isEmpty);
    });
  });

  group('summary sentence', () {
    String cam(String id) => id == 'lpr' ? '.06 LPR' : 'Driveway';

    test('regular evening arrival, mostly one camera', () {
      final hours = List<int>.filled(24, 0)
        ..[17] = 30
        ..[18] = 6
        ..[8] = 4;
      final s = PlateStats(
        plate: 'X',
        total: 40,
        seen7d: 9,
        seen30d: 20,
        firstSeen: DateTime(2026, 3, 14),
        lastSeen: DateTime(2026, 10, 29, 17, 42),
        prevSeen: DateTime(2026, 10, 28, 17, 31),
        cameras: const [PlateCameraCount('lpr', 32), PlateCameraCount('dw', 8)],
        hours: hours,
        days30: List<int>.filled(30, 0)..[29] = 1,
      );
      expect(
        plateSummary(s, camName: cam),
        'Usually arrives between 5 and 6 PM, mostly on .06 LPR.',
      );
      final now = DateTime(2026, 10, 29, 18);
      expect(
        plateSummary(
          s,
          camName: cam,
          focus: DateTime(2026, 10, 29, 2, 10),
          now: now,
        ),
        "Usually arrives between 5 and 6 PM, mostly on .06 LPR. "
        "Today's 2:10 AM read is unusual for this plate.",
      );
    });

    test('spread across hours and cameras', () {
      final s = PlateStats(
        plate: 'X',
        total: 48,
        seen7d: 1,
        seen30d: 10,
        firstSeen: DateTime(2026, 3, 14),
        lastSeen: DateTime(2026, 10, 29),
        prevSeen: null,
        cameras: const [
          PlateCameraCount('lpr', 24),
          PlateCameraCount('dw', 24),
        ],
        hours: List<int>.filled(24, 2),
        days30: List<int>.filled(30, 0)..[29] = 1,
      );
      expect(
        plateSummary(s, camName: cam),
        'Comes and goes at all hours, across 2 cameras.',
      );
    });

    test('three-hour window when no single hour dominates', () {
      final hours = List<int>.filled(24, 0)
        ..[7] = 4
        ..[8] = 4
        ..[9] = 4
        ..[20] = 2;
      final s = PlateStats(
        plate: 'X',
        total: 20,
        seen7d: 1,
        seen30d: 10,
        firstSeen: DateTime(2026, 3, 14),
        lastSeen: DateTime(2026, 10, 29),
        prevSeen: null,
        cameras: const [PlateCameraCount('dw', 20)],
        hours: hours..[14] = 6,
        days30: List<int>.filled(30, 0)..[29] = 1,
      );
      // Busiest hour has 6 of 20 = 30%: one-hour window wins.
      expect(
        plateSummary(s, camName: cam),
        startsWith('Usually arrives between 2 and 3 PM'),
      );
      hours[14] = 3; // now 3 of 17 < 25%, 7-10 AM holds 12 of 17
      final s2 = PlateStats(
        plate: 'X',
        total: 17,
        seen7d: 1,
        seen30d: 10,
        firstSeen: s.firstSeen,
        lastSeen: s.lastSeen,
        prevSeen: null,
        cameras: s.cameras,
        hours: hours,
        days30: s.days30,
      );
      expect(
        plateSummary(s2, camName: cam),
        'Usually arrives between 7 and 10 AM, mostly on Driveway.',
      );
    });

    test('new and rarely seen plates', () {
      final n = PlateStats(
        plate: 'X',
        total: 2,
        seen7d: 2,
        seen30d: 2,
        firstSeen: DateTime(2026, 10, 29, 9),
        lastSeen: DateTime(2026, 10, 29, 10),
        prevSeen: null,
        cameras: const [PlateCameraCount('dw', 2)],
        hours: List<int>.filled(24, 0),
        days30: List<int>.filled(30, 0)..[29] = 2,
      );
      expect(
        plateSummary(n, camName: cam),
        'First seen today on Driveway, 2 times so far.',
      );
      final rare = PlateStats(
        plate: 'X',
        total: 2,
        seen7d: 1,
        seen30d: 1,
        firstSeen: DateTime(2026, 6, 3, 9),
        lastSeen: DateTime(2026, 10, 29, 10),
        prevSeen: DateTime(2026, 6, 3, 9),
        cameras: const [PlateCameraCount('dw', 2)],
        hours: List<int>.filled(24, 0),
        days30: List<int>.filled(30, 0)..[29] = 1,
      );
      expect(
        plateSummary(rare, camName: cam, now: DateTime(2026, 10, 29, 12)),
        'Seen twice before, first on Jun 3, mostly on Driveway.',
      );
    });

    test('hour ranges', () {
      expect(fmtHourRange(17, 1), '5 and 6 PM');
      expect(fmtHourRange(11, 1), '11 AM and 12 PM');
      expect(fmtHourRange(23, 1), '11 PM and 12 AM');
      expect(fmtHourRange(7, 3), '7 and 10 AM');
      expect(
        busiestHours(
          List<int>.filled(24, 0)
            ..[23] = 3
            ..[0] = 3,
          2,
        ),
        (23, 6),
      );
    });
  });

  group('hide regulars', () {
    // Regular: seen before today and >= 5 reads in 30 d. New: no prior sighting.
    final regular = _stats(seen30d: 8, prev: _t0.subtract(const Duration(days: 1)));
    final fresh = _stats(total: 1, seen30d: 1);
    final reads = [
      _read('REG1', minAgo: 1),
      _read('NEW1', minAgo: 2),
      _read('UNK1', minAgo: 3),
      _read('WAT1', minAgo: 4),
    ];
    final statsByPlate = {'REG1': regular, 'NEW1': fresh, 'WAT1': regular};
    PlateStats? statsFor(String p) => statsByPlate[p];

    test('isHiddenRegular: only known, unwatched regulars', () {
      expect(regular.isRegular, isTrue);
      expect(isHiddenRegular(watched: false, stats: regular), isTrue);
      expect(isHiddenRegular(watched: true, stats: regular), isFalse);
      expect(isHiddenRegular(watched: false, stats: fresh), isFalse);
      expect(isHiddenRegular(watched: false, stats: null), isFalse);
    });

    test('groups: regulars dropped; unknown, new and watchlisted kept', () {
      final groups = [for (final r in reads) _g(r)];
      final out = withoutRegularGroups(
        groups,
        watched: (p) => p == 'WAT1',
        stats: statsFor,
      );
      expect([for (final g in out) g.representative.plate], [
        'NEW1',
        'UNK1',
        'WAT1',
      ]);
    });

    test('reads variant matches the groups variant', () {
      final out = withoutRegularReads(
        reads,
        watched: (p) => p == 'WAT1',
        stats: statsFor,
      );
      expect([for (final r in out) r.plate], ['NEW1', 'UNK1', 'WAT1']);
      expect(reads.length - out.length, 1);
    });

    test('nothing hidden before stats load', () {
      final out = withoutRegularReads(
        reads,
        watched: (_) => false,
        stats: (_) => null,
      );
      expect(out.length, reads.length);
    });

    test('yields to the Regulars desk filter', () {
      expect(
        hideRegularsActive(hideRegulars: true, filter: DeskFilter.all),
        isTrue,
      );
      expect(
        hideRegularsActive(hideRegulars: true, filter: DeskFilter.watchlist),
        isTrue,
      );
      expect(
        hideRegularsActive(hideRegulars: true, filter: DeskFilter.regulars),
        isFalse,
      );
      expect(
        hideRegularsActive(hideRegulars: false, filter: DeskFilter.all),
        isFalse,
      );
    });
  });
}
