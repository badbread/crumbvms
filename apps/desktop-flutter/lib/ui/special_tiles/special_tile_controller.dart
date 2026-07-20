// Runtime engine for the two VIDEO special tiles — carousel and hotspot —
// that resolve to a live camera id the host's existing camera-tile widget
// renders (same pane machinery as a plain `{type:"camera"}` slot). Port of
// app.js's applySlotItems / carouselStartFromSpec / carouselMotionTick /
// hotspotMotionTick / pickHotspotCam / routeHotspotClick
// (apps/desktop/src/app.js ~1468-1600, ~5540-5635).
//
// The DOM-only special tiles (clock/text/image/web/events) don't need this
// controller — they render standalone via `specialTileWidget()` in
// special_tile_widgets.dart with no camera pane underneath.
//
// Usage (in the host wall screen's State):
// ```dart
// late final SpecialTileController _special;
//
// @override
// void initState() {
//   super.initState();
//   _special = SpecialTileController(allCameraIds: () => widget.cameras.map((c) => c.id).toList())
//     ..addListener(() => setState(() {}));
// }
//
// // whenever the slot->spec map changes (view applied/edited):
// _special.applySpecs(specialSpecsBySlot);
//
// // every LiveStatusController tick (recent_motion changed):
// _special.onMotionTick(recentMotionCameraIds: liveStatus.byCameraId.values
//     .where((c) => c.recentMotion).map((c) => c.id).toSet());
//
// // on a left-click/select of a plain camera slot showing `cameraId`:
// _special.routeHotspotClick(cameraId);
//
// // render: _special.resolvedCamera(slot) -> String? cameraId to show in that slot.
// ```
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'special_tile_spec.dart';

class _CarouselState {
  _CarouselState({required this.cameras, required this.intervalMs, required this.mode});
  List<String> cameras;
  int intervalMs;
  CarouselMode mode;
  int idx = 0;
  Timer? timer;

  void stop() {
    timer?.cancel();
    timer = null;
  }
}

class _HotspotAutoState {
  String? cam;
  DateTime? lastSwitch;
  bool pinned = false;
}

/// Holds up to one slot's worth of "this slot is maximized, freeze it" info —
/// mirrors app.js's `state.maximized` guard in carousel/_show and
/// hotspotMotionTick so a maximized carousel/hotspot doesn't churn underneath
/// the operator. The host sets this when it maximizes/restores a slot.
class SpecialTileController extends ChangeNotifier {
  SpecialTileController({
    required List<String> Function() allCameraIds,
    this.hotspotDwell = const Duration(milliseconds: 4000),
  }) : _allCameraIds = allCameraIds;

  final List<String> Function() _allCameraIds;

  /// Hold a freshly-switched auto-hotspot camera this long before switching to
  /// another mover, so a busy wall doesn't strobe (HOTSPOT_DWELL_MS in app.js).
  final Duration hotspotDwell;

  Map<int, SpecialTileSpec> _specs = const {};
  final Map<int, _CarouselState> _carousels = {};
  final Map<int, _HotspotAutoState> _hotspotAuto = {};

  /// The classic click-hotspot's shared target (state.hotspotCam in app.js).
  String? _clickHotspotCam;

  /// Resolved camera id per slot for carousel/hotspot slots.
  final Map<int, String?> _resolved = {};

  /// The slot currently maximized/frozen, or null. Set by the host so a
  /// maximized carousel/hotspot tile stops advancing underneath it.
  int? frozenSlot;

  String? resolvedCamera(int slot) => _resolved[slot];

