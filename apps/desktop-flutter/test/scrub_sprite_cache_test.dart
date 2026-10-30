// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the scrub sprite-strip cache: header parsing, tile lookup
// at 1 s granularity, LRU, negative caching, the "which segment next"
// prefetch plan, and the tile alignment the overlay crops with.
//
// Pure, headless, deterministic.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/playback/scrub_sprite_cache.dart';
import 'package:crumb_desktop/ui/playback/scrub_sprite_view.dart';

// A real (1x1 PNG) image so the view test's Image can decode it.
final Uint8List _jpeg = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

Map<String, String> _headers({
  int start = 40000,
  int end = 44000,
  int tiles = 4,
  int? columns,
  int interval = 1000,
}) => {
  // Mixed case on purpose: header names are case-insensitive.
  'X-Crumb-Sprite-Start-Ms': '$start',
  'x-crumb-sprite-end-ms': '$end',
  'x-crumb-sprite-interval-ms': '$interval',
  'x-crumb-sprite-tiles': '$tiles',
  'x-crumb-sprite-columns': '${columns ?? tiles}',
  'x-crumb-sprite-tile-width': '160',
};

ScrubSprite _sprite({int start = 40000, int end = 44000}) =>
    ScrubSprite.fromResponse(_headers(start: start, end: end), _jpeg)!;

void main() {
  group('ScrubSprite.fromResponse', () {
    test('parses the layout headers', () {
      final s = ScrubSprite.fromResponse(_headers(), _jpeg)!;
      expect(s.startMs, 40000);
      expect(s.endMs, 44000);
      expect(s.intervalMs, 1000);
      expect(s.tiles, 4);
      expect(s.columns, 4);
      expect(s.rows, 1);
    });

    test('rejects missing or nonsensical layouts (treated as a miss)', () {
      final h = _headers()..remove('x-crumb-sprite-tiles');
      expect(ScrubSprite.fromResponse(h, _jpeg), isNull);
      expect(
        ScrubSprite.fromResponse(_headers(start: 5, end: 5), _jpeg),
        isNull,
      );
      expect(ScrubSprite.fromResponse(_headers(interval: 0), _jpeg), isNull);
      expect(ScrubSprite.fromResponse(_headers(tiles: 0), _jpeg), isNull);
      expect(ScrubSprite.fromResponse(_headers(), Uint8List(0)), isNull);
    });
  });

  group('tiles', () {
    test('one tile per second, clamped into the strip', () {
      final s = _sprite();
      expect(s.tileFor(40000), 0);
      expect(s.tileFor(40999), 0);
      expect(s.tileFor(41000), 1);
      expect(s.tileFor(43999), 3);
      expect(s.tileFor(39000), 0);
      expect(s.tileFor(90000), 3);
    });

    test('alignment walks the strip left to right', () {
      final s = _sprite();
      expect(ScrubSpriteTile(s, 0).alignX, -1);
      expect(ScrubSpriteTile(s, 3).alignX, 1);
      expect(ScrubSpriteTile(s, 1).alignX, closeTo(-1 / 3, 1e-9));
      expect(ScrubSpriteTile(s, 2).alignY, 0, reason: 'single row');
      final one = ScrubSprite.fromResponse(_headers(tiles: 1), _jpeg)!;
      expect(ScrubSpriteTile(one, 0).alignX, 0);
    });

    test('tile equality is by sprite identity + index', () {
      final s = _sprite();
      expect(ScrubSpriteTile(s, 1), ScrubSpriteTile(s, 1));
      expect(ScrubSpriteTile(s, 1) == ScrubSpriteTile(s, 2), isFalse);
      expect(ScrubSpriteTile(s, 1) == ScrubSpriteTile(_sprite(), 1), isFalse);
    });
  });

  group('ScrubSpriteCache', () {
    test('lookup returns the tile of the sprite covering t, per camera', () {
      final c = ScrubSpriteCache();
      final s = _sprite();
      c.put('cam', 41500, s);
      final hit = c.lookup('cam', 42100)!;
      expect(identical(hit.sprite, s), isTrue);
      expect(hit.index, 2);
      expect(c.lookup('cam', 44000), isNull, reason: 'end is exclusive');
      expect(c.lookup('other', 42100), isNull);
    });

    test('evicts least-recently-used past capacity', () {
      final c = ScrubSpriteCache(capacity: 2);
      c.put('cam', 0, _sprite(start: 0, end: 4000));
      c.put('cam', 4000, _sprite(start: 4000, end: 8000));
      expect(c.lookup('cam', 1000), isNotNull); // touch the first
      c.put('cam', 8000, _sprite(start: 8000, end: 12000));
      expect(c.length, 2);
      expect(c.lookup('cam', 5000), isNull);
      expect(c.lookup('cam', 1000), isNotNull);
      expect(c.lookup('cam', 9000), isNotNull);
    });

    test('a miss is remembered per 4 s cell, only for its TTL', () {
      var now = DateTime.utc(2026, 1, 1);
      final c = ScrubSpriteCache(now: () => now);
      c.put('cam', 41000, null);
      expect(c.isKnownMiss('cam', 40000), isTrue);
      expect(c.isKnownMiss('cam', 43999), isTrue);
      expect(c.isKnownMiss('cam', 44000), isFalse);
      expect(c.has('cam', 42000), isTrue);
      now = now.add(kScrubSpriteMissTtl + const Duration(seconds: 1));
      expect(c.isKnownMiss('cam', 42000), isFalse);
    });

    test('probesAhead targets the next segments in the direction of travel',
        () {
      final c = ScrubSpriteCache();
      final s = _sprite();
      c.put('cam', 40000, s);
      expect(c.probesAhead('cam', s, direction: 1), [44000, 48000]);
      expect(c.probesAhead('cam', s, direction: -1), [39999, 35999]);
      // Already cached / known missing segments are skipped.
      c.put('cam', 44000, _sprite(start: 44000, end: 48000));
      c.put('cam', 48000, null);
      expect(c.probesAhead('cam', s, direction: 1), isEmpty);
    });
  });

  testWidgets('ScrubSpriteTileView builds a one-tile crop of the strip', (
    tester,
  ) async {
    final s = _sprite();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScrubSpriteTileView(tile: ScrubSpriteTile(s, 3)),
      ),
    );
    final align = tester.widget<Align>(find.byType(Align));
    expect(align.widthFactor, 1 / 4);
    expect(align.heightFactor, 1);
    expect(align.alignment, const Alignment(1, 0));
  });
}
