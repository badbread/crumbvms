// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Client side of the per-segment scrub sprite strips
// (`GET /filmstrip/{camera}/sprite?ts=`, services/api/src/scrub_sprite.rs).
//
// A sprite is ONE small JPEG per recorded segment: `tiles` tiles in a single
// row, tile i showing the segment at `start + i * interval` (1 s). One request
// therefore gives the scrub overlay 1 s granularity across a whole 4 s segment,
// where the per-frame endpoint snaps to a 4 s grid. Sprites exist only when the
// server's background pre-generation is on and has caught up; a 404 means "not
// generated", and the screen falls back to the per-frame path
// (scrub_frame_cache.dart) for that part of the timeline.
//
// Pure and headless (layout parsing, lookup, LRU, negative caching, which
// segment to warm next) so it is unit-testable; the screen owns the HTTP side.

import 'dart:collection';
import 'dart:typed_data';

/// Default number of sprites kept. A 4-tile 160 px sprite is ~10-20 KiB, so
/// this is ~1-2 MiB: about 8 minutes of timeline at 4 s segments.
const int kScrubSpriteCacheCapacity = 128;

/// How long "no sprite here" is remembered before the server is asked again.
/// The pre-generation worker may simply not have reached this footage yet,
/// so this is short; long enough that a drag parked over a not-yet-generated
/// stretch doesn't re-probe on every pointer event.
const Duration kScrubSpriteMissTtl = Duration(seconds: 15);

/// Width of the cells negative results are remembered in. A 404 doesn't say
/// which segment was missing (or whether one exists at all), so a miss is
/// keyed by the server's 4 s frame grid, like the frame cache's misses.
const int kScrubSpriteMissCellMs = 4000;

/// One segment's sprite strip and its layout, as returned in the response
/// headers.
class ScrubSprite {
  const ScrubSprite({
    required this.startMs,
    required this.endMs,
    required this.intervalMs,
    required this.tiles,
    required this.columns,
    required this.bytes,
  });

  /// Segment start / end (exclusive), epoch ms.
  final int startMs;
  final int endMs;

  /// Time between tiles (1000).
  final int intervalMs;

  /// Number of tiles and tiles per row.
  final int tiles;
  final int columns;

  /// The JPEG.
  final Uint8List bytes;

  /// Rows in the strip (the server currently always writes one).
  int get rows => (tiles + columns - 1) ~/ columns;

  bool covers(int epochMs) => epochMs >= startMs && epochMs < endMs;

  /// Tile showing [epochMs] (clamped into the strip).
  int tileFor(int epochMs) {
    final i = (epochMs - startMs) ~/ intervalMs;
    if (i < 0) return 0;
    if (i >= tiles) return tiles - 1;
    return i;
  }

  /// Build from a 200 response. `null` when any layout header is missing or
  /// nonsensical, so a malformed response is treated like a miss (the frame
  /// fallback still works) rather than drawing the wrong part of a strip.
  /// Header names are matched case-insensitively.
  static ScrubSprite? fromResponse(Map<String, String> headers, Uint8List bytes) {
    final h = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
    int? read(String k) => int.tryParse(h['x-crumb-sprite-$k'] ?? '');
    final start = read('start-ms');
    final end = read('end-ms');
    final interval = read('interval-ms');
    final tiles = read('tiles');
    final columns = read('columns') ?? tiles;
    if (start == null ||
        end == null ||
        interval == null ||
        tiles == null ||
        columns == null ||
        end <= start ||
        interval <= 0 ||
        tiles <= 0 ||
        columns <= 0 ||
        bytes.isEmpty) {
      return null;
    }
    return ScrubSprite(
      startMs: start,
      endMs: end,
      intervalMs: interval,
      tiles: tiles,
      columns: columns,
      bytes: bytes,
    );
  }
}

/// What the overlay draws: one tile of a sprite.
class ScrubSpriteTile {
  const ScrubSpriteTile(this.sprite, this.index);
  final ScrubSprite sprite;
  final int index;

  int get column => index % sprite.columns;
  int get row => index ~/ sprite.columns;

