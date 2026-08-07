// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The plate report's option logic: which sightings land on the page, in what
// order, and how many images ride along. This is the part that decides what an
// operator hands to a neighbour or an officer, so it is tested directly rather
// than through the dialog.
//
// Also a composition smoke test: a long occurrence list must produce a real,
// multi-page PDF rather than a single overflowing page.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_pdf_report.dart';
import 'package:crumb_desktop/ui/plates/plate_report_options.dart';

PlateRead _read({
  required String id,
  required DateTime ts,
  String cameraId = 'cam-a',
  String plate = '7ABC123',
  String? eventId = 'ev-1',
  double? confidence = 0.9,
  String? displayName,
}) =>
    PlateRead.fromJson({
      'id': id,
      'camera_id': cameraId,
      'ts': ts.toUtc().toIso8601String(),
      'plate': plate,
      'plate_raw': plate,
      'confidence': confidence,
      'region': null,
      'source_id': 'crumb-alpr',
      'event_id': ?eventId,
      'snapshot_url': null,
      'display_name': ?displayName,
      'bbox': null,
    });

void main() {
  final now = DateTime.utc(2026, 8, 7, 12);

  group('resolveReportWindow', () {
    test('all time is unbounded', () {
      final w = resolveReportWindow(ReportRange.allTime, now: now);
      expect(w.isUnbounded, isTrue);
      expect(w.start, isNull);
      expect(w.end, isNull);
    });

    test('the day presets end at now and start N days back', () {
      expect(
        resolveReportWindow(ReportRange.days7, now: now),
        ReportWindow(now.subtract(const Duration(days: 7)), now),
      );
      expect(
        resolveReportWindow(ReportRange.days30, now: now),
        ReportWindow(now.subtract(const Duration(days: 30)), now),
      );
      expect(
        resolveReportWindow(ReportRange.days90, now: now),
        ReportWindow(now.subtract(const Duration(days: 90)), now),
      );
    });

    test('custom uses the operator bounds verbatim', () {
      final s = DateTime.utc(2026, 7, 17);
      final e = DateTime.utc(2026, 8, 7);
      expect(
        resolveReportWindow(ReportRange.custom,
            now: now, customStart: s, customEnd: e),
        ReportWindow(s, e),
      );
    });

    test('a backwards custom range is swapped, not silently empty', () {
      final s = DateTime.utc(2026, 8, 7);
      final e = DateTime.utc(2026, 7, 17);
      expect(
        resolveReportWindow(ReportRange.custom,
            now: now, customStart: s, customEnd: e),
        ReportWindow(e, s),
      );
    });

    test('a half-open custom range stays half-open', () {
      final s = DateTime.utc(2026, 7, 17);
      final w = resolveReportWindow(ReportRange.custom,
          now: now, customStart: s, customEnd: null);
      expect(w.start, s);
      expect(w.end, isNull);
      expect(w.isUnbounded, isFalse);
    });
  });

  group('ReportWindow.contains', () {
    final w = ReportWindow(DateTime.utc(2026, 8, 1), DateTime.utc(2026, 8, 5));

    test('start is inclusive, end is exclusive', () {
      expect(w.contains(DateTime.utc(2026, 8, 1)), isTrue);
      expect(w.contains(DateTime.utc(2026, 8, 5)), isFalse);
      expect(
          w.contains(DateTime.utc(2026, 8, 4, 23, 59, 59)), isTrue);
    });

    test('outside on either side is excluded', () {
      expect(w.contains(DateTime.utc(2026, 7, 31, 23)), isFalse);
      expect(w.contains(DateTime.utc(2026, 8, 6)), isFalse);
    });

    test('an unbounded window contains everything', () {
      const open = ReportWindow(null, null);
      expect(open.contains(DateTime.utc(1999)), isTrue);
      expect(open.contains(DateTime.utc(2099)), isTrue);
    });
  });

  group('buildOccurrenceList', () {
    final reads = [
      _read(id: 'a', ts: DateTime.utc(2026, 8, 6), cameraId: 'cam-a'),
      _read(id: 'b', ts: DateTime.utc(2026, 8, 2), cameraId: 'cam-b'),
      _read(id: 'c', ts: DateTime.utc(2026, 7, 20), cameraId: 'cam-a'),
      _read(id: 'd', ts: DateTime.utc(2026, 8, 4), cameraId: 'cam-b'),
    ];

    test('newest first by default', () {
      final out = buildOccurrenceList(
        reads,
        window: const ReportWindow(null, null),
        cameraIds: const {},
        sort: ReportSort.newestFirst,
      );
      expect(out.map((r) => r.id), ['a', 'd', 'b', 'c']);
    });

    test('oldest first reverses it', () {
      final out = buildOccurrenceList(
        reads,
        window: const ReportWindow(null, null),
        cameraIds: const {},
        sort: ReportSort.oldestFirst,
      );
      expect(out.map((r) => r.id), ['c', 'b', 'd', 'a']);
    });

    test('the window drops sightings outside it', () {
      final out = buildOccurrenceList(
        reads,
        window: ReportWindow(DateTime.utc(2026, 8, 1), DateTime.utc(2026, 8, 5)),
        cameraIds: const {},
        sort: ReportSort.newestFirst,
      );
      expect(out.map((r) => r.id), ['d', 'b']);
    });

    test('an empty camera set means every camera', () {
      final out = buildOccurrenceList(
        reads,
        window: const ReportWindow(null, null),
        cameraIds: const {},
        sort: ReportSort.newestFirst,
      );
      expect(out, hasLength(4));
    });

    test('a camera filter keeps only those cameras', () {
      final out = buildOccurrenceList(
        reads,
        window: const ReportWindow(null, null),
        cameraIds: const {'cam-b'},
        sort: ReportSort.newestFirst,
      );
      expect(out.map((r) => r.id), ['d', 'b']);
    });

    test('window and camera filters compose', () {
      final out = buildOccurrenceList(
        reads,
        window: ReportWindow(DateTime.utc(2026, 8, 1), null),
        cameraIds: const {'cam-a'},
        sort: ReportSort.newestFirst,
      );
      expect(out.map((r) => r.id), ['a']);
    });

    test('does not mutate the input list', () {
      final input = [...reads];
      buildOccurrenceList(
        input,
        window: const ReportWindow(null, null),
        cameraIds: const {},
        sort: ReportSort.oldestFirst,
      );
      expect(input.map((r) => r.id), ['a', 'b', 'c', 'd']);
    });
  });

  group('image-count capping', () {
    test('the presets resolve to their numbers', () {
      expect(reportThumbTarget(ReportThumbCount.none), 0);
      expect(reportThumbTarget(ReportThumbCount.four), 4);
      expect(reportThumbTarget(ReportThumbCount.eight), 8);
      expect(reportThumbTarget(ReportThumbCount.twelve), 12);
    });

    test('"all" is the hard cap, not unbounded', () {
      expect(reportThumbTarget(ReportThumbCount.all), kMaxReportThumbs);
      expect(cappedThumbCount(ReportThumbCount.all, 500), kMaxReportThumbs);
    });

    test('capped by how many sightings actually exist', () {
      expect(cappedThumbCount(ReportThumbCount.twelve, 3), 3);
      expect(cappedThumbCount(ReportThumbCount.all, 5), 5);
      expect(cappedThumbCount(ReportThumbCount.four, 0), 0);
    });

    test('none embeds nothing regardless of what exists', () {
      expect(cappedThumbCount(ReportThumbCount.none, 100), 0);
    });

    test('the size warning fires above the threshold only', () {
      expect(
          PlateReportOptions(thumbCount: ReportThumbCount.four).warnsAboutSize,
          isFalse);
      expect(
          PlateReportOptions(thumbCount: ReportThumbCount.eight).warnsAboutSize,
          isFalse);
      expect(
          PlateReportOptions(thumbCount: ReportThumbCount.twelve)
              .warnsAboutSize,
          isTrue);
      expect(PlateReportOptions(thumbCount: ReportThumbCount.all).warnsAboutSize,
          isTrue);
    });
  });

  group('selectThumbCandidates', () {
    final occ = [
      _read(id: 'subject', ts: DateTime.utc(2026, 8, 6)),
      _read(id: 'x', ts: DateTime.utc(2026, 8, 5)),
      _read(id: 'no-event', ts: DateTime.utc(2026, 8, 4), eventId: null),
      _read(id: 'y', ts: DateTime.utc(2026, 8, 3)),
      _read(id: 'z', ts: DateTime.utc(2026, 8, 2)),
    ];

    test('excludes the subject read, whose images already lead the report', () {
      final out = selectThumbCandidates(occ, excludeId: 'subject', count: 10);
      expect(out.map((r) => r.id), ['x', 'y', 'z']);
    });

    test('skips reads with no linked event (no authed image source)', () {
      final out = selectThumbCandidates(occ, excludeId: 'subject', count: 10);
      expect(out.map((r) => r.id), isNot(contains('no-event')));
    });

    test('honours the count, in the list order it was given', () {
      final out = selectThumbCandidates(occ, excludeId: 'subject', count: 2);
      expect(out.map((r) => r.id), ['x', 'y']);
    });

    test('a zero or negative count selects nothing', () {
      expect(selectThumbCandidates(occ, excludeId: 'subject', count: 0),
          isEmpty);
      expect(selectThumbCandidates(occ, excludeId: 'subject', count: -3),
          isEmpty);
    });
  });

  test('camerasInReads collapses to the distinct set', () {
    expect(
      camerasInReads([
        _read(id: 'a', ts: now, cameraId: 'cam-a'),
        _read(id: 'b', ts: now, cameraId: 'cam-b'),
        _read(id: 'c', ts: now, cameraId: 'cam-a'),
      ]),
      {'cam-a', 'cam-b'},
    );
    expect(camerasInReads(const []), isEmpty);
  });

  group('composition smoke test', () {
    const tz = ReportTimezone(label: 'UTC', offset: Duration.zero);

    Future<List<int>> build({
      OccurrenceList? occurrences,
      ReportImageType imageType = ReportImageType.both,
      ReportPageSize pageSize = ReportPageSize.letter,
      String notes = '',
      String? displayName,
    }) =>
        buildSinglePlateReportPdf(
          read: _read(id: 'subject', ts: now, displayName: displayName),
          cameraName: 'Driveway',
          tz: tz,
          exportedAt: now,
          watchMatch: null,
          plateCropBytes: null,
          plateCropIsFallback: true,
          vehicleBytes: null,
          dossier: null,
          occurrences: occurrences,
          imageType: imageType,
          pageSize: pageSize,
          notes: notes,
          serverLabel: 'https://crumb.example',
        );

    OccurrenceList listOf(int n) => OccurrenceList(
          rows: [
            for (var i = 0; i < n; i++)
              OccurrenceRow(
                ts: now.subtract(Duration(hours: i)),
                cameraName: 'Driveway',
                source: 'crumb-alpr',
                confidence: 0.9,
                plate: '7ABC123',
              ),
          ],
          total: n,
          truncated: false,
          windowLabel: 'All time',
          cameraLabel: 'All cameras',
        );

    test('produces a real PDF with no occurrence list', () async {
      final bytes = await build();
      expect(bytes.length, greaterThan(500));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('a 27-sighting list is embedded, not silently dropped', () async {
      final withList = await build(occurrences: listOf(27));
      final without = await build();
      expect(withList.length, greaterThan(without.length));
    });

    test('a long list spills onto more pages', () async {
      final short = await build(occurrences: listOf(5));
      final long = await build(occurrences: listOf(300));
      // Not a layout assertion (that is a visual judgement) — just that the
      // table genuinely paginates instead of overflowing one page.
      expect(long.length, greaterThan(short.length * 2));
    });

    test('every option combination still composes', () async {
      for (final t in ReportImageType.values) {
        for (final p in ReportPageSize.values) {
          final bytes = await build(
            occurrences: listOf(3),
            imageType: t,
            pageSize: p,
            notes: 'Repeated trespass, please advise.',
            displayName: "Neighbour's truck",
          );
          expect(String.fromCharCodes(bytes.take(4)), '%PDF',
              reason: 'imageType=$t pageSize=$p');
        }
      }
    });

    test('a full 24-image strip composes (wraps instead of smearing)',
        () async {
      final bytes = await buildSinglePlateReportPdf(
        read: _read(id: 'subject', ts: now),
        cameraName: 'Driveway',
        tz: tz,
        exportedAt: now,
        watchMatch: null,
        plateCropBytes: null,
        plateCropIsFallback: true,
        vehicleBytes: null,
        dossier: PlateDossier(
          total: 40,
          distinctCameras: 2,
          firstSeen: now.subtract(const Duration(days: 21)),
          lastSeen: now,
          thumbs: [
            for (var i = 0; i < kMaxReportThumbs; i++)
              DossierThumb(
                // Undecodable on purpose: this exercises the LAYOUT, and the
                // report is meant to place a "-" rather than fail the page.
                bytes: Uint8List.fromList(const [1, 2, 3]),
                plate: '7ABC123',
                cameraName: 'Driveway',
                ts: now.subtract(Duration(hours: i)),
              ),
          ],
        ),
      );
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('sighting images without summary counts still compose', () async {
      final bytes = await buildSinglePlateReportPdf(
        read: _read(id: 'subject', ts: now),
        cameraName: 'Driveway',
        tz: tz,
        exportedAt: now,
        watchMatch: null,
        plateCropBytes: null,
        plateCropIsFallback: true,
        vehicleBytes: null,
        dossier: PlateDossier(
          total: 3,
          distinctCameras: 1,
          firstSeen: null,
          lastSeen: null,
          showStats: false,
          thumbs: [
            DossierThumb(
              bytes: Uint8List.fromList(const [1, 2, 3]),
              plate: '7ABC123',
              cameraName: 'Driveway',
              ts: now,
            ),
          ],
        ),
      );
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('A4 and Letter are actually different documents', () async {
      final letter = await build(pageSize: ReportPageSize.letter);
      final a4 = await build(pageSize: ReportPageSize.a4);
      expect(letter, isNot(equals(a4)));
    });
  });
}
