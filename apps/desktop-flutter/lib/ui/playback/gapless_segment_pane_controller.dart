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
// shared playhead clock — those are cross-pane concerns owned by the playback
// screen (its transport bar + `PlaybackTimelineController`). The screen drives
// [player] directly for play/pause/speed (keeping [rate] in sync), calls
// [onTick] once per playhead tick for every active camera, and [resolveAt]
// with `forceReload` for explicit jumps/seeks.
//
// ── Two clocks, and who wins at a segment boundary ────────────────────────
// There are two independent clocks in play: the screen's shared playhead
// (wall-clock × speed) and mpv's actual decode position. They are NEVER in
// perfect lockstep — a fallback `open()` has open→seek→first-frame latency,
// and a mid-segment decode/IO stall puts mpv behind the wall clock by the
// stall length. Forcing the boundary advance (`_player.next()`) off the WALL
// clock therefore jumps mpv past every frame it hadn't shown yet: the
// operator sees smooth playback, then a "BAM" skip forward at the segment /
// motion-event boundary — worse after a stall, and non-deterministic because
// open/decode latency varies run to run. That was the frame-skip bug this
// header block documents the fix for.
//
// The fix is mode-dependent (see [onTick]'s `mpvDriven` flag):
//
//  * SINGLE active pane (maximized, or a 1-camera layout — the frame-accurate
//    review case): the screen slaves the shared playhead to [mpvPlayhead]
//    (segment start + mpv's real position), so the playhead can never run
//    ahead of the video, and the boundary is crossed by mpv ITSELF hitting
//    the real end of file: `prefetch-playlist=yes` + the appended next
//    segment make mpv auto-advance the playlist at EOF with a warm decoder
//    (the exact same mpv mechanism `playlist-next weak` rides on), showing
//    every frame of the outgoing segment. [_onPlaylistChanged] observes that
//    auto-advance and updates the segment bookkeeping after the fact. The
//    wall-clock forced `next()` is disabled in this mode.
//
//  * MULTIPLE visible panes: cross-camera time alignment matters more than
//    any one pane's last few frames, so the shared wall clock stays in charge
//    and the boundary advance stays wall-driven (a lagging pane is yanked
//    forward to stay in sync — the accepted trade-off, matching the old
//    Tauri client's behavior).
//
// `/play/{camera_id}` only ever resolves a segment COVERING the requested ts
// (404 otherwise — see services/api/src/playback.rs), so a prefetched
// playlist entry is always time-contiguous with the current segment: mpv's
// EOF auto-advance can never wander across a coverage gap into wrong-time
// footage. Gaps therefore still play out exactly as before: no prefetch
// resolves, mpv completes at EOF, the wall clock walks the gap, and the
// per-tick resolve loads footage when the playhead reaches it.
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
import '../../services/diagnostics_service.dart';

/// How long before a segment's end to kick off the prefetch of the next one.
/// Mirrors app.js's `seg.segEndMs - 1000` check in `pbTick`.
const Duration kPrefetchLeadTime = Duration(milliseconds: 1000);

/// How close to (or past) a segment's end counts as "boundary reached".
/// Mirrors app.js's `segEndMs - 100` check.
const Duration kBoundaryTolerance = Duration(milliseconds: 100);

/// Trust window after [GaplessSegmentPaneController._current] changes before
/// [GaplessSegmentPaneController.mpvPlayhead] reports a position. media_kit's
/// `state.position` is updated from an async mpv property-change stream, so
/// for a beat after an `open()` / playlist advance it can still hold the
/// PREVIOUS file's position; `newSegment.start + oldPosition` would teleport
/// the slaved playhead (forward by up to a whole segment). During this grace
/// the screen falls back to its wall clock — indistinguishable from the old
/// behavior for a few ticks, and the slaved model resumes immediately after.
const Duration kMpvPlayheadGrace = Duration(milliseconds: 300);

/// Positions at/below this count as "on the first frame of the file" for the
/// backward frame-step edge decision (cross into the previous segment).
/// One frame at 30 fps is ~33 ms, so 20 ms is safely inside frame zero for
/// any camera at ≤ 50 fps. Deliberately TIGHT: a silent
/// `frame-back-step` no-op anywhere above this falls back to an exact
/// in-file reverse seek instead — treating a mid-file no-op as an edge is
/// what made one back-click skip a whole segment.
const Duration kFirstFrameEpsilon = Duration(milliseconds: 20);

