// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Client-side cache for the filmstrip frames shown while scrubbing across
// segment boundaries, plus the pure "which neighbouring slots to warm"
// decision.
//
// The server snaps every `GET /filmstrip/{camera}/frame?ts=` to a fixed 4 s
// grid (services/api/src/filmstrip.rs::serve_frame), so a drag only ever
// needs one distinct image per 4 s of timeline, and dragging back over
// ground already covered asks for byte-identical images. Before this cache
// every pointer event past the throttle was a fresh HTTP round-trip (and,
// on a cold server, an ffmpeg run), so scrubbing back and forth over the
// same few seconds re-fetched the same frames forever and the overlay lagged
// the cursor by a network round-trip per slot. With it, a revisited slot
// repaints synchronously from memory and the slots just ahead of the cursor
// are fetched before the cursor reaches them.
//
// Pure and headless so the eviction and prefetch rules are unit-testable;
// the screen owns the HTTP side.

import 'dart:collection';
import 'dart:typed_data';

/// The server's filmstrip grid interval, in ms (`DEFAULT_THUMB_INTERVAL_SECS`
/// in filmstrip.rs). Requests inside the same cell share a cache key.
const int kScrubGridMs = 4000;

/// Default number of frames kept. At the 480 px scrub width a frame is
/// ~30-60 KiB, so this is a few MiB: enough for ~6 min of timeline at the
/// grid spacing, which comfortably covers a drag back and forth over an
/// event, without growing with session length.
const int kScrubCacheCapacity = 96;

/// How long a negative result (the server had no frame: 404 in a coverage
/// gap, or a transient extraction failure) is remembered before the slot is
/// asked for again. Short, because the cause may be transient, long enough
/// that a drag parked over a gap doesn't hammer the server 8×/s.
const Duration kScrubMissTtl = Duration(seconds: 10);

class ScrubFrameCache {
  ScrubFrameCache({
    this.capacity = kScrubCacheCapacity,
    this.gridMs = kScrubGridMs,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int capacity;
  final int gridMs;
  final DateTime Function() _now;

  // Insertion-ordered so eviction is LRU: a hit re-inserts the key at the end.
  final LinkedHashMap<String, Uint8List> _frames = LinkedHashMap();
  final Map<String, DateTime> _misses = {};

  int get length => _frames.length;

  /// Snap an absolute time (epoch ms) to the server's grid cell start —
  /// floor division, matching `div_euclid` in serve_frame so a client key
  /// and the server's cache key always name the same frame.
  int snap(int epochMs) => epochMs - (epochMs % gridMs); // Dart % is Euclidean

  String _key(String cameraId, int snappedMs, int width) =>
      '$cameraId|$snappedMs|$width';

  /// Cached frame bytes for the cell containing [epochMs], or `null`. A hit
  /// refreshes the entry's LRU position.
  Uint8List? get(String cameraId, int epochMs, int width) {
    final k = _key(cameraId, snap(epochMs), width);
    final v = _frames.remove(k);
    if (v == null) return null;
    _frames[k] = v;
    return v;
  }

  /// True when the cell is known to have NO frame (a recent negative result),
  /// so the caller should not ask the server again yet.
  bool isKnownMiss(String cameraId, int epochMs, int width) {
    final k = _key(cameraId, snap(epochMs), width);
    final at = _misses[k];
    if (at == null) return false;
    if (_now().difference(at) > kScrubMissTtl) {
      _misses.remove(k);
      return false;
    }
    return true;
  }

  /// True when the cell needs no fetch: either a frame is cached or a miss
  /// is still fresh.
  bool has(String cameraId, int epochMs, int width) =>
      _frames.containsKey(_key(cameraId, snap(epochMs), width)) ||
      isKnownMiss(cameraId, epochMs, width);

  /// Store a fetch result. `null` records a negative result (see
  /// [kScrubMissTtl]); bytes evict the least-recently-used frame past
  /// [capacity].
  void put(String cameraId, int epochMs, int width, Uint8List? bytes) {
    final k = _key(cameraId, snap(epochMs), width);
    if (bytes == null) {
      _misses[k] = _now();
      return;
    }
    _misses.remove(k);
    _frames.remove(k);
    _frames[k] = bytes;
    while (_frames.length > capacity) {
      _frames.remove(_frames.keys.first);
    }
  }

  void clear() {
    _frames.clear();
    _misses.clear();
  }

  /// Grid cells to warm around a cursor at [epochMs] moving in [direction]
  /// (+1 forward, -1 backward, 0 unknown → symmetric). Ordered nearest-first
  /// so a bounded fetcher takes the most useful ones. Cells the cache already
  /// [has] are omitted; the cursor's own cell is never included (the caller
  /// fetches it directly and shows it).
  List<int> slotsToPrefetch(
    String cameraId,
    int epochMs,
    int width, {
    required int direction,
    int ahead = 3,
    int behind = 1,
  }) {
    final center = snap(epochMs);
    final fwd = direction >= 0 ? ahead : behind;
    final back = direction >= 0 ? behind : ahead;
    final out = <int>[];
    for (var i = 1; i <= (fwd > back ? fwd : back); i++) {
      if (i <= fwd) out.add(center + i * gridMs);
      if (i <= back) out.add(center - i * gridMs);
    }
    // Symmetric when the direction is unknown: the loop above already
    // alternates, this just keeps the list in cursor-distance order.
    return out.where((ms) => !has(cameraId, ms, width)).toList(growable: false);
  }
}
