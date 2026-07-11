// Gapless segment advance with next-segment prefetch — the playback engine
// for ONE camera pane. Port of the P1 mechanism in apps/desktop/src/app.js:
//
//   pbPrefetchNextSegment (app.js:6967)  — pre-resolves GET /play/:camera_id
//     for segEnd+1 ~1s before the current segment ends, and pre-queues the
//     URL into the native player via `append_pane_next`
//     (apps/desktop/src-tauri/src/lib.rs:1181 -> `mpv.loadfile_append`, i.e.
//     mpv command `loadfile <url> append`).
//   pbTick (app.js:7425)                — the per-slot body that triggers the
//     prefetch ~1s before a segment boundary and detects when the boundary
//     has been crossed. Exposed here as [onTick], called once per pane per
//     tick by whoever owns the shared playhead clock (this app's
//     `PlaybackTransportController` / a screen's own tick loop) — mirrors
//     `pbActiveSlots().forEach(i => ...)` inside `pbTick`.
//   pbResolveAllPanesInner (app.js:7255) — on a boundary crossing, if the
//     next segment was already prefetched it swaps via `advance_pane`
//     (lib.rs:1193 -> mpv `playlist-next weak` + `playlist-clear`) — a pure
//     playlist-pointer move with a warm decoder, no HTTP round-trip and no
//     re-init stutter. If nothing was prefetched (e.g. the operator just
//     jumped, or the prefetch fetch lost a race) it falls back to a normal
//     `/play/` resolve + loadfile — "the boundary resolve will fall back to
//     a live fetch" (app.js comment at the same spot).
//
// media_kit/libmpv equivalent of the Tauri IPC pair:
//   append_pane_next(url)  ->  Player.add(Media(url))      (mpv `loadfile append`)
//   advance_pane(url)      ->  Player.next() + Player.remove(0)
//                               (mpv `playlist-next weak` + `playlist-clear`,
//                                done as two calls since media_kit's playlist
//                                is index-addressable rather than exposing a
//                                raw "clear all but current" primitive)
//   mpv.set_option("prefetch-playlist", "yes") (lib.rs:395, pane creation)
//                          ->  NativePlayer.setProperty('prefetch-playlist', 'yes')
//
// Scope: this controller owns ONE camera's [Player] + its segment/prefetch
// bookkeeping ONLY. It deliberately does NOT own play/pause/speed or the
// shared playhead clock — those are cross-pane concerns already covered by
// this app's `PlaybackTransportController` (registerPane/onPlayheadAdvance)
// and `PlaybackTimelineController`. Wire this controller's [player] into
// `PlaybackTransportController.registerPane`, and call [onTick] from
// `PlaybackTransportController.onPlayheadAdvance` for every active camera —
// see this file's integration note in the porting task output.
//
// Segment-resolve and scoped-media-token logic is NOT duplicated here — it
// calls the existing `PlaybackApi` extension (lib/api/playback_api.dart),
// mirroring app.js's `pbFetchSegment` (which itself calls
// `mediaUrlForCamera` for the scoped `?token=`).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../api/crumb_api.dart';
import '../../api/models.dart';
import '../../api/playback_api.dart';

/// How long before a segment's end to kick off the prefetch of the next one.
/// Mirrors app.js's `seg.segEndMs - 1000` check in `pbTick`.
const Duration kPrefetchLeadTime = Duration(milliseconds: 1000);

/// How close to (or past) a segment's end counts as "boundary reached".
/// Mirrors app.js's `segEndMs - 100` check.
const Duration kBoundaryTolerance = Duration(milliseconds: 100);

class GaplessSegmentPaneController extends ChangeNotifier {
  GaplessSegmentPaneController({
    required this.api,
    required Session session,
    required this.cameraId,
    this.stream = 'main',
  }) : _session = session {
    _player = Player();
    _videoController = VideoController(_player);
    unawaited(_configurePlayer());
  }

  final CrumbApi api;
  Session _session;
  final String cameraId;
  final String stream;

