// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for plate corrections (issue #673): the pure helpers behind the
// "Correct plate..." dialog and the JSON parsing of the alias endpoints.

import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plate_alias_api.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_correction_dialog.dart';

void main() {
  group('normalizePlateInput', () {
    test('uppercases and keeps only letters and digits', () {
      expect(normalizePlateInput(' gif-2 gab '), 'GIF2GAB');
      expect(normalizePlateInput('---'), '');
    });
  });

  group('canOfferPlateCorrection', () {
    test('admins only, and never for a blank plate', () {
      expect(canOfferPlateCorrection(isAdmin: true, plate: 'ABC123'), isTrue);
      expect(canOfferPlateCorrection(isAdmin: false, plate: 'ABC123'), isFalse);
      expect(canOfferPlateCorrection(isAdmin: true, plate: '  '), isFalse);
    });
  });

  group('plateCorrectionEffect', () {
    test('says how many reads move', () {
      expect(
        plateCorrectionEffect(from: 'GIT2GAB', target: 'gif2gab', reads: 12),
        "GIT2GAB's 12 reads will count as GIF2GAB, and so will future reads "
        'of it.',
      );
      expect(
        plateCorrectionEffect(from: 'GIT2GAB', target: 'GIF2GAB', reads: 1),
        startsWith("GIT2GAB's 1 read will"),
      );
    });

    test('no reads yet still explains the future', () {
      expect(
        plateCorrectionEffect(from: 'GIT2GAB', target: 'GIF2GAB', reads: 0),
        'Future reads of GIT2GAB will count as GIF2GAB.',
      );
    });

    test('mentions misreads that move along', () {
      expect(
        plateCorrectionEffect(
          from: 'GIT2GAB',
          target: 'GIF2GAB',
          reads: 3,
          movingAliases: const ['G1T2GAB'],
        ),
        endsWith('Its known misread G1T2GAB will move to GIF2GAB too.'),
      );
    });

    test('null for an empty or identical target', () {
      expect(
        plateCorrectionEffect(from: 'GIT2GAB', target: '', reads: 3),
        isNull,
      );
      expect(
        plateCorrectionEffect(from: 'GIT2GAB', target: 'git-2gab', reads: 3),
        isNull,
      );
    });
  });

  test('plateSuggestionDistanceLabel', () {
    expect(plateSuggestionDistanceLabel(0), 'look-alike characters');
    expect(plateSuggestionDistanceLabel(1), '1 character off');
    expect(plateSuggestionDistanceLabel(2), '2 characters off');
  });

  test('PlateSuggestions.fromJson', () {
    final s = PlateSuggestions.fromJson({
      'plate': 'GIT2GAB',
      'canonical_plate': 'GIT2GAB',
      'reads': 12,
      'aliases': ['G1T2GAB'],
      'suggestions': [
        {
          'plate': 'GIF2GAB',
          'reads': 40,
          'distance': 1,
          'display_name': "Mom's car",
        },
      ],
    });
    expect(s.reads, 12);
    expect(s.aliases, ['G1T2GAB']);
    expect(s.suggestions.single.plate, 'GIF2GAB');
    expect(s.suggestions.single.distance, 1);
    expect(s.suggestions.single.displayName, "Mom's car");
  });

  test('PlateAlias.fromJson tolerates missing fields', () {
    final a = PlateAlias.fromJson({
      'alias_plate': 'GIT2GAB',
      'canonical_plate': 'GIF2GAB',
      'created_at': '2026-10-29T12:00:00Z',
      'reads': 5,
    });
    expect(a.aliasPlate, 'GIT2GAB');
    expect(a.canonicalPlate, 'GIF2GAB');
    expect(a.createdBy, isNull);
    expect(a.createdAt, isNotNull);
    expect(a.reads, 5);
  });

  test('plateReadAs keeps the read and swaps the plate', () {
    final r = PlateRead(
      id: 'r1',
      cameraId: 'c1',
      ts: DateTime.utc(2026, 10, 29),
      plate: 'GIT2GAB',
      plateRaw: 'GIT-2GAB',
      confidence: 0.8,
      region: null,
      sourceId: 'frigate',
      eventId: 'e1',
      snapshotUrl: null,
      displayName: 'old name',
      bbox: const [0.1, 0.2, 0.3, 0.4],
    );
    final moved = plateReadAs(r, 'GIF2GAB');
    expect(moved.plate, 'GIF2GAB');
    expect(moved.id, 'r1');
    expect(moved.plateRaw, 'GIT-2GAB');
    expect(moved.eventId, 'e1');
    expect(moved.bbox, r.bbox);
    expect(moved.displayName, isNull);
  });
}
