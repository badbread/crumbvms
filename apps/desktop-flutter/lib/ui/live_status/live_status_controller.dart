// Live status poll — port of app.js's `liveStatusPoll` / `fetchActiveDetections`
// / `maybeApplyConfigChange` / `setConnLostBanner` / `applyBookmarksEnabled`
// (apps/desktop/src/app.js ~2540-2820) to a Flutter `ChangeNotifier`.
//
// Every 3s, while active:
//   - GET /status  → per-camera {recording, recent_motion}, config_version,
//                     bookmarks_enabled.
//   - GET /events?camera_ids=...&start=now-25s&end=now+5s&limit=100 (parallel)
//     → active object-detection glyphs per camera (in-progress events, plus an
//     8s linger after `end_ts` so brief detections don't flicker off instantly).
//
// Failure handling mirrors the old client: a transient failure keeps the last
// known indicator state (never blank the wall on one bad tick); after 3
// consecutive failures `connectionLost` flips true so the UI can show a
// "connection lost, indicators may be stale" banner. A failed /events fetch
// alone does NOT clear existing detection glyphs (keeps last-known rather
// than flickering empty), matching `detMap === null` semantics in app.js.
//
// Config-version changes are debounced 1.5s (a flurry of edits / a repeated
// reconcile bump collapses into one re-fetch) and skip the FIRST observation
// (so simply opening the wall doesn't trigger a spurious reload).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/ha_api.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/status_api.dart';
import 'package:crumb_desktop/api/status_models.dart';

/// Polls `/status` + `/events` every 3s and exposes per-camera badges, a
/// connection-lost flag, the bookmarks-enabled toggle, and a config-change
/// signal the owner can use to re-fetch cameras/streams.
///
/// Usage (in a screen's `State`):
/// ```dart
/// late final LiveStatusController _liveStatus;
///
/// @override
/// void initState() {
///   super.initState();
///   _liveStatus = LiveStatusController(api: widget.api, session: widget.session)
///     ..onConfigChanged = _reloadCameraConfig
///     ..start();
/// }
///
/// @override
/// void dispose() {
///   _liveStatus.dispose();
///   super.dispose();
/// }
/// ```
/// Then wrap the tile grid (or individual tiles) in an
/// `AnimatedBuilder(animation: _liveStatus, builder: ...)` and read
/// `_liveStatus.cameraFor(camera.id)` / `_liveStatus.detectionKeysFor(camera.id)`.
class LiveStatusController extends ChangeNotifier {
  LiveStatusController({
    required this.api,
    required this.session,
    this.pollInterval = const Duration(seconds: 3),
    this.failuresBeforeConnLost = 3,
    this.detectionLinger = const Duration(seconds: 8),
    this.detectionLookback = const Duration(seconds: 25),
    this.detectionLookahead = const Duration(seconds: 5),
    this.configReloadDebounce = const Duration(milliseconds: 1500),
  });

  final CrumbApi api;

  /// The session whose bearer token authenticates every poll. NOT final: an
  /// in-place re-auth (see `main.dart`'s session-change handler) mints a fresh
  /// token, and this long-lived poller must adopt it via [updateSession] or it
  /// keeps hitting `/status` + `/events` with the dead token — surfacing a
  /// false "connection lost" and stale/empty badges forever.
  Session session;

  final Duration pollInterval;
  final int failuresBeforeConnLost;
  final Duration detectionLinger;
  final Duration detectionLookback;
  final Duration detectionLookahead;
  final Duration configReloadDebounce;

  /// Camera ids to poll for. The owner updates this (e.g. from the current
  /// camera list) before/while polling; an empty list still polls `/status`
  /// (still drives recording/motion + config/bookmarks) but skips `/events`.
  List<String> cameraIds = const [];