  late final Player _player;
  /// The underlying media_kit player — register it with whatever owns
  /// play/pause/speed for the pane grid (e.g.
  /// `PlaybackTransportController.registerPane(slot, controller.player)`).
  Player get player => _player;

  late final VideoController _videoController;
  VideoController get videoController => _videoController;

  ResolvedSegment? _current;
  ResolvedSegment? get currentSegment => _current;
  ResolvedSegment? _prefetched;

  bool _prefetching = false;
  bool _resolving = false;
  bool _advancing = false;

  /// True once a resolve for the current playhead came back with no covering
  /// segment (a normal "no footage here" outcome, not an error).
  bool noFootage = false;
  String? error;

  /// Swap in a fresh [Session] (e.g. after re-auth) without tearing down the
  /// player. Mirrors `MediaTokenCache.updateSession`.
  void updateSession(Session session) => _session = session;

  Future<void> _configurePlayer() async {
    final p = _player.platform;
    if (p is! NativePlayer) return;
    for (final kv in const [
      ['rtsp-transport', 'tcp'],
      ['hwdec', 'auto'],
      ['cache', 'yes'],
      ['demuxer-readahead-secs', '2.0'],
      ['demuxer-max-bytes', '32MiB'],
      ['demuxer-max-back-bytes', '1MiB'],
      ['network-timeout', '10'],
      ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
      // THE feature this file ports: demux the appended next-segment file
      // while the current one is still playing, so `Player.next()` at the
      // boundary lands on an already-warm decoder. Verbatim equivalent of
      // apps/desktop/src-tauri/src/lib.rs:395's `mpv.set_option(...)`.
      ['prefetch-playlist', 'yes'],
    ]) {
      try {
        await p.setProperty(kv[0], kv[1]);
      } catch (_) {
        /* non-fatal tuning */
      }
    }
  }

  // ── the per-pane tick body (port of pbTick's per-slot segment bookkeeping,
  //    called once per tick by the shared playhead clock) ────────────────

  /// Call once per tick with the shared playhead. Triggers the next-segment
  /// prefetch shortly before the current segment's boundary, and swaps
  /// across the boundary (gapless if a prefetch made it in time) once
  /// reached. No-ops if nothing is currently loaded (e.g. this camera has no
  /// footage at the playhead — [resolveAt] owns getting a segment loaded in
  /// the first place).
  Future<void> onTick(DateTime playhead) async {
    final cur = _current;
    if (cur == null) return;

    final untilEnd = cur.end.difference(playhead);
    if (untilEnd <= kPrefetchLeadTime && _prefetched == null && !_prefetching) {
      unawaited(_prefetchNext());
    }

    if (!playhead.isBefore(cur.end.subtract(kBoundaryTolerance)) &&
        !_advancing &&
        !_resolving) {
      unawaited(_advanceOrResolve(playhead));
    }
  }

  // ── prefetch (port of pbPrefetchNextSegment) ────────────────────────────

  Future<void> _prefetchNext() async {
    final cur = _current;
    if (cur == null) return;
    _prefetching = true;
    try {
      final seg = await api.resolveSegment(
        _session,
        cameraId,
        DateTime.fromMillisecondsSinceEpoch(cur.endMs + 1, isUtc: true),
        stream: stream,
      );
      // Keep only if it's genuinely a LATER segment (guard against the API
      // returning the same/overlapping one near the boundary) — mirrors
      // app.js's `seg.startMs >= cur.segEndMs - 250` guard.
      if (seg == null || seg.startMs < cur.endMs - 250) return;
      final url = await api.mediaUrlForSegment(_session, seg);
      if (url == null) return;
      try {
        await _player.add(Media(url));
        _prefetched = seg;
      } catch (_) {
        // append failed — the boundary resolve below will fall back to a
        // live fetch, matching app.js's comment on the same failure mode.
      }
    } finally {
      _prefetching = false;
    }
  }

  // ── boundary crossing (port of the gapless branch in
  //    pbResolveAllPanesInner) ────────────────────────────────────────────