  /// Apply a fresh slot -> special-spec map (e.g. after a view is applied or
  /// edited). Non-video specs (clock/text/image/web/events) are ignored here
  /// — they carry no resolved camera. Starts/stops carousel timers as needed.
  void applySpecs(Map<int, SpecialTileSpec> specs) {
    _specs = specs;
    // Slot indices mean something else in the incoming view — a stale frozen
    // index could freeze an arbitrary slot of the new layout (#269).
    frozenSlot = null;

    // Stop + drop carousels for slots no longer carrying a carousel spec.
    for (final slot in _carousels.keys.toList()) {
      final sp = specs[slot];
      if (sp is! CarouselSpec) {
        _carousels.remove(slot)?.stop();
        _resolved.remove(slot);
      }
    }
    // (Re)start carousels — a changed spec (cameras/interval/mode) restarts
    // from the top, matching app.js's carouselStartFromSpec always calling
    // carouselStop(slot) first.
    for (final entry in specs.entries) {
      final sp = entry.value;
      if (sp is CarouselSpec) _startCarousel(entry.key, sp);
    }

    // Hotspot bookkeeping: split into auto-follow (cameras set) vs classic
    // (shared click target) slots, mirroring applySlotItems in app.js.
    final autoSlots = <int, HotspotSpec>{};
    final clickSlots = <int>[];
    for (final entry in specs.entries) {
      final sp = entry.value;
      if (sp is! HotspotSpec) continue;
      if (sp.isAutoFollow) {
        autoSlots[entry.key] = sp;
      } else {
        clickSlots.add(entry.key);
      }
    }
    // Drop stale per-slot dwell state.
    for (final s in _hotspotAuto.keys.toList()) {
      if (!autoSlots.containsKey(s)) _hotspotAuto.remove(s);
    }
    // Seed each auto-hotspot immediately (most-recent motion, else first
    // camera) so the tile shows something before the next motion tick.
    autoSlots.forEach((slot, sp) {
      final st = _hotspotAuto.putIfAbsent(slot, () => _HotspotAutoState());
      if (st.cam == null || !sp.cameras.contains(st.cam)) {
        st.cam = sp.cameras.isNotEmpty ? sp.cameras.first : null;
        st.lastSwitch = null;
        st.pinned = false;
      }
      _resolved[slot] = st.cam;
    });
    for (final s in clickSlots) {
      _resolved[s] = _clickHotspotCam;
    }
    notifyListeners();
  }

