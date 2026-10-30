// Short-lived client cache of `GET /play/{camera_id}` resolves.
//
// A scrub release, a frame-step and the adjacent-segment probes mostly land
// inside a segment that was resolved moments earlier. A segment's identity and
// `[start, end)` window never change once it is indexed, so the same answer
// can be served from memory instead of another round trip.
//
// What is cached is the ResolvedSegment itself, whose `url` is the
// API-relative `/segments/{id}` path with NO media token: the scoped
// `?token=` claim is attached afterwards by `PlaybackApi.mediaUrlForSegment`
// from its own token cache, which refreshes ahead of expiry. So a cached
// resolve can never hand out an expired media URL, and the 60 s TTL (far
// inside the server's 15 min media-token lifetime anyway) only bounds how
// long a segment that retention deleted in the meantime can still be
// answered from memory.
//
// Only positive answers are cached. A 404 ("no footage here") is never
// remembered, so footage recorded after a miss shows up on the next resolve.
//
// Entries are keyed by [scope] (the server base and session token, so one
// principal's camera grants never answer another's resolve), camera and
// stream. Lookup is by time: any `ts` inside a cached segment's window hits.

import 'dart:collection';

import 'playback_api.dart';

/// Default lifetime of a cached resolve.
const Duration kPlayResolveTtl = Duration(seconds: 60);

/// Default maximum number of cached segments (all cameras together).
const int kPlayResolveCapacity = 256;

class _Entry {
  _Entry(this.scope, this.stream, this.seg, this.storedAt);
  final String scope;
  final String stream;
  final ResolvedSegment seg;
  final DateTime storedAt;
}

class PlayResolveCache {
  PlayResolveCache({
    this.ttl = kPlayResolveTtl,
    this.capacity = kPlayResolveCapacity,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int capacity;
  final DateTime Function() _now;

  // Insertion/recency ordered: the first entry is the least recently used.
  final LinkedHashMap<String, _Entry> _entries = LinkedHashMap();

  int get length => _entries.length;

  String _key(String scope, String stream, ResolvedSegment seg) =>
      '$scope|${seg.cameraId}|$stream|${seg.segmentId}';

  /// The cached segment of [cameraId]/[stream] covering [ts]
  /// (start inclusive, end exclusive, like the server), or null.
  ResolvedSegment? lookup(
    String scope,
    String cameraId,
    String stream,
    DateTime ts,
  ) {
    final now = _now();
    String? hitKey;
    _Entry? hit;
    final expired = <String>[];
    for (final e in _entries.entries) {
      final v = e.value;
      if (now.difference(v.storedAt) >= ttl) {
        expired.add(e.key);
        continue;
      }
      if (hit == null &&
          v.scope == scope &&
          v.stream == stream &&
          v.seg.cameraId == cameraId &&
          v.seg.covers(ts)) {
        hitKey = e.key;
        hit = v;
      }
    }
    expired.forEach(_entries.remove);
    if (hit == null) return null;
    // Refresh recency (not the TTL: an entry still expires [ttl] after it was
    // fetched, however often it is read).
    _entries.remove(hitKey);
    _entries[hitKey!] = hit;
    return hit.seg;
  }

  void put(String scope, String stream, ResolvedSegment seg) {
    final key = _key(scope, stream, seg);
    _entries.remove(key);
    _entries[key] = _Entry(scope, stream, seg, _now());
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Forget every cached resolve, or only [cameraId]'s.
  void invalidate({String? cameraId}) {
    if (cameraId == null) {
      _entries.clear();
    } else {
      _entries.removeWhere((_, e) => e.seg.cameraId == cameraId);
    }
  }
}