  Future<void> _advanceOrResolve(DateTime playhead) async {
    final pre = _prefetched;
    if (pre != null && pre.covers(playhead)) {
      _advancing = true;
      try {
        // mpv `playlist-next weak` — the prefetch already demuxed this file
        // (prefetch-playlist=yes), so this is just a pointer move: no
        // re-init stutter.
        await _player.next();
        // mpv `playlist-clear` (keeps the now-current file) — drop the
        // played entry so the playlist never grows past {current, next}
        // over a long linear playback.
        try {
          await _player.remove(0);
        } catch (_) {
          /* best-effort trim */
        }
        _current = pre;
        _prefetched = null;
        noFootage = false;
        error = null;
        notifyListeners();
        return;
      } catch (_) {
        // Fall through to a fresh resolve.
      } finally {
        _advancing = false;
      }
    }
    await resolveAt(playhead, forceReload: false);
  }

  // ── full resolve (port of the non-gapless branch of
  //    pbResolveAllPanesInner; also used for the initial load and any
  //    explicit jump/seek) ─────────────────────────────────────────────────

  /// Resolve the segment covering `ts` and (if it differs from what's
  /// currently loaded) load it. `forceReload = true` is a jump/seek — it
  /// invalidates any pending prefetch and always reloads, even if `ts` is
  /// still technically within the current segment (the playhead moved, so
  /// the pane needs a seek regardless). `playing` controls whether a freshly
  /// opened file starts playing (mirrors mpv `loadfile`'s default vs.
  /// `pbApplyPausedToAllPanes` reasserting pause right after) — pass the
  /// caller's current play/pause state.
  Future<void> resolveAt(
    DateTime ts, {
    bool forceReload = false,
    bool playing = false,
  }) async {
    if (_resolving) return;
    _resolving = true;
    try {
      final cur = _current;
      if (forceReload) {
        _prefetched = null;
      } else if (cur != null && cur.covers(ts)) {
        return; // still covered — nothing to do (matches the cached-skip in app.js)
      }

      final seg = await api.resolveSegment(_session, cameraId, ts, stream: stream);
      if (seg == null) {
        _current = null;
        _prefetched = null;
        noFootage = true;
        error = null;
        notifyListeners();
        return;
      }
      final url = await api.mediaUrlForSegment(_session, seg);
      if (url == null) {
        error = 'Could not obtain a media token for this camera.';
        notifyListeners();
        return;
      }

      // Only push a new file if the URL actually changed (mirrors app.js's
      // `needsSync` check) — a same-URL re-resolve (e.g. a scrub that lands
      // back in the same segment) just needs a seek.
      final sameFile = cur != null && cur.url == seg.url;
      if (!sameFile) {
        await _player.open(Playlist([Media(url)]), play: playing);
        try {
          await _player.setRate(1.0);
        } catch (_) {
          /* caller/transport controller reasserts the real speed */
        }
      }
      final offsetMs = (ts.millisecondsSinceEpoch - seg.startMs)
          .clamp(0, seg.durationMs)
          .toInt();
      try {
        await _player.seek(Duration(milliseconds: offsetMs));
      } catch (_) {
        /* non-fatal */
      }
      _current = seg;
      _prefetched = null;
      noFootage = false;
      error = null;
      notifyListeners();
    } catch (e) {
      error = 'Playback resolve failed: $e';
      notifyListeners();
    } finally {
      _resolving = false;
    }
  }

  /// Cheap in-segment seek during scrub — no `/play/` round-trip. Mirrors
  /// `pbSeekAllPanes`'s same-segment branch. If `ts` has left the current
  /// segment, this is a no-op; callers should follow up with [resolveAt]
  /// once the scrub commits (mirrors the timeline's `onCommitSeek`).
  Future<void> seekWithinSegment(DateTime ts) async {
    final cur = _current;
    if (cur == null || !cur.covers(ts)) return;
    final offsetMs = (ts.millisecondsSinceEpoch - cur.startMs)
        .clamp(0, cur.durationMs)
        .toInt();
    try {
      await _player.seek(Duration(milliseconds: offsetMs));
    } catch (_) {
      /* non-fatal */
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
