// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure unit tests for the "footage deleted by retention" handling: the
// playback no-footage reason choice, parsing `footage_expired` /
// `oldest_footage_ts` / `recording_mode` (null-safe against older servers), the expired-bookmark
// filter, and the protection restored when a deleted bookmark is undone.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/bookmarks_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/bookmarks/bookmarks_screen.dart';
import 'package:crumb_desktop/ui/playback/no_footage_message.dart';

Map<String, dynamic> _bookmarkJson({Object? expired = _absent}) => {
  'id': 'b1',
  'camera_id': 'c1',
  'camera_name': '.06 LPR',
  'ts': '2026-09-10T17:03:52Z',
  'description': 'plate',
  'protect_until': null,
  'protect_start_ts': null,
  'protect_end_ts': null,
  'created_at': '2026-09-10T17:04:00Z',
  if (expired != _absent) 'footage_expired': expired,
};

const _absent = Object();

void main() {
  final oldest = DateTime.utc(2026, 10, 1, 12);

  group('noFootageMessage', () {
    final now = DateTime.utc(2026, 10, 29, 12);
    final inRange = oldest.add(const Duration(days: 2));

    NoFootageMessage pick({
      DateTime? playhead,
      String? error,
      DateTime? oldestFootage,
      String? mode,
      bool motionNow = false,
    }) => noFootageMessage(
      playhead: playhead ?? inRange,
      now: now,
      error: error,
      oldestFootage: oldestFootage,
      recordingMode: mode,
      motionNow: motionNow,
    );

    test('a load error wins over everything and carries the error', () {
      final m = pick(
        playhead: now,
        error: 'Playback resolve failed: timeout',
        oldestFootage: oldest,
        mode: 'continuous',
      );
      expect(m.reason, NoFootageReason.loadError);
      expect(m.title, "Couldn't load footage");
      expect(m.subtitle, 'Playback resolve failed: timeout');
      expect(m.shortLabel, 'error');
    });

    test('an idle motion camera at the live edge has no motion, not a delay', () {
      for (final p in [now.subtract(const Duration(seconds: 5)), now]) {
        final m = pick(playhead: p, oldestFootage: oldest, mode: 'motion');
        expect(m.reason, NoFootageReason.noMotion, reason: '$p');
        expect(m.title, 'No motion right now');
        expect(m.shortLabel, 'no motion');
      }
    });

    test('unknown mode with no recent motion claims nothing at the live edge', () {
      final m = pick(playhead: now, oldestFootage: oldest);
      expect(m.reason, NoFootageReason.unknown);
      expect(m.title, 'Nothing recorded yet');
      expect(
        pick(playhead: now, oldestFootage: oldest, motionNow: true).reason,
        NoFootageReason.liveEdge,
      );
    });

    test('a motion camera that is moving right now is at the live edge', () {
      final m = pick(
        playhead: now,
        oldestFootage: oldest,
        mode: 'motion',
        motionNow: true,
      );
      expect(m.reason, NoFootageReason.liveEdge);
    });

    test('within 10 s of now, or later, is the live edge', () {
      for (final p in [
        now.subtract(const Duration(seconds: 9)),
        now.subtract(kLiveEdgeWindow),
        now,
        now.add(const Duration(minutes: 5)),
      ]) {
        final m = pick(playhead: p, oldestFootage: oldest, mode: 'continuous');
        expect(m.reason, NoFootageReason.liveEdge, reason: '$p');
        expect(m.title, 'Live edge');
        expect(m.subtitle, 'Recordings appear a few seconds behind live');
        expect(m.shortLabel, 'live edge');
      }
      expect(
        pick(
          playhead: now.subtract(const Duration(seconds: 11)),
          oldestFootage: oldest,
          mode: 'motion',
        ).reason,
        NoFootageReason.noMotion,
      );
    });

    test('before the oldest recording reads as deleted by retention', () {
      final m = pick(
        playhead: DateTime.utc(2026, 9, 10, 17),
        oldestFootage: oldest,
        mode: 'continuous',
      );
      expect(m.reason, NoFootageReason.footageDeleted);
      expect(m.title, 'Footage deleted');
      expect(m.subtitle, startsWith("Older than this camera's retention."));
      expect(m.subtitle, contains(formatLocalDateTime(oldest)));
      expect(m.shortLabel, 'deleted');
      expect(m.isWarning, isFalse);
    });

    test('exactly at the oldest recording is not deleted', () {
      final m = pick(playhead: oldest, oldestFootage: oldest, mode: 'motion');
      expect(m.reason, NoFootageReason.noMotion);
    });

    test('motion camera in the retained range: no motion, neutral', () {
      final m = pick(oldestFootage: oldest, mode: 'motion');
      expect(m.reason, NoFootageReason.noMotion);
      expect(m.title, 'No motion at this time');
      expect(m.subtitle, 'This camera records only when it detects motion');
      expect(m.shortLabel, 'no motion');
      expect(m.isWarning, isFalse);
    });

    test('continuous camera in the retained range: recording gap, warn', () {
      final m = pick(oldestFootage: oldest, mode: 'continuous');
      expect(m.reason, NoFootageReason.recordingGap);
      expect(m.title, 'Recording gap');
      expect(m.subtitle, contains('records continuously'));
      expect(m.shortLabel, 'gap');
      expect(m.isWarning, isTrue);
    });

    test('new server, camera with no recordings at all: warn', () {
      final m = pick(mode: 'continuous');
      expect(m.reason, NoFootageReason.noFootageForCamera);
      expect(m.title, 'No footage for this camera');
      expect(m.isWarning, isTrue);
    });

    test('older server (no mode): no reason is claimed', () {
      for (final o in [null, oldest]) {
        final m = pick(oldestFootage: o);
        expect(m.reason, NoFootageReason.unknown);
        expect(m.title, 'No footage at this time');
        expect(m.subtitle, isNull);
        expect(m.shortLabel, 'no footage');
      }
      expect(pick(mode: 'something-new').reason, NoFootageReason.unknown);
    });
  });

  group('parsing', () {
    test('footage_expired is read, and defaults to false when absent', () {
      expect(
        Bookmark.fromJson(_bookmarkJson(expired: true)).footageExpired,
        isTrue,
      );
      expect(
        Bookmark.fromJson(_bookmarkJson(expired: false)).footageExpired,
        isFalse,
      );
      expect(Bookmark.fromJson(_bookmarkJson()).footageExpired, isFalse);
      expect(
        Bookmark.fromJson(_bookmarkJson(expired: null)).footageExpired,
        isFalse,
      );
    });

    test('oldest_footage_ts is parsed and null-safe', () {
      final base = {
        'id': 'c1',
        'name': 'Cam',
        'enabled': true,
        'has_sub': false,
        'ptz': false,
        'served_by': 'crumb',
      };
      expect(Camera.fromJson(base).oldestFootageTs, isNull);
      expect(
        Camera.fromJson({...base, 'oldest_footage_ts': null}).oldestFootageTs,
        isNull,
      );
      expect(
        Camera.fromJson({
          ...base,
          'oldest_footage_ts': '2026-10-01T12:00:00Z',
        }).oldestFootageTs,
        oldest,
      );
      expect(Camera.fromJson(base).recordingMode, isNull);
      expect(
        Camera.fromJson({...base, 'recording_mode': 'motion'}).recordingMode,
        'motion',
      );
    });
  });

  group('expired bookmarks', () {
    test('expiredBookmarks keeps only footage_expired rows', () {
      final a = Bookmark.fromJson(_bookmarkJson(expired: true));
      final b = Bookmark.fromJson({..._bookmarkJson(), 'id': 'b2'});
      expect(expiredBookmarks([a, b]).map((x) => x.id), ['b1']);
      expect(expiredBookmarks(const []), isEmpty);
    });

    test('deleted message pluralises', () {
      expect(bookmarksDeletedMessage(1), 'Bookmark deleted');
      expect(bookmarksDeletedMessage(3), '3 bookmarks deleted');
    });
  });

  group('restoreProtection (undo)', () {
    final ts = DateTime.utc(2026, 10, 20, 12);
    Bookmark protectedBm(DateTime? until) => Bookmark(
      id: 'b',
      cameraId: 'c',
      ts: ts,
      protectUntil: until,
      protectStartTs: ts.subtract(const Duration(seconds: 90)),
      protectEndTs: ts.add(const Duration(seconds: 600)),
      createdAt: ts,
    );

    test('unprotected bookmark restores unprotected', () {
      expect(protectedBm(null).restoreProtection(ts), isNull);
    });

    test('lapsed protection is not restored', () {
      final now = DateTime.utc(2026, 10, 25);
      expect(
        protectedBm(
          now.subtract(const Duration(minutes: 1)),
        ).restoreProtection(now),
        isNull,
      );
    });

    test('remaining time rounds up to whole days, window is kept', () {
      final now = DateTime.utc(2026, 10, 21);
      final p = protectedBm(
        now.add(const Duration(days: 2, hours: 3)),
      ).restoreProtection(now)!;
      expect(p.days, 3);
      expect(p.preSeconds, 90);
      expect(p.postSeconds, 600);
    });

    test('days clamp to the server range', () {
      final now = DateTime.utc(2026, 10, 21);
      expect(
        protectedBm(
          now.add(const Duration(minutes: 5)),
        ).restoreProtection(now)!.days,
        1,
      );
      expect(
        protectedBm(
          now.add(const Duration(days: 90)),
        ).restoreProtection(now)!.days,
        30,
      );
    });
  });
}