/// How far the exact-seek fallback steps backward when the native
/// `frame-back-step` reports no movement mid-file: one frame at 30 fps.
/// At lower frame rates the target still lands inside the previous frame
/// (frames are wider); at higher ones it may skip a single frame — an
/// acceptable rare-fallback error that can never skip a whole segment.
const int kReverseStepFallbackMs = 33;

class GaplessSegmentPaneController extends ChangeNotifier {
  GaplessSegmentPaneController({
    required this.api,
    required Session session,
    required this.cameraId,
    this.stream = 'main',
  }) : _session = session {
    _player = Player();
    _videoController = VideoController(_player);
    // Diagnostics (#180): player errors always captured; mpv log in verbose.
    DiagnosticsService.instance.attachPlayer('playback:$cameraId', _player);
    // Watch mpv's playlist pointer: with `prefetch-playlist=yes` and the next
    // segment appended, mpv auto-advances the playlist at the REAL end of the
    // current file. In the single-pane mpv-driven mode that auto-advance IS
    // the boundary crossing (no forced `next()` involved), so the segment
    // bookkeeping must follow it after the fact — see [_onPlaylistChanged].
    _playlistSub = _player.stream.playlist.listen(_onPlaylistChanged);
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

  /// When [_current] last changed — gates [mpvPlayhead] behind
  /// [kMpvPlayheadGrace] so a stale `state.position` from the previous file
  /// never gets attributed to the new segment (see the const's doc).
  DateTime? _currentSince;

  /// Subscription to `player.stream.playlist` (see the constructor).
  StreamSubscription<Playlist>? _playlistSub;

  bool _prefetching = false;
  bool _resolving = false;
  bool _advancing = false;

  // Coalesced follow-up resolve. A [resolveAt] call that arrives while another
  // is in-flight is NOT dropped (that desynced the pane from the playhead when
  // two quick seeks raced — #130); its target is stashed here and replayed once
  // the in-flight resolve finishes. Only the newest target is kept, but
  // [_pendingForceReload] is sticky so a forced jump in the window is never
  // silently lost.
  DateTime? _pendingResolveTs;
  bool _pendingForceReload = false;
  bool _pendingResolvePlaying = false;

  /// Playback rate to reassert after a fresh `open()`. mpv keeps `speed`
  /// across a playlist advance (the gapless path), but a fallback `loadfile`
  /// would reset an operator-chosen 4x back to 1x without this. Kept in sync
  /// by whoever owns the speed control (alongside its `player.setRate`).
  double rate = 1.0;

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
      // The back-buffer must hold AT LEAST one full GOP or mpv's native
      // `frame-back-step` cannot reach the previous frame from a paused
      // mid-GOP position and silently no-ops (the "one back-click jumps a
      // whole segment" bug: the no-movement fallback then misread the no-op
      // as a file edge). Typical main streams here run a ~1 s keyframe
      // interval at ~16 Mbps — 1 MiB was only ~0.5 s. 32 MiB retains the
      // demuxed packets of an entire multi-second segment (4 s @ 16 Mbps is
      // ~8 MiB), keeping reverse stepping cache-local; actual memory use per
      // pane is bounded by the current file's size, not by this cap.
      ['demuxer-max-back-bytes', '32MiB'],
      ['network-timeout', '10'],
      // Start muted, exactly like the live wall tiles (wall_screen.dart's
      // _WallTile sets mute=yes at creation). The shared AudioFollowController
      // is the sole owner of unmuting: it unmutes only the active (maximized
      // else selected) pane when audio is on. Without this, every playback
      // pane would start unmuted and several cameras' audio would blare at
      // once; with it, the controller's reconcile decides who is audible.
      ['mute', 'yes'],
      ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
      // Same as the wall tiles: never emit decoder output from before the
      // first keyframe. The gapless advance never decodes mid-GOP, but the
      // jump/seek fallback `loadfile` can — this masks the grey/blocky
      // partial frames it would otherwise flash.
      ['vd-lavc-show-all', 'no'],
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

  // ── mpv-truth position + EOF auto-advance bookkeeping ───────────────────

  /// The absolute time of the frame mpv is ACTUALLY showing —
  /// `currentSegment.start + player position`, clamped into the segment —
  /// or `null` when that mapping can't be trusted and the caller should fall
  /// back to its wall clock:
  ///
  ///  * no segment loaded / a resolve or advance is in flight (`position`
  ///    may belong to the outgoing file);
  ///  * within [kMpvPlayheadGrace] of the segment changing (same reason —
  ///    media_kit's position stream is async, see the const's doc);
  ///  * mpv completed the playlist (EOF with nothing appended — a coverage
  ///    gap or a lost prefetch race): position is frozen at the file end, and
  ///    slaving to it would DEADLOCK the playhead at `cur.end` forever. The
  ///    wall clock must take over to walk the gap so the per-tick resolve can
  ///    re-arm footage under it;
  ///  * not playing (paused/idle) — the transport owns pauses; a wedged pane
  ///    must not freeze the shared playhead.
  ///
  /// The playback screen slaves the shared playhead to this in the
  /// single-active-pane mode, which is what makes the UI playhead and the
  /// video physically unable to disagree (the frame-skip fix — see the file
  /// header). Polled from the screen's existing 100 ms tick rather than
  /// pushing `stream.position` events upstream: the tick already exists, and
  /// 10 Hz is well inside the timeline's visual granularity.
  DateTime? get mpvPlayhead {
    final cur = _current;
    if (cur == null || _resolving || _advancing) return null;
    final since = _currentSince;
    if (since == null || DateTime.now().difference(since) < kMpvPlayheadGrace) {
      return null;
    }
    if (_player.state.completed || !_player.state.playing) return null;
    final ms = (cur.startMs + _player.state.position.inMilliseconds)
        .clamp(cur.startMs, cur.endMs)
        .toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// mpv moved its playlist pointer. If that was mpv's own EOF auto-advance
  /// onto the appended prefetch (single-pane mpv-driven boundaries — and, as
  /// a latent-desync fix, a wall-mode pane whose decode outran the wall
  /// clock), adopt the prefetched segment as current so [mpvPlayhead] and the
  /// covers()-based tick logic stay truthful. Explicit [_advanceOrResolve]
  /// advances and in-flight resolves do their own bookkeeping and are
  /// excluded via the `_advancing` / `_resolving` guards (a stale playlist
  /// event landing mid-`open()` must not resurrect a dropped prefetch).
  ///
  /// Contiguity is guaranteed: `/play/` only resolves segments COVERING
  /// `cur.end + 1ms` (see the file header), so this can never skip the
  /// playhead across a coverage gap.
  void _onPlaylistChanged(Playlist pl) {
    if (_advancing || _resolving) return;
    final pre = _prefetched;
    if (pre == null || pl.index <= 0) return;
    // State flips are synchronous (before any await) so a burst of playlist
    // events can't double-apply the same prefetch.
    _current = pre;
    _currentSince = DateTime.now();
    _prefetched = null;
    noFootage = false;
    error = null;
    notifyListeners();
    // Trim the played entry so the playlist never grows past {current, next}
    // — the async twin of the explicit advance's `remove(0)`.
    unawaited(() async {
      try {
        await _player.remove(0);
      } catch (_) {
        /* best-effort trim */
      }
    }());
  }

  // ── the per-pane tick body (port of pbTick's per-slot segment bookkeeping,
  //    called once per tick by the shared playhead clock) ────────────────

  /// Call once per tick with the shared playhead. Triggers the next-segment
  /// prefetch shortly before the current segment's boundary, and swaps
  /// across the boundary (gapless if a prefetch made it in time) once
  /// reached. If nothing is currently loaded (this camera had no footage at
  /// the last resolve, or the pane just became active) it keeps resolving so
  /// footage under the advancing playhead loads as soon as it exists —
  /// mirrors `pbTick` re-resolving empty slots every tick. `playing` is the
  /// transport's play/pause state, applied to any fallback `loadfile`.
  ///
  /// `mpvDriven` selects the boundary-crossing model (see the file header):
  /// `false` (multi-pane wall-clock mode, the historical behavior) forces the
  /// playlist advance the moment the SHARED playhead hits the boundary — even
  /// if mpv is behind and would skip unseen frames — because cross-camera
  /// alignment wins there. `true` (single active pane, playhead slaved to
  /// [mpvPlayhead]) leaves the crossing to mpv's own EOF auto-advance so no
  /// decoded-but-unshown frame is ever jumped over; the wall-clock trigger
  /// below then only acts as the FALLBACK for the cases mpv can't advance
  /// itself out of (a coverage gap or a lost prefetch race → `completed`).
  Future<void> onTick(
    DateTime playhead, {
    bool playing = false,
    bool mpvDriven = false,
  }) async {
    final cur = _current;
    if (cur == null) {
      if (!_resolving) await resolveAt(playhead, playing: playing);
      return;
    }

    if (playhead.isBefore(cur.start)) {
      // Ride-through tolerance: when a segment FILE is slightly shorter than
      // its indexed span, mpv hits EOF "early" and auto-advances onto the
      // next segment ([_onPlaylistChanged] adopts it) while the playhead is
      // still just shy of its start. Resolving here would reopen the OLD
      // file only to replay/skip its missing tail — a pointless stutter at
      // the boundary. Let the playhead catch up instead (a beat of the next
      // segment's first frame; the slaved clock snaps forward ≤ this bound).
      // Anything further behind is a genuine backward move — really resolve.
      if (cur.start.difference(playhead) <= const Duration(milliseconds: 750)) {
        return;
      }
      // The playhead is BEHIND the loaded segment (a backwards nudge, or a
      // pane re-activated after the operator scrubbed back while it was
      // hidden) — the linear boundary logic below can never get there, so do
      // a real resolve.
      if (!_resolving) await resolveAt(playhead, playing: playing);
      return;
    }

    // Prefetch lead is scaled by the playback rate: at 8× the playhead covers
    // 8 s of timeline per real second, so a fixed 1 s lead left only ~125 ms
    // of real time for the resolve+append round-trip and the boundary kept
    // losing the race (falling back to a stuttery fresh load). The scaled
    // lead keeps ~1 s of REAL time regardless of speed.
    final leadMs = (kPrefetchLeadTime.inMilliseconds * (rate > 1 ? rate : 1))
        .round();
    final untilEnd = cur.end.difference(playhead);
    if (untilEnd.inMilliseconds <= leadMs &&
        _prefetched == null &&
        !_prefetching) {
      unawaited(_prefetchNext());
    }

    if (!playhead.isBefore(cur.end.subtract(kBoundaryTolerance)) &&
        !_advancing &&
        !_resolving) {
      if (!mpvDriven) {
        // Wall-clock mode: force the crossing now to keep panes time-aligned.
        unawaited(_advanceOrResolve(playhead, playing: playing));
      } else if (_player.state.completed &&
          (_player.state.playlist.medias.length <= 1 ||
              playhead.isAfter(cur.end.add(const Duration(seconds: 1))))) {
        // mpv-driven mode: normally mpv auto-advances at real EOF and
        // [_onPlaylistChanged] has already moved [_current] on before the
        // playhead (slaved to mpv) can even sit at the boundary — so reaching
        // here with `completed` means mpv genuinely ran out of playlist:
        // nothing was appended (gap / prefetch too slow), or the appended
        // entry failed to play (the `playhead > end + 1s` escape hatch, wall
        // clock having taken over via [mpvPlayhead] returning null). Fall
        // back to a plain resolve at the playhead — for contiguous footage
        // that loads the next segment (non-gapless but correct); in a gap it
        // resolves null → noFootage and the wall clock walks the gap exactly
        // as before. The `medias.length <= 1` guard keeps a transient
        // completed flicker during a normal auto-advance (next entry still
        // queued) from racing [_onPlaylistChanged] with a redundant open().
        unawaited(resolveAt(playhead, playing: playing));
      }
      // else: mpv is still showing real frames from this segment while the
      // slaved playhead waits (clamped) at `cur.end` — its EOF auto-advance
      // will cross the boundary without skipping any of them.
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
      // A jump/seek may have swapped the current segment while the resolve
      // was in flight — this prefetch was for the OLD linear path, drop it
      // (a forced resolve invalidates the look-ahead, as in app.js).
      if (!identical(_current, cur)) return;
      // Keep only if it's genuinely a LATER segment (guard against the API
      // returning the same/overlapping one near the boundary) — mirrors
      // app.js's `seg.startMs >= cur.segEndMs - 250` guard.
      if (seg == null || seg.startMs < cur.endMs - 250) return;
      final url = await api.mediaUrlForSegment(_session, seg);
      if (url == null || !identical(_current, cur)) return;
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
  //    pbResolveAllPanesInner) — WALL-CLOCK MODE ONLY: the single-pane
  //    mpv-driven mode never forces this; mpv's own EOF auto-advance +
  //    [_onPlaylistChanged] cross the boundary there (see onTick) ─────────

  Future<void> _advanceOrResolve(
    DateTime playhead, {
    bool playing = false,
  }) async {
    final pre = _prefetched;
    if (pre != null && pre.covers(playhead)) {
      _advancing = true;
      try {
        // mpv `playlist-next weak` — the prefetch already demuxed this file
        // (prefetch-playlist=yes), so this is just a pointer move: no
        // re-init stutter. If mpv is still mid-segment this deliberately
        // jumps it forward (the multi-pane sync-over-smoothness trade-off);
        // if mpv already auto-advanced at EOF on its own, `next()` on the
        // last playlist entry is a no-op and [_onPlaylistChanged] (or the
        // bookkeeping below) has already/will have converged `_current`.
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
        _currentSince = DateTime.now();
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
    await resolveAt(playhead, forceReload: false, playing: playing);
  }

  /// Invalidate a prefetched-but-not-yet-played next segment: forget it AND
  /// best-effort remove its appended playlist entry (always the LAST entry —
  /// the playlist never grows past {current, next}). Without the removal,
  /// mpv's EOF auto-advance could wander into wrong-time footage when the
  /// current file runs out with the playhead sitting in a coverage gap.
  /// Paths that go on to `open()` don't strictly need it (open replaces the
  /// whole playlist), but the paths that DON'T open (a jump landing in a
  /// gap) do.
  Future<void> _dropPrefetch() async {
    if (_prefetched == null) return;
    _prefetched = null;
    try {
      final n = _player.state.playlist.medias.length;
      if (n > 1) await _player.remove(n - 1);
    } catch (_) {
      /* best-effort */
    }
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
    if (_resolving) {
      // Coalesce to the newest request and replay it after the in-flight
      // resolve finishes (see the fields above) rather than dropping it. A
      // forced jump stays forced even if a later non-forced call overwrites the
      // target.
      _pendingResolveTs = ts;
      _pendingForceReload = _pendingForceReload || forceReload;
      _pendingResolvePlaying = playing;
      return;
    }
    _resolving = true;
    try {
      final cur = _current;
      if (forceReload) {
        await _dropPrefetch();
      } else if (cur != null && cur.covers(ts)) {
        return; // still covered — nothing to do (matches the cached-skip in app.js)
      }

      final seg = await api.resolveSegment(
        _session,
        cameraId,
        ts,
        stream: stream,
      );
      if (seg == null) {
        await _dropPrefetch();
        _current = null;
        _currentSince = null; // no segment → mpvPlayhead has nothing to map
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
        // Open PAUSED, then seek, then resume below — never `play: playing`.
        // Opening with play=true starts decoding from the segment START at
        // once, and the seek to the target offset only lands a beat later
        // (after loadfile + the first frames), so the pane visibly plays
        // wrong-time footage and then does a big forward jump to the target.
        // That is the "huge jump" seen when opening a plate/bookmark deep into
        // a segment — and it is worse on a slower machine, where the open→seek
        // gap is larger. Seeking while paused renders the exact target frame
        // first; playback (if any) resumes only after it has landed.
        await _player.open(Playlist([Media(url)]), play: false);
        try {
          await _player.setRate(rate);
        } catch (_) {
          /* non-fatal — the transport owner reasserts speed on its next change */
        }
        // The offset seek below MUST wait for the file to finish loading:
        // media_kit's open() returns before mpv's file-loaded, and mpv
        // silently REJECTS seeks issued mid-load (media_kit logs, never
        // throws). Without this gate the pane lands on the segment's FIRST
        // frame while the playhead shows the clicked time — invisible on a
        // static scene, then "exposed" by the first frame-step truthfully
        // mapping mpv's real position and snapping the playhead a whole
        // segment (the #186 no-motion ~4s jump).
        await _awaitFileLoaded();
      }
      final offsetMs = (ts.millisecondsSinceEpoch - seg.startMs)
          .clamp(0, seg.durationMs)
          .toInt();
      try {
        await _player.seek(Duration(milliseconds: offsetMs));
      } catch (_) {
        /* non-fatal */
      }
      // Resume only after the seek has landed on a freshly opened file, so the
      // first shown frame is the target rather than the segment start.
      if (!sameFile && playing) {
        try {
          await _player.play();
        } catch (_) {
          /* non-fatal — the transport owner reasserts play on its next change */
        }
      }
      _current = seg;
      _currentSince = DateTime.now();
      _prefetched = null;
      noFootage = false;
      error = null;
      notifyListeners();
    } catch (e) {
      error = 'Playback resolve failed: $e';
      notifyListeners();
    } finally {
      _resolving = false;
      _replayPendingResolve();
    }
  }

  /// Wait (bounded) for a just-`open()`ed file to actually finish loading
  /// before issuing its offset seek. mpv rejects seeks while a file is still
  /// loading, and media_kit's `open()` returns as soon as the load *begins* —
  /// so an immediate seek is silently dropped (media_kit only logs the mpv
  /// error) and the pane sits on the file's first frame while the app thinks
  /// it seeked (#186). mpv's `duration` flips 0 → real exactly at
  /// file-loaded (`open()` resets it to 0 first), so that's the gate.
  /// Timeout → proceed and seek anyway: the worst case is today's behavior,
  /// never a new hang.
  Future<void> _awaitFileLoaded() async {
    if (_player.state.duration > Duration.zero) return;
    try {
      await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      /* best-effort — see doc */
    }
  }

  /// Replay the newest [resolveAt] request that raced an in-flight resolve
  /// (or a boundary-crossing frame-step, which holds the same `_resolving`
  /// lock), if any. Snapshot and clear the pending slot first so a request
  /// arriving during the replay coalesces afresh instead of being lost.
  /// Extracted so every `_resolving = false` path releases the queue the
  /// same way.
  void _replayPendingResolve() {
    final pendingTs = _pendingResolveTs;
    if (pendingTs == null) return;
    final pendingForce = _pendingForceReload;
    final pendingPlaying = _pendingResolvePlaying;
    _pendingResolveTs = null;
    _pendingForceReload = false;
    _pendingResolvePlaying = false;
    unawaited(
      resolveAt(pendingTs, forceReload: pendingForce, playing: pendingPlaying),
    );
  }

  // ── frame-step (port of pbFrameStep, app.js:7627 →
  //    `frame_step_pane`, src-tauri/src/lib.rs:1219) ───────────────────────

  /// Step exactly ONE frame forward/backward using libmpv's native
  /// `frame-step` / `frame-back-step` commands — the same commands the old
  /// Tauri client invoked over IPC. The previous approximation (seek by
  /// `1000/estimated-vf-fps` ms) broke down stepping BACKWARD: mpv resolves
  /// a backward seek to the nearest keyframe, so repeated back-steps snapped
  /// to the same keyframe forever — the "back button does nothing / gets
  /// stuck" symptom. The native commands are frame-exact in both directions.
  ///
  /// Boundary crossing: when a back-step lands at (or a forward-step at the
  /// end can't leave) the current file, this resolves the ADJACENT segment,
  /// opens it paused, and lands on its nearest edge frame — so stepping
  /// walks across segment boundaries instead of dead-ending at them.
  ///
  /// Returns the absolute time of the frame now showing (for the caller to
  /// snap the shared playhead to, keeping the two clocks consistent — the
  /// old code never updated the playhead on a step at all), or `null` if
  /// nothing moved (no footage loaded, adjacent-segment miss, or an error —
  /// all non-fatal, mirroring pbFrameStep's per-slot `.catch(warn)`).
  ///
  /// Caller contract: pause the transport BEFORE stepping (mpv's step
  /// commands pause the player themselves; the transport state must agree).
  Future<DateTime?> frameStep(bool forward) async {
    final cur = _current;
    if (cur == null || _resolving || _advancing) return null;
    final p = _player.platform;
    if (p is! NativePlayer) return null; // desktop is always NativePlayer
    final before = _player.state.position;
    final idxBefore = _player.state.playlist.index;
    try {
      await p.command([forward ? 'frame-step' : 'frame-back-step']);
    } catch (_) {
      return null;
    }
    // The step decodes asynchronously — wait for the position to actually
    // move (or time out: mpv's step commands are silent no-ops at the file
    // edges, which is exactly the boundary case handled below). Backward
    // steps get a longer wait: a `frame-back-step` whose GOP fell out of the
    // demuxer back-buffer is a real (possibly network) seek plus a
    // decode-forward of up to a whole GOP, easily slower than the forward
    // step's single-frame decode.
    final after = await _positionAfter(
      before,
      timeout: forward
          ? const Duration(milliseconds: 300)
          : const Duration(milliseconds: 500),
    );
    // A forward step at the very last frame trips EOF instead of showing a
    // new frame. `completed` (playlist ran out) is checked BEFORE trusting a
    // position emission, because media_kit may reset the position on
    // playlist end — mapping that reset as "movement" would snap the
    // playhead to the segment start.
    if (_player.state.completed) {
      return forward ? _openAdjacentForStep(cur, forward: true) : null;
    }
    if (after != null) {
      if (_player.state.playlist.index != idxBefore) {
        // The forward step at the last frame tripped EOF and mpv auto-
        // advanced onto the appended prefetch (only possible when the
        // operator paused within the prefetch window). [_onPlaylistChanged]
        // adopts the new segment; give the position stream a beat to reflect
        // the NEW file before mapping, then fall through to the re-read of
        // [_current] below.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final seg = _current ?? cur;
      final ms = (seg.startMs + _player.state.position.inMilliseconds)
          .clamp(seg.startMs, seg.endMs)
          .toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    // No position emission inside the wait — but that is NOT proof of a
    // file edge. Re-sample first: the step (or a just-finished open/seek's
    // async position update) may have landed between the timeout and now.
    final resampled = _player.state.position;
    if (resampled != before) {
      final seg = _current ?? cur;
      final ms = (seg.startMs + resampled.inMilliseconds)
          .clamp(seg.startMs, seg.endMs)
          .toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    if (!forward) {
      // A silent backward no-op mid-file means mpv could not REACH the
      // previous frame (its GOP evicted from the demuxer back-buffer, or the
      // internal re-seek outran the wait) — it does not mean there is no
      // previous frame. Cross to the previous segment ONLY when the position
      // is genuinely on the file's first frame; anywhere else, fall back to
      // an exact in-file reverse seek of ~one frame, which can never skip a
      // whole segment. (Misreading the mid-file no-op as an edge was the
      // "one back-click jumps ~a whole segment" bug.)
      if (before <= kFirstFrameEpsilon) {
        return _openAdjacentForStep(cur, forward: false);
      }
      return _reverseStepFallback(cur, before);
    }
    final dur = _player.state.duration;
    if (dur > Duration.zero &&
        dur - before <= const Duration(milliseconds: 200)) {
      return _openAdjacentForStep(cur, forward: true);
    }
    return null;
  }

  /// The native `frame-back-step` reported no movement while mid-file (see
  /// [frameStep]): step backward with an exact absolute seek instead.
  /// Absolute seeks are hr-precise in mpv, so this decodes and shows the
  /// frame covering `before − ~1 frame` — nearest-frame rather than
  /// frame-exact at unusual frame rates, but strictly bounded to about one
  /// frame of error. Returns the mapped absolute time of the target (using
  /// the observed landing position when the player confirms it in time).
  Future<DateTime?> _reverseStepFallback(
    ResolvedSegment cur,
    Duration before,
  ) async {
    final targetMs = (before.inMilliseconds - kReverseStepFallbackMs)
        .clamp(0, before.inMilliseconds)
        .toInt();
    try {
      await _player.seek(Duration(milliseconds: targetMs));
    } catch (_) {
      return null;
    }
    // Best-effort settle so `state.position` is truthful for the NEXT step;
    // fall back to the seek target (the seek was issued — mpv will land it).
    final landed = await _positionAfter(before);
    final posMs = landed?.inMilliseconds ?? targetMs;
    final seg = _current ?? cur;
    final ms = (seg.startMs + posMs).clamp(seg.startMs, seg.endMs).toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// First position emitted by the player that differs from [before], or
  /// `null` on timeout. Used to observe an async mpv command (frame-step)
  /// landing.
  Future<Duration?> _positionAfter(
    Duration before, {
    Duration timeout = const Duration(milliseconds: 300),
  }) async {
    try {
      return await _player.stream.position
          .firstWhere((pos) => pos != before)
          .timeout(timeout);
    } catch (_) {
      // TimeoutException, or the stream closed under us (dispose race).
      return null;
    }
  }

  /// Frame-step ran off the edge of the current file: resolve the segment
  /// adjacent to it, open it paused, and land near the edge we stepped over
  /// (its first frame going forward; just shy of its last frame going
  /// backward). Returns the landed absolute time, or `null` when there is no
  /// adjacent footage (retention edge, or a coverage gap — stepping does NOT
  /// jump gaps; that's a scrub/jump decision, not a one-frame nudge).
  ///
  /// Probes the edge ±1 ms first (contiguous files), then ±750 ms as a
  /// fallback for the sub-second indexing seams a recorder restart can leave
  /// (still under the server's 1 s span-merge tolerance, so anything the
  /// timeline paints as continuous is steppable). `/play/` only resolves
  /// COVERING segments, so a probe inside a real gap misses both times.
  ///
  /// Holds the `_resolving` lock (and replays coalesced [resolveAt] requests
  /// on release) so a concurrent seek/jump can't open a different file
  /// mid-step.
  Future<DateTime?> _openAdjacentForStep(
    ResolvedSegment cur, {
    required bool forward,
  }) async {
    if (_resolving) return null;
    _resolving = true;
    try {
      ResolvedSegment? seg;
      for (final probeMs
          in forward
              ? [cur.endMs + 1, cur.endMs + 750]
              : [cur.startMs - 1, cur.startMs - 750]) {
        seg = await api.resolveSegment(
          _session,
          cameraId,
          DateTime.fromMillisecondsSinceEpoch(probeMs, isUtc: true),
          stream: stream,
        );
        if (seg != null) break;
      }
      if (seg == null) return null; // no adjacent footage — stay put
      // Direction sanity: the probe must have found a genuinely earlier /
      // later file, never the current one again (mirrors _prefetchNext's
      // same/overlapping guard).
      if (forward
          ? seg.startMs < cur.endMs - 250
          : seg.startMs >= cur.startMs) {
        return null;
      }
      final url = await api.mediaUrlForSegment(_session, seg);
      if (url == null) return null;
      // open() replaces the whole playlist, taking any appended prefetch
      // with it — forget the bookkeeping to match.
      _prefetched = null;
      await _player.open(Playlist([Media(url)]), play: false);
      try {
        await _player.setRate(rate);
      } catch (_) {
        /* non-fatal — the transport owner reasserts speed on its next change */
      }
      // Same dropped-seek gate as resolveAt (#186): without it the backward
      // cross's `durationMs - 200` seek is rejected mid-load and the pane
      // lands on the previous segment's FIRST frame — whose position ≈ 0 the
      // next back-press reads as "at the file start" and crosses ANOTHER
      // segment (the repeated whole-segment back-jump #192 only softened).
      await _awaitFileLoaded();
      // Landing offset: first frame going forward. Going backward, aim a few
      // frames shy of the end (200 ms) rather than the exact last frame —
      // the indexed duration can slightly overshoot the real file, and a
      // paused seek pinned to/past EOF risks tripping playlist-end (a black
      // pane). Absolute seeks are hr-precise in mpv, so this lands where it
      // aims.
      final offMs = forward
          ? 0
          : (seg.durationMs - 200).clamp(0, seg.durationMs).toInt();
      try {
        await _player.seek(Duration(milliseconds: offMs));
      } catch (_) {
        /* non-fatal */
      }
      // Give the async position stream a bounded beat to reflect the fresh
      // open+seek: `open()` resets `state.position` to zero, and an
      // immediate follow-up [frameStep] reading that stale zero would judge
      // itself "at the file start" and cross ANOTHER segment backward (the
      // repeated whole-segment back-jump). Best-effort — stepping stays
      // correct without it thanks to frameStep's re-sample, just less sharp.
      try {
        await _player.stream.position.first.timeout(
          const Duration(milliseconds: 400),
        );
      } catch (_) {
        /* best-effort */
      }
      _current = seg;
      _currentSince = DateTime.now();
      noFootage = false;
      error = null;
      notifyListeners();
      final ms = (seg.startMs + offMs).clamp(seg.startMs, seg.endMs).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    } catch (_) {
      return null;
    } finally {
      _resolving = false;
      _replayPendingResolve();
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
    // Cancel before disposing the player so a final playlist event can't
    // touch a disposed Player from [_onPlaylistChanged].
    unawaited(_playlistSub?.cancel());
    _playlistSub = null;
    // Detach the (potentially seconds-long) libmpv teardown from the calling
    // isolate — media_kit/libmpv's Player.dispose() can block for seconds
    // while the native mpv handle winds down, and PlaybackScreen.dispose()
    // tears down every pane's controller in a tight synchronous loop. On a
    // 9-16 camera playback wall that reproduces the same multi-second UI
    // freeze the live wall already worked around (its
    // `_disposePlayerDetached` helper, wall_screen.dart — issue #105).
    // Nothing reads `_player` after this ChangeNotifier is disposed, so it's
    // safe to let the native teardown finish on its own after this returns.
    final player = _player;
    unawaited(Future(() => player.dispose()));
    super.dispose();
  }
}