  /// Whether to also poll `GET /ha/states` this tick (issue #170 P0 plan
  /// §4.4). The owner sets this to `true` iff at least one visible camera has
  /// at least one placed HA badge — while `false`, `/ha/states` is NEVER
  /// fetched at all (the client half of the energy-lean "poll on demand"
  /// contract; the server side already caches/no-ops when nobody asks).
  bool wantHaStates = false;

  /// Called (debounced) when `/status.config_version` changes after the first
  /// observation — the owner should re-fetch cameras + streams and re-sync
  /// panes. Optional; if unset, config changes are still tracked in
  /// [configVersion] but nothing is auto-triggered.
  VoidCallback? onConfigChanged;

  Timer? _timer;
  Timer? _configDebounce;
  bool _inFlight = false;
  int _failStreak = 0;
  bool _disposed = false;

  Map<String, CameraStatus> _byCameraId = const {};
  Map<String, Set<String>> _detectionKeysByCameraId = const {};
  String? _configVersion; // null = not yet observed
  bool _bookmarksEnabled = true;
  bool _connectionLost = false;

  /// Last-known `/ha/states` snapshot (kept across a failed poll — never
  /// blank the badges on one bad tick, same rationale as `_byCameraId`).
  /// Null until the first successful fetch while [wantHaStates] is true.
  HaStatesSnapshot? _haStates;

  /// Consecutive `/ha/states` fetch failures while [wantHaStates] is true;
  /// mirrors `_failStreak` but scoped to the HA feed only (an HA outage must
  /// grey the badges without flipping the whole-wall `connectionLost`
  /// banner).
  int _haMissStreak = 0;

  /// Latest per-camera status, keyed by camera id. Empty until the first
  /// successful poll.
  Map<String, CameraStatus> get byCameraId => _byCameraId;

  /// Latest active detection icon keys per camera (e.g. {"person", "car"}).
  /// Empty set / absent key = no active detections for that camera.
  Map<String, Set<String>> get detectionKeysByCameraId => _detectionKeysByCameraId;

  /// `true` once 3 consecutive poll failures have occurred; indicators may be
  /// stale. Clears on the next successful poll.
  bool get connectionLost => _connectionLost;

  /// Platform-wide bookmarks-UI toggle from the last successful poll.
  bool get bookmarksEnabled => _bookmarksEnabled;

  String? get configVersion => _configVersion;

  CameraStatus? cameraFor(String cameraId) => _byCameraId[cameraId];

  Set<String> detectionKeysFor(String cameraId) =>
      _detectionKeysByCameraId[cameraId] ?? const {};

  /// Latest known state for `entityId` from the last successful `/ha/states`
  /// poll, or null when no state is known yet (never polled, or the entity
  /// isn't in the caller-visible set). A null return is "unknown", NOT
  /// "off" — callers (e.g. `ha_overlay/ha_icons.dart`'s `haVisualFor`) must
  /// treat it as indeterminate, matching the backend's `edge_on` invariant.
  HaEntityState? haStateFor(String entityId) => _haStates?.byEntity[entityId];

  /// True when the HA badges should render the grey/stale treatment: either
  /// the server's own snapshot is marked stale (HA unreachable past its
  /// cache TTL) or this poller has missed 2+ consecutive `/ha/states` fetches
  /// itself. Mirrors `connectionLost`'s "never lie about staleness" rule, but
  /// scoped to the HA feed so an HA outage doesn't trip the whole-wall
  /// connection-lost banner.
  bool get haStale => (_haStates?.stale ?? false) || _haMissStreak >= 2;

