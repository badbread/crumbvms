// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the filmstrip scrub-frame cache: the grid snap must match
// the server's cache key, hits are LRU, negative results expire, and the
// prefetch plan leads the cursor in its direction of travel while skipping
// cells that are already known.
//
// Pure, headless, deterministic.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/playback_api.dart';
import 'package:crumb_desktop/ui/playback/scrub_frame_cache.dart';

Uint8List _bytes(int tag) => Uint8List.fromList([tag]);

void main() {
  group('ScrubFrameCache.snap', () {
    test('floors to the 4 s grid like the server (div_euclid)', () {
      final c = ScrubFrameCache();
      expect(c.snap(0), 0);
      expect(c.snap(3999), 0);
      expect(c.snap(4000), 4000);
      expect(c.snap(1_700_000_001_234), 1_700_000_000_000);
      // Negative times never occur in practice, but the snap must still be a
      // floor (not a truncation toward zero) so the key never flips cells.
      expect(c.snap(-1), -4000);
    });
  });

  group('ScrubFrameCache get/put', () {
    test('any time inside a cell hits the frame stored for that cell', () {
      final c = ScrubFrameCache();
      c.put('cam', 8_001, 480, _bytes(1));
      expect(c.get('cam', 8_000, 480), _bytes(1));
      expect(c.get('cam', 11_999, 480), _bytes(1));
      expect(c.get('cam', 12_000, 480), isNull);
      // Width and camera are part of the key.
      expect(c.get('cam', 8_000, 160), isNull);
      expect(c.get('other', 8_000, 480), isNull);
    });

    test('evicts least-recently-used past capacity', () {
      final c = ScrubFrameCache(capacity: 2);
      c.put('cam', 0, 480, _bytes(0));
      c.put('cam', 4000, 480, _bytes(1));
      // Touch slot 0 so slot 4000 is the LRU one.
      expect(c.get('cam', 0, 480), _bytes(0));
      c.put('cam', 8000, 480, _bytes(2));
      expect(c.length, 2);
      expect(c.get('cam', 4000, 480), isNull);
      expect(c.get('cam', 0, 480), _bytes(0));
      expect(c.get('cam', 8000, 480), _bytes(2));
    });

    test('a negative result is remembered only for its TTL', () {
      var now = DateTime.utc(2026, 1, 1);
      final c = ScrubFrameCache(now: () => now);
      c.put('cam', 4000, 480, null);
      expect(c.isKnownMiss('cam', 4001, 480), isTrue);
      expect(c.has('cam', 4001, 480), isTrue);
      expect(c.get('cam', 4001, 480), isNull);
      now = now.add(kScrubMissTtl + const Duration(seconds: 1));
      expect(c.isKnownMiss('cam', 4001, 480), isFalse);
      expect(c.has('cam', 4001, 480), isFalse);
      // A real frame arriving later replaces the miss.
      c.put('cam', 4000, 480, _bytes(7));
      expect(c.isKnownMiss('cam', 4000, 480), isFalse);
      expect(c.get('cam', 4000, 480), _bytes(7));
    });
  });

  group('ScrubFrameCache.slotsToPrefetch', () {
    test('leads the cursor forward, one cell behind, nearest first', () {
      final c = ScrubFrameCache();
      expect(
        c.slotsToPrefetch('cam', 40_100, 480, direction: 1),
        [44_000, 36_000, 48_000, 52_000],
      );
    });

    test('mirrors when scrubbing backward', () {
      final c = ScrubFrameCache();
      expect(
        c.slotsToPrefetch('cam', 40_100, 480, direction: -1),
        [44_000, 36_000, 32_000, 28_000],
      );
    });

    test('omits cells already cached or known missing, never the cursor cell',
        () {
      final c = ScrubFrameCache();
      c.put('cam', 44_000, 480, _bytes(1));
      c.put('cam', 48_000, 480, null);
      expect(
        c.slotsToPrefetch('cam', 40_100, 480, direction: 1),
        [36_000, 52_000],
      );
    });
  });

  group('parseTimelineSpans', () {
    test('decodes spans and tolerates garbage', () {
      final spans = parseTimelineSpans(
        '{"spans":[{"camera_id":"c","start":"2026-01-01T00:00:00Z",'
        '"end":"2026-01-01T00:01:00Z","has_motion":true,"stage":"live"}],'
        '"total":1,"has_more":false}',
      );
      expect(spans, hasLength(1));
      expect(spans.single.cameraId, 'c');
      expect(spans.single.hasMotion, isTrue);
      expect(spans.single.end.difference(spans.single.start).inSeconds, 60);
      expect(parseTimelineSpans('not json'), isEmpty);
      expect(parseTimelineSpans('{"spans":null}'), isEmpty);
    });
  });
}
