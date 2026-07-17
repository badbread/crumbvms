// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the Plates list duplicate-collapse (plate_collapse.dart).
//
// The list must show one row per physical car even though a single pass can
// produce several reads: both engines read a "both"-mode camera, and Frigate
// on its own re-emits a pass as its OCR refines. These are pure, deterministic
// assertions on the grouping — same camera + fuzzy plate + short time window.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_collapse.dart';

// A fixed anchor so tests are deterministic (no wall-clock).
final _t0 = DateTime.utc(2026, 7, 17, 20, 30, 0);

PlateRead _read(
  String plate, {
  required int secAgo,
  String source = 'frigate',
  double conf = 0.9,
  String camera = 'cam-A',
  String? id,
}) {
  return PlateRead(
    id: id ?? '$plate-$source-$secAgo',
    cameraId: camera,
    ts: _t0.subtract(Duration(seconds: secAgo)),
    plate: plate,
    plateRaw: plate,
    confidence: conf,
    region: null,
    sourceId: source,
    eventId: null,
    snapshotUrl: null,
    bbox: null,
  );
}

void main() {
  group('collapsePlateReads', () {
    test('cross-engine reads of the same car collapse to one group', () {
      final groups = collapsePlateReads([
        _read('8EWS547', secAgo: 0, source: 'crumb-alpr', conf: 1.0),
        _read('8EWS547', secAgo: 2, source: 'frigate', conf: 0.99),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.count, 2);
      expect(groups.single.sources.toSet(), {'crumb-alpr', 'frigate'});
      // Highest confidence wins the representative.
      expect(groups.single.representative.sourceId, 'crumb-alpr');
      expect(groups.single.disagreements, isEmpty);
    });

    test("Frigate's own OCR refinement (1-char drift) collapses to the best", () {
      // 9GXV498 <-> 9GXVL98 is edit distance 1: same pass, same engine. We keep
      // the higher-confidence read and DON'T flag it as a disagreement — an
      // engine wobbling on its own is noise, not an A/B signal.
      final groups = collapsePlateReads([
        _read('9GXVL98', secAgo: 0, conf: 0.94),
        _read('9GXV498', secAgo: 5, conf: 0.98),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.count, 2);
      expect(groups.single.representative.plate, '9GXV498');
      expect(groups.single.disagreements, isEmpty);
    });

    test('cross-engine disagreement is surfaced (Frigate vs Crumb)', () {
      // The two engines read the same pass one character apart — the A/B signal
      // the disagreement line exists to show.
      final groups = collapsePlateReads([
        _read('9GXV498', secAgo: 0, source: 'crumb-alpr', conf: 0.98),
        _read('9GXVL98', secAgo: 2, source: 'frigate', conf: 0.94),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.representative.plate, '9GXV498'); // higher conf
      expect(groups.single.disagreements['frigate'], '9GXVL98');
      expect(groups.single.disagreements.containsKey('crumb-alpr'), isFalse);
    });

    test('distinct plates on the same camera stay separate', () {
      final groups = collapsePlateReads([
        _read('8EWS547', secAgo: 0),
        _read('7BWP213', secAgo: 3),
      ]);
      expect(groups, hasLength(2));
    });

    test('the same plate outside the time window is a new pass', () {
      final groups = collapsePlateReads([
        _read('8EWS547', secAgo: 0),
        _read('8EWS547', secAgo: 60), // > 15s window => re-appearance
      ]);
      expect(groups, hasLength(2));
    });

    test('same plate, same instant, different cameras do not merge', () {
      final groups = collapsePlateReads([
        _read('8EWS547', secAgo: 0, camera: 'cam-A'),
        _read('8EWS547', secAgo: 0, camera: 'cam-B'),
      ]);
      expect(groups, hasLength(2));
    });

    test('a slow pass chains beyond the window via consecutive reads', () {
      // 0,8,16,24s apart — each hop <= 15s — is one car passing slowly.
      final groups = collapsePlateReads([
        _read('8EWS547', secAgo: 0),
        _read('8EWS547', secAgo: 8),
        _read('8EWS547', secAgo: 16),
        _read('8EWS547', secAgo: 24),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.count, 4);
    });

    test('only one engine saw the pass => single-source group', () {
      final groups = collapsePlateReads([
        _read('LDRG248', secAgo: 0, source: 'crumb-alpr'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.sources, ['crumb-alpr']);
      expect(groups.single.count, 1);
    });

    test('members are newest-first regardless of input order within a group',
        () {
      final groups = collapsePlateReads([
        _read('8EWS547', secAgo: 0, conf: 0.8),
        _read('8EWS547', secAgo: 4, conf: 0.95),
      ]);
      final m = groups.single.members;
      expect(m.first.ts.isAfter(m.last.ts), isTrue);
    });
  });
}