  void start() {
    _timer?.cancel();
    // Fire immediately, then every [pollInterval].
    unawaited(_poll());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Adopt a refreshed [session] (e.g. after an in-place re-auth) so subsequent
  /// polls use the new bearer token. Safe to call while polling; the next tick
  /// picks it up. Clears the connection-lost state so a stale-token banner
  /// doesn't linger past a successful re-auth.
  void updateSession(Session next) {
    if (identical(session, next)) return;
    session = next;
    if (_connectionLost || _failStreak != 0) {
      _failStreak = 0;
      _connectionLost = false;
      notifyListeners();
    }
  }

  Future<void> _poll() async {
    if (_disposed || _inFlight) return; // re-entrancy guard (slow/wedged server)
    _inFlight = true;
    try {
      final now = DateTime.now();
      SystemStatus? status;
      EventsResponse? events;
      HaStatesSnapshot? haSnapshot;
      Object? statusError;
      try {
        final futures = <Future<Object?>>[
          api.getStatus(session),
          api
              .getEvents(
                session,
                cameraIds: cameraIds,
                start: now.subtract(detectionLookback),
                end: now.add(detectionLookahead),
              )
              // A failed /events fetch shouldn't fail the whole tick or clear
              // existing glyphs — surface as null and keep the last-known set.
              .then<EventsResponse?>((v) => v)
              .catchError((_) => null),
        ];
        // Only polled when at least one visible camera has a placed badge —
        // the energy-lean half of the "poll on demand" contract (issue #170
        // P0 plan §4.4). Same failure isolation as /events: a bad tick keeps
        // the last-known snapshot rather than blanking the badges.
        if (wantHaStates) {
          futures.add(
            api
                .haStates(session)
                .then<HaStatesSnapshot?>((v) => v)
                .catchError((_) => null),
          );
        }
        final results = await Future.wait(futures, eagerError: false);
        status = results[0] as SystemStatus;
        events = results[1] as EventsResponse?;
        if (wantHaStates) haSnapshot = results[2] as HaStatesSnapshot?;
      } catch (e) {
        statusError = e;
      }

      if (_disposed) return;

      if (statusError != null || status == null) {
        _failStreak += 1;
        if (_failStreak >= failuresBeforeConnLost && !_connectionLost) {
          _connectionLost = true;
          notifyListeners();
        }
        return;
      }

      _byCameraId = {for (final c in status.cameras) c.id: c};
      _bookmarksEnabled = status.bookmarksEnabled;
      _maybeApplyConfigChange(status.configVersion);

      if (events != null) {
        _detectionKeysByCameraId = _activeDetectionKeys(events, now);
      }
      // else: keep the previous _detectionKeysByCameraId as-is.

      if (wantHaStates) {
        if (haSnapshot != null) {
          _haStates = haSnapshot;
          _haMissStreak = 0;
        } else {
          // Keep the previous _haStates as-is (last-known); count the miss
          // toward haStale.
          _haMissStreak += 1;
        }
      }

      _failStreak = 0;
      _connectionLost = false;
      notifyListeners(); // fresh status/detections/config every successful tick
    } finally {
      _inFlight = false;
    }
  }

  /// In-progress events (no `end_ts`) plus a short linger after `end_ts` so
  /// brief detections don't flicker out the instant they end. Motion itself
  /// is conveyed via `recent_motion`, not as a tile glyph, so `icon_key ==
  /// "motion"` is excluded here.
  Map<String, Set<String>> _activeDetectionKeys(EventsResponse resp, DateTime now) {
    final map = <String, Set<String>>{};
    for (final e in resp.events) {
      if (e.iconKey.isEmpty || e.iconKey == 'motion') continue;
      final active = e.endTs == null || now.difference(e.endTs!) < detectionLinger;
      if (!active) continue;
      (map[e.cameraId] ??= <String>{}).add(e.iconKey);
    }
    return map;
  }

  void _maybeApplyConfigChange(String cv) {
    if (cv.isEmpty) return;
    final prev = _configVersion;
    // Skip the first observation — starting the poller shouldn't itself
    // trigger a reload.
    if (prev != null && cv != prev) {
      _configDebounce?.cancel();
      _configDebounce = Timer(configReloadDebounce, () {
        if (!_disposed) onConfigChanged?.call();
      });
    }
    _configVersion = cv;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _configDebounce?.cancel();
    super.dispose();
  }
}