  void _startCarousel(int slot, CarouselSpec spec) {
    _carousels.remove(slot)?.stop();
    final all = _allCameraIds();
    var cams = (spec.cameras.isNotEmpty ? spec.cameras : all)
        .where(all.contains)
        .toList(growable: false);
    if (cams.isEmpty) cams = all;
    if (cams.isEmpty) {
      _resolved[slot] = null;
      return;
    }
    final intervalMs = spec.intervalMs < 2000 ? 8000 : spec.intervalMs;
    final st = _CarouselState(cameras: cams, intervalMs: intervalMs, mode: spec.mode);
    final prev = _resolved[slot];
    final pos = prev != null ? cams.indexOf(prev) : -1;
    st.idx = pos >= 0 ? pos : 0;
    _resolved[slot] = cams[st.idx];
    if (spec.mode == CarouselMode.time || spec.mode == CarouselMode.both) {
      st.timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
        if (frozenSlot == slot) return; // maximized on this slot — don't churn
        if (st.mode == CarouselMode.time) {
          _advanceCarousel(slot, st);
        } else if (st.mode == CarouselMode.both) {
          final motionSet = _lastMotion;
          final anyMoving = st.cameras.any(motionSet.contains);
          if (!anyMoving) _advanceCarousel(slot, st);
        }
      });
    }
    _carousels[slot] = st;
  }

  void _advanceCarousel(int slot, _CarouselState st) {
    st.idx = (st.idx + 1) % st.cameras.length;
    _resolved[slot] = st.cameras[st.idx];
    notifyListeners();
  }

  Set<String> _lastMotion = const {};

  /// Last poll timestamp (ms) at which each camera was seen with
  /// `recent_motion` — mirrors app.js's `camLastMotionTs`, used to break ties
  /// among several currently-moving cameras in favor of the most recent one.
  final Map<String, int> _lastMotionTsMs = {};

  /// Call on every live-status poll tick (e.g. from `LiveStatusController`'s
  /// listener) with the current set of camera ids showing `recent_motion`.
  /// Drives motion/both-mode carousels and auto-follow hotspots
  /// (carouselMotionTick / hotspotMotionTick in app.js).
  void onMotionTick({required Set<String> recentMotionCameraIds}) {
    _lastMotion = recentMotionCameraIds;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final id in recentMotionCameraIds) {
      _lastMotionTsMs[id] = nowMs;
    }
    var changed = false;

    // Motion-mode carousels jump to a moving camera in their set.
    _carousels.forEach((slot, st) {
      if (st.mode != CarouselMode.motion && st.mode != CarouselMode.both) return;
      if (frozenSlot == slot) return;
      final movers = st.cameras.where(recentMotionCameraIds.contains).toList();
      if (movers.isEmpty) return; // quiet -> hold (motion) / time-rotate handles 'both'
      final curId = st.cameras[st.idx];
      if (movers.contains(curId)) return; // already on a moving camera
      st.idx = st.cameras.indexOf(movers.first);
      _resolved[slot] = st.cameras[st.idx];
      changed = true;
    });

    // Auto-follow hotspots: point at the most-recently-moved camera in each
    // set, holding a busy camera and dwelling briefly after a switch.
    final now = DateTime.now();
    for (final entry in _specs.entries) {
      final spec = entry.value;
      if (spec is! HotspotSpec || !spec.isAutoFollow) continue;
      final slot = entry.key;
      if (frozenSlot == slot) continue;
      final st = _hotspotAuto.putIfAbsent(slot, () => _HotspotAutoState());
      final movers = spec.cameras.where(recentMotionCameraIds.contains).toList();
      if (movers.isEmpty) continue; // quiet -> hold whatever is showing
      if (st.cam != null && spec.cameras.contains(st.cam) && recentMotionCameraIds.contains(st.cam)) {
        continue; // current camera still moving -> hold it
      }
      var target = movers.first;
      var targetTs = _lastMotionTsMs[target] ?? 0;
      for (final id in movers) {
        final ts = _lastMotionTsMs[id] ?? 0;
        if (ts > targetTs) {
          targetTs = ts;
          target = id;
        }
      }
      if (st.cam == target) continue;
      if (st.lastSwitch != null && now.difference(st.lastSwitch!) < hotspotDwell) continue; // dwell
      st.cam = target;
      st.lastSwitch = now;
      st.pinned = false;
      if (_resolved[slot] != target) {
        _resolved[slot] = target;
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  /// A camera pane elsewhere on the wall was clicked/selected — re-target any
  /// classic hotspot slots to it, and treat it as a manual override (pinned
  /// for one dwell window) for auto-follow hotspots (routeHotspotClick).
  /// `clickedSlot` is the slot that was clicked; no-op if that slot is itself
  /// a hotspot slot (clicking the hotspot tile itself doesn't retarget it).
  void routeHotspotClick(int clickedSlot, String? cameraId) {
    if (cameraId == null) return;
    final clickSlots = <int>[];
    final autoSlots = <int, HotspotSpec>{};
    for (final entry in _specs.entries) {
      final sp = entry.value;
      if (sp is! HotspotSpec) continue;
      if (sp.isAutoFollow) {
        autoSlots[entry.key] = sp;
      } else {
        clickSlots.add(entry.key);
      }
    }
    if (clickSlots.isEmpty && autoSlots.isEmpty) return;
    if (clickSlots.contains(clickedSlot) || autoSlots.containsKey(clickedSlot)) return;

    var changed = false;
    if (clickSlots.isNotEmpty && cameraId != _clickHotspotCam) {
      _clickHotspotCam = cameraId;
      for (final s in clickSlots) {
        _resolved[s] = cameraId;
      }
      changed = true;
    }
    autoSlots.forEach((slot, _) {
      final st = _hotspotAuto.putIfAbsent(slot, () => _HotspotAutoState());
      st.cam = cameraId;
      st.lastSwitch = DateTime.now();
      st.pinned = true;
      if (_resolved[slot] != cameraId) {
        _resolved[slot] = cameraId;
        changed = true;
      }
    });
    if (changed) notifyListeners();
  }

  /// Seed the classic hotspot's shared target from the first plain-camera
  /// slot on the wall, if it hasn't been clicked yet (applySlotItems'
  /// click-hotspot seeding — shows something immediately on a fresh view).
  void seedClickHotspot(String? firstWallCameraId) {
    if (_clickHotspotCam != null || firstWallCameraId == null) return;
    _clickHotspotCam = firstWallCameraId;
    var changed = false;
    for (final entry in _specs.entries) {
      if (entry.value is HotspotSpec && !(entry.value as HotspotSpec).isAutoFollow) {
        _resolved[entry.key] = firstWallCameraId;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    for (final c in _carousels.values) {
      c.stop();
    }
    _carousels.clear();
    super.dispose();
  }
}