  /// `Alignment` x/y (-1..1) that puts this tile in view when the strip is
  /// clipped to one tile with `Align(widthFactor: 1 / columns, heightFactor:
  /// 1 / rows)`: tile 0 is the left edge (-1), the last column the right (+1).
  double get alignX =>
      sprite.columns <= 1 ? 0 : -1 + 2 * column / (sprite.columns - 1);
  double get alignY => sprite.rows <= 1 ? 0 : -1 + 2 * row / (sprite.rows - 1);

  @override
  bool operator ==(Object other) =>
      other is ScrubSpriteTile &&
      identical(other.sprite, sprite) &&
      other.index == index;

  @override
  int get hashCode => Object.hash(identityHashCode(sprite), index);
}

class ScrubSpriteCache {
  ScrubSpriteCache({
    this.capacity = kScrubSpriteCacheCapacity,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int capacity;
  final DateTime Function() _now;

  // Keyed "camera|startMs"; insertion-ordered so eviction is LRU.
  final LinkedHashMap<String, ScrubSprite> _sprites = LinkedHashMap();
  final Map<String, DateTime> _misses = {};

  int get length => _sprites.length;

  String _missKey(String cameraId, int epochMs) =>
      '$cameraId|${epochMs - (epochMs % kScrubSpriteMissCellMs)}';

  /// The tile for [epochMs] if a cached sprite covers it. A hit refreshes the
  /// sprite's LRU position.
  ScrubSpriteTile? lookup(String cameraId, int epochMs) {
    final prefix = '$cameraId|';
    String? hitKey;
    for (final e in _sprites.entries) {
      if (e.key.startsWith(prefix) && e.value.covers(epochMs)) {
        hitKey = e.key;
        break;
      }
    }
    if (hitKey == null) return null;
    final s = _sprites.remove(hitKey)!;
    _sprites[hitKey] = s;
    return ScrubSpriteTile(s, s.tileFor(epochMs));
  }

  /// True when the server recently had no sprite for [epochMs].
  bool isKnownMiss(String cameraId, int epochMs) {
    final k = _missKey(cameraId, epochMs);
    final at = _misses[k];
    if (at == null) return false;
    if (_now().difference(at) > kScrubSpriteMissTtl) {
      _misses.remove(k);
      return false;
    }
    return true;
  }

  /// True when [epochMs] needs no sprite request: a cached sprite covers it
  /// or a miss there is still fresh. Does not touch LRU order.
  bool has(String cameraId, int epochMs) {
    final prefix = '$cameraId|';
    for (final e in _sprites.entries) {
      if (e.key.startsWith(prefix) && e.value.covers(epochMs)) return true;
    }
    return isKnownMiss(cameraId, epochMs);
  }

  /// Store a fetch result for a request made at [requestedMs]: a sprite, or
  /// `null` for "none there" (negative-cached for [kScrubSpriteMissTtl]).
  void put(String cameraId, int requestedMs, ScrubSprite? sprite) {
    if (sprite == null) {
      _misses[_missKey(cameraId, requestedMs)] = _now();
      return;
    }
    _misses.remove(_missKey(cameraId, requestedMs));
    final k = '$cameraId|${sprite.startMs}';
    _sprites.remove(k);
    _sprites[k] = sprite;
    while (_sprites.length > capacity) {
      _sprites.remove(_sprites.keys.first);
    }
  }

  void clear() {
    _sprites.clear();
    _misses.clear();
  }

  /// Instants to request next so the segment the cursor is heading into is
  /// already cached when it gets there: just past the current sprite in the
  /// direction of travel (+1 forward, -1 backward), then one further segment
  /// assumed to be the same length. Instants already covered or known-missing
  /// are omitted. Gaps in the recording just come back as cheap 404s.
  List<int> probesAhead(
    String cameraId,
    ScrubSprite current, {
    required int direction,
    int count = 2,
  }) {
    final span = current.endMs - current.startMs;
    final out = <int>[];
    for (var i = 0; i < count; i++) {
      final t = direction >= 0
          ? current.endMs + i * span
          : current.startMs - 1 - i * span;
      if (!has(cameraId, t)) out.add(t);
    }
    return out;
  }
}
