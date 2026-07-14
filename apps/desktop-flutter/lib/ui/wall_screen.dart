// The live wall — the real P1 headline surface. A grid of live camera panes,
// each pulling its own go2rtc restream via media_kit/libmpv. Each tile
// self-manages its stream-URL fetch + player lifecycle so one camera's slow
// load or failure never blocks the others.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:flutter/gestures.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/ptz_panel_store.dart';
import 'package:crumb_desktop/services/audio_follow_controller.dart';
import 'package:crumb_desktop/services/snapshot_registry.dart';
import 'package:crumb_desktop/src/rust/api/host.dart';
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';
import 'package:crumb_desktop/state/stream_prefs.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/live/pane_watchdog.dart';
import 'package:crumb_desktop/ui/live_status/live_status_badges.dart';
import 'package:crumb_desktop/ui/live_status/live_status_controller.dart';
import 'package:crumb_desktop/ui/ptz/ptz_imaging_controls.dart';
import 'package:crumb_desktop/ui/ptz/ptz_panel_controller.dart';
import 'package:crumb_desktop/ui/ptz/ptz_panel_editor_bar.dart';
import 'package:crumb_desktop/ui/ptz/ptz_panel_overlay.dart';
import 'package:crumb_desktop/ui/ptz/ptz_presets_panel.dart';
import 'package:crumb_desktop/ui/saved_views/saved_views_screen.dart'
    show AppliedView;
import 'package:crumb_desktop/ui/special_tiles/special_tile_controller.dart';
import 'package:crumb_desktop/ui/special_tiles/special_tile_spec.dart';
import 'package:crumb_desktop/ui/special_tiles/special_tile_widgets.dart';

class WallScreen extends StatefulWidget {
  const WallScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.onLogout,
    this.clientOptions,
    this.streamPrefs,
    this.view,
    this.audio,
    this.hotkeys,
    this.shortcuts,
    this.onMaximizedCameraChanged,
    this.statsSink,
    this.onConfigChanged,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;
  final VoidCallback onLogout;

  /// Play-on-focus audio controller (single audible pane). Tiles register
  /// their Player; selection/maximize pick the active pane.
  final AudioFollowController? audio;

  /// Hotkey config — number keys maximize the assigned camera on the wall.
  final HotkeyConfigStore? hotkeys;

  /// Remapped action-shortcut bindings (Keyboard Shortcuts settings) for the
  /// wall's key listener. Null → the hardcoded defaults.
  final KeyboardShortcutsStore? shortcuts;

  /// Per-camera stream (main/sub) + PTZ-disable prefs. Drives the right-click
  /// menu on a tile and which stream each pane plays.
  final StreamPrefsStore? streamPrefs;

  /// The applied saved view (its custom layout + slot→camera map). Null → the
  /// default auto-grid of every enabled camera (the "All Cameras" wall).
  final AppliedView? view;

  /// Reports which camera is currently maximized (full-pane) on the wall, or
  /// null when restored — so the host can carry that maximize into Playback.
  final ValueChanged<String?>? onMaximizedCameraChanged;

  /// Sink for the perf/debug line (camera count + CPU/GPU/NVDEC/RSS). The host
  /// renders it in the bottom status bar on the Live tab instead of a floating
  /// overlay on the wall. Updated on each ~2s stats poll.
  final ValueNotifier<String?>? statsSink;

  /// Called (debounced) when the server's `/status.config_version` changes —
  /// the host re-fetches the camera list so an admin/config edit (camera added,
  /// removed, renamed, re-streamed) reflects on the wall without a restart
  /// (#146). Null → config changes are detected but nothing is reloaded.
  final Future<void> Function()? onConfigChanged;

  /// Client options store. The wall LISTENS to it, so a preference change made
  /// while the wall is visible — e.g. toggling "Show tile info bar" in the
  /// floating Settings panel — is reflected live on the wall behind the panel.
  /// The relevant option here is `showInfoBar` (per-tile header strip vs
  /// floating overlays). Null → defaults (header bar on).
  final ClientOptionsStore? clientOptions;

  @override
  State<WallScreen> createState() => _WallScreenState();
}

class _WallScreenState extends State<WallScreen> {
  Timer? _statsTimer;
  double? _lastCpuTime;
  DateTime? _lastSample;

  Camera? _maximized;

  late final LiveStatusController _liveStatus;

  /// Runtime engine for the two VIDEO special tiles (carousel/hotspot) — it
  /// resolves each to a live camera id the normal tile widget renders. The
  /// DOM-only special tiles (clock/text/image/web/events) render standalone via
  /// [specialTileWidget] and don't go through this controller.
  late final SpecialTileController _special;

  /// Parsed special-tile specs for the applied view, by slot index. Cells not
  /// in here are plain cameras (or empty).
  Map<int, SpecialTileSpec> _specsBySlot = const {};

  /// Stable per-camera GlobalKeys for the wall tiles. Keying a plain camera
  /// tile by CAMERA (not by view+slot) lets Flutter move the tile's element —
  /// and the live, already-decoding Player inside it — to its new position
  /// when the wall relayouts (view switch, default grid ↔ view), instead of
  /// tearing every pane down and making each fresh mpv player wait ~a GOP
  /// (1–2 s of black) for its first keyframe from the go2rtc restream.
  final Map<String, GlobalKey<_WallTileState>> _tileKeys = {};

  GlobalKey<_WallTileState> _tileKeyFor(String cameraId) =>
      _tileKeys.putIfAbsent(cameraId, () => GlobalKey<_WallTileState>());

  /// The maximized pane's warm-start surface: the wall tile's live controller,
  /// captured at maximize time. The tile stays mounted (and decoding) under
  /// the maximized overlay, so the pane can paint this at full size while its
  /// own main-stream player waits for a keyframe — no black flash.
  VideoController? _maximizeWarmCtrl;

  /// Custom per-camera PTZ control panels (the drag-laid-out button clusters
  /// ported from the old client's `ptzPanels`). One store + one controller
  /// shared by every maximized pane: the store serializes writes to the single
  /// shared_preferences key, and the controller carries edit state across the
  /// tile right-click menu ("Edit PTZ panel…") → maximized-pane handoff.
  final PtzPanelStore _ptzPanelStore = PtzPanelStore();
  late final PtzPanelController _ptzPanel = PtzPanelController(
    api: widget.api,
    session: widget.session,
    store: _ptzPanelStore,
  );

  List<Camera> get _shown =>
      widget.cameras.where((c) => c.enabled).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _statsTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollStats(),
    );
    _liveStatus = LiveStatusController(api: widget.api, session: widget.session)
      ..cameraIds = _shown.map((c) => c.id).toList()
      // A config_version bump means cameras/streams may have changed — ask the
      // host to re-fetch the camera list so the wall picks it up live (#146).
      ..onConfigChanged = _onConfigChanged
      ..start();
    _special = SpecialTileController(
      allCameraIds: () => _shown.map((c) => c.id).toList(),
    )..addListener(_onSpecialChanged);
    // Feed carousel/hotspot resolution from the live-status motion signal.
    _liveStatus.addListener(_onLiveStatusTick);
    _applyViewSpecs();
  }

  @override
  void didUpdateWidget(WallScreen old) {
    super.didUpdateWidget(old);
    // Fresh session after an in-place re-auth — keep PTZ panel calls authed,
    // and hand the new token to the long-lived /status + /events poller so it
    // doesn't keep hitting the server with the dead token (which shows a false
    // "connection lost" banner and stale/empty badges).
    if (old.session.token != widget.session.token ||
        old.session.base != widget.session.base) {
      _ptzPanel.updateSession(widget.session);
      _liveStatus.updateSession(widget.session);
    }
    // A different applied view (or none) → re-parse its special-tile specs.
    if (!identical(old.view, widget.view) || old.view?.id != widget.view?.id) {
      // The new view may drop the maximized camera's tile — whose player the
      // maximized pane could still be painting as its warm-start surface —
      // so release the handoff before that tile is unmounted this frame.
      _maximizeWarmCtrl = null;
      _applyViewSpecs();
    }
    // The camera set changed (e.g. a config-driven refresh added/removed one) —
    // keep the /status + /events poller's camera list in step so new cameras
    // get badges and dropped ones stop being polled.
    final oldIds = old.cameras.map((c) => c.id).toList();
    final newIds = widget.cameras.map((c) => c.id).toList();
    var idsChanged = oldIds.length != newIds.length;
    for (var i = 0; !idsChanged && i < oldIds.length; i++) {
      if (oldIds[i] != newIds[i]) idsChanged = true;
    }
    if (idsChanged) {
      _liveStatus.cameraIds = _shown.map((c) => c.id).toList();
    }
  }

  /// The wall's config-change signal: re-fetch the camera list via the host.
  /// Fire-and-forget — the host owns the list and rebuilds us with it.
  void _onConfigChanged() {
    final refresh = widget.onConfigChanged;
    if (refresh != null) unawaited(refresh());
  }

  void _onSpecialChanged() {
    if (mounted) setState(() {});
  }

  void _onLiveStatusTick() {
    _special.onMotionTick(
      recentMotionCameraIds: _liveStatus.byCameraId.values
          .where((c) => c.recentMotion)
          .map((c) => c.id)
          .toSet(),
    );
  }

  /// Parse the applied view's raw slots into special-tile specs and hand them
  /// to the controller (starts/stops carousel timers, seeds hotspots).
  void _applyViewSpecs() {
    final view = widget.view;
    final specs = <int, SpecialTileSpec>{};
    if (view != null) {
      view.rawSlots.forEach((idxStr, raw) {
        final idx = int.tryParse(idxStr);
        if (idx == null || raw is! Map) return;
        final spec = SpecialTileSpec.fromRaw(Map<String, dynamic>.from(raw));
        if (spec != null) specs[idx] = spec;
      });
    }
    _specsBySlot = specs;
    _special.applySpecs(specs);
    // Seed the classic (click) hotspot from the view's first camera slot.
    if (view != null) {
      String? firstCam;
      for (var i = 0; i < view.layout.cells.length; i++) {
        final c = view.slots[i];
        if (c != null) {
          firstCam = c;
          break;
        }
      }
      _special.seedClickHotspot(firstCam);
    }
  }

  Future<void> _pollStats() async {
    final s = await hostStats();
    if (!mounted) return;
    final now = DateTime.now();
    double? cpuPct;
    if (_lastCpuTime != null && _lastSample != null) {
      final dt = now.difference(_lastSample!).inMilliseconds / 1000.0;
      if (dt > 0) {
        cpuPct = ((s.cpuTimeSecs - _lastCpuTime!) / dt) / s.numCpus * 100.0;
      }
    }
    _lastCpuTime = s.cpuTimeSecs;
    _lastSample = now;
    // Perf/debug line for the bottom status bar (no wall rebuild needed).
    widget.statsSink?.value =
        '${_shown.length} cameras     '
        'CPU ${cpuPct?.toStringAsFixed(0) ?? "—"}%   '
        'GPU ${s.gpuUtil?.toStringAsFixed(0) ?? "—"}%   '
        'NVDEC ${s.gpuDecUtil?.toStringAsFixed(0) ?? "—"}%   '
        'RSS ${s.memMb.toStringAsFixed(0)}MB';
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _liveStatus.removeListener(_onLiveStatusTick);
    _special.dispose();
    _liveStatus.dispose();
    // Persist any in-flight panel edit straight to the store — the async
    // endEdit() would notifyListeners on the controller after dispose().
    // (Every discrete edit already persisted itself; this only covers a
    // mid-drag move.)
    final editCam = _ptzPanel.editMode ? _ptzPanel.editCameraId : null;
    if (editCam != null) {
      unawaited(
        _ptzPanelStore.save(
          editCam,
          _ptzPanelStore.panelForEditSync(editCam) ?? const [],
        ),
      );
    }
    _ptzPanel.dispose();
    super.dispose();
  }

  /// Maximize a camera + make it the audio-active pane.
  void _maximize(Camera cam) {
    // Maximizing a different camera mid panel-edit ends (and persists) the
    // edit — the editor chrome must not follow the wrong camera.
    if (_ptzPanel.editMode && _ptzPanel.editCameraId != cam.id) {
      unawaited(_ptzPanel.endEdit());
    }
    // Load the camera's saved custom PTZ panel (if any) so the maximized
    // pane can render it in view mode.
    if (cam.ptz) unawaited(_ptzPanel.loadForView(cam.id));
    widget.audio?.setMaximized('max:${cam.id}');
    widget.onMaximizedCameraChanged?.call(cam.id);
    setState(() {
      // Hand the tile's already-decoding controller to the maximized pane so
      // it shows live video (upscaled sub stream) instead of black while its
      // own main-stream player waits ~a GOP for its first keyframe.
      _maximizeWarmCtrl = _tileKeys[cam.id]?.currentState?.warmController;
      _maximized = cam;
    });
  }

  /// Restore from the maximized pane back to the grid.
  void _restore() {
    // Leaving the maximized view mid panel-edit ends (and persists) the edit.
    if (_ptzPanel.editMode) unawaited(_ptzPanel.endEdit());
    widget.audio?.setMaximized(null);
    widget.onMaximizedCameraChanged?.call(null);
    setState(() {
      _maximizeWarmCtrl = null;
      _maximized = null;
    });
  }

  /// "Edit PTZ panel…" from a tile's right-click menu: maximize the camera
  /// (the panel is composed over the full-pane video, WYSIWYG) and enter the
  /// panel editor.
  void _editPtzPanel(Camera cam) {
    if (_maximized?.id != cam.id) _maximize(cam);
    unawaited(_ptzPanel.beginEdit(cam.id));
  }

  @override
  Widget build(BuildContext context) {
    final cams = _shown;
    final cols = cams.isEmpty ? 1 : math.sqrt(cams.length).ceil();
    final scaffold = Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            // Listen to client options so toggling "Show tile info bar" in the
            // floating Settings panel restyles the tiles live (tile States
            // persist by key, so no player teardown/restart).
            child: widget.clientOptions == null
                ? _wallBody(cams, cols, true)
                : ListenableBuilder(
                    listenable: widget.clientOptions!,
                    builder: (context, _) =>
                        _wallBody(cams, cols, widget.clientOptions!.showInfoBar),
                  ),
          ),

          // (Sign-out lives in the top bar — no redundant floating button here.
          // The perf/debug stats that used to sit top-left now live in the
          // bottom status bar via statsSink.)

          // Connection-lost banner: status polling has failed 3x in a row, so
          // the REC/motion/detection badges below may be stale. Positioned is
          // the DIRECT Stack child; the ListenableBuilder that rebuilds the
          // banner on poll ticks sits INSIDE it (a Positioned must never be
          // nested under a non-Stack parent, or the whole Stack fails to build).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ListenableBuilder(
              listenable: _liveStatus,
              builder: (context, _) =>
                  ConnLostBanner(show: _liveStatus.connectionLost),
            ),
          ),

          // Maximized single-camera view (main stream + zoom/pan), on top.
          if (_maximized != null)
            _MaximizedPane(
              key: ValueKey('max-${_maximized!.id}'),
              api: widget.api,
              session: widget.session,
              camera: _maximized!,
              liveStatus: _liveStatus,
              streamPrefs: widget.streamPrefs,
              audio: widget.audio,
              warmController: _maximizeWarmCtrl,
              ptzPanel: _ptzPanel,
              ptzClickMode:
                  widget.clientOptions?.ptzClickMode ?? PtzClickMode.center,
              ptzStyle: widget.clientOptions?.ptzStyle ?? PtzStyle.edges,
              ptzWheelCorner:
                  widget.clientOptions?.ptzWheelCorner ??
                  PtzWheelCorner.bottomLeft,
              onClose: _restore,
            ),
        ],
      ),
    );

    // Number-key hotkeys maximize the assigned camera; Esc restores; M toggles
    // audio. (S snapshot is handled by the app-level SnapshotHotkey.)
    final hk = widget.hotkeys;
    if (hk == null) return scaffold;
    return GlobalHotkeysListener(
      store: hk,
      cameras: cams,
      autofocus: true,
      shortcuts: widget.shortcuts,
      options: widget.clientOptions,
      onGoToCamera: (id) {
        for (final c in cams) {
          if (c.id == id) {
            _maximize(c);
            break;
          }
        }
      },
      // Esc leaves panel-edit mode first (persisting the layout); the next
      // Esc restores the wall — same layered-Esc model as fullscreen.
      onEscape: _maximized == null
          ? null
          : () {
              if (_ptzPanel.editMode) {
                unawaited(_ptzPanel.endEdit());
              } else {
                _restore();
              }
            },
      onToggleAudio: widget.audio == null
          ? null
          : () => widget.audio!.toggleAudio(),
      child: scaffold,
    );
  }

  /// Pick what fills the wall: an applied view's custom layout, the empty-state
  /// message, or the default auto-grid of every enabled camera.
  Widget _wallBody(List<Camera> cams, int cols, bool showInfoBar) {
    final view = widget.view;
    if (view != null) return _viewGrid(view, showInfoBar);
    if (cams.isEmpty) {
      return const Center(
        child: Text(
          'No enabled cameras visible to this account.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return _grid(cams, cols, showInfoBar);
  }

  /// Render an applied saved view: place one tile per layout cell (in reading
  /// order = slot index) at its fractional rect, mapping the slot to its camera
  /// (empty slots show a placeholder). Custom geometry fills the pane exactly
  /// like the old client's CSS-grid `gridColumn/gridRow` spans.
  Widget _viewGrid(AppliedView view, bool showInfoBar) {
    final layout = view.layout;
    final camById = {for (final c in widget.cameras) c.id: c};
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        const g = 1.0; // half-gap between tiles
        final children = <Widget>[];
        // Camera ids that already claimed their per-camera GlobalKey this
        // build — a GlobalKey may appear at most once per frame, so a second
        // slot showing the same camera falls back to a slot-scoped key.
        final usedCamKeys = <String>{};
        for (var i = 0; i < layout.cells.length; i++) {
          final cell = layout.cells[i];
          final left = cell.x / layout.cols * w;
          final top = cell.y / layout.rows * h;
          final width = cell.w / layout.cols * w;
          final height = cell.h / layout.rows * h;
          final spec = _specsBySlot[i];
          Widget child;
          if (spec != null && !spec.isVideoTile) {
            // DOM-only special tile (clock/text/image/web/events): render
            // standalone, no camera pane underneath.
            child = KeyedSubtree(
              key: ValueKey('${view.id}:$i:${spec.kind.wireType}'),
              child: ColoredBox(
                color: Colors.black,
                child: specialTileWidget(
                  spec,
                  api: widget.api,
                  session: widget.session,
                  cameras: widget.cameras,
                ),
              ),
            );
          } else {
            // Plain camera slot, or a carousel/hotspot resolved to a camera.
            final camId = (spec != null && spec.isVideoTile)
                ? _special.resolvedCamera(i)
                : view.slots[i];
            final cam = camId == null ? null : camById[camId];
            // Plain camera slots key by camera (per-camera GlobalKey) so a
            // camera shared between the outgoing and incoming view keeps its
            // decoding player across the switch. Carousel/hotspot slots keep
            // the old slot-scoped key — their camera changes over time, and
            // stealing a static slot's key would just move the teardown.
            final Key? tileKey = cam == null
                ? null
                : (spec == null && usedCamKeys.add(cam.id))
                ? _tileKeyFor(cam.id)
                : ValueKey('${view.id}:$i:${cam.id}');
            child = cam == null
                ? const _EmptySlot()
                : _WallTile(
                    key: tileKey,
                    api: widget.api,
                    session: widget.session,
                    camera: cam,
                    liveStatus: _liveStatus,
                    streamPrefs: widget.streamPrefs,
                    audio: widget.audio,
                    showInfoBar: showInfoBar,
                    zoomToMain: widget.clientOptions?.zoomSwitchesToMain ?? false,
                    // Custom cells can be any aspect — letterbox, don't crop.
                    fit: BoxFit.contain,
                    onTap: () {
                      // Clicking a camera retargets classic (click) hotspots.
                      _special.routeHotspotClick(i, cam.id);
                      _maximize(cam);
                    },
                    onEditPtzPanel: () => _editPtzPanel(cam),
                  );
          }
          children.add(
            Positioned(
              left: left + g,
              top: top + g,
              width: (width - 2 * g).clamp(0.0, w),
              height: (height - 2 * g).clamp(0.0, h),
              child: child,
            ),
          );
        }
        return Stack(children: children);
      },
    );
  }

  /// The default auto-grid of every enabled camera. Pulled out of [build] so it
  /// can be rebuilt on a client-option change (via the ListenableBuilder above)
  /// without disturbing the rest of the wall. `showInfoBar` chooses the per-tile
  /// header strip vs the floating name/badge overlays.
  ///
  /// Fills the whole pane with fractional [Positioned] cells (like [_viewGrid]
  /// and the old client's CSS grid) rather than [GridView.count], whose forced
  /// `childAspectRatio` left dead space at the bottom whenever the grid's aspect
  /// didn't match the pane. Video is letterboxed (contain) inside each cell, so
  /// no footage is cropped.
  Widget _grid(List<Camera> cams, int cols, bool showInfoBar) {
    final rows = cols <= 0 ? 1 : (cams.length / cols).ceil().clamp(1, cams.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        const g = 1.0; // half-gap between tiles (matches _viewGrid)
        final cellW = w / cols;
        final cellH = h / rows;
        final children = <Widget>[];
        for (var i = 0; i < cams.length; i++) {
          final cam = cams[i];
          final col = i % cols;
          final row = i ~/ cols;
          children.add(
            Positioned(
              left: col * cellW + g,
              top: row * cellH + g,
              width: (cellW - 2 * g).clamp(0.0, w),
              height: (cellH - 2 * g).clamp(0.0, h),
              child: _WallTile(
                // Per-camera GlobalKey: the tile (and its already-decoding
                // player) survives a switch between this default grid and a
                // saved view, instead of tearing down and re-waiting a keyframe.
                key: _tileKeyFor(cam.id),
                api: widget.api,
                session: widget.session,
                camera: cam,
                liveStatus: _liveStatus,
                streamPrefs: widget.streamPrefs,
                audio: widget.audio,
                showInfoBar: showInfoBar,
                zoomToMain: widget.clientOptions?.zoomSwitchesToMain ?? false,
                // Cells rarely land on 16:9 once they fill the pane — letterbox
                // rather than crop, matching _viewGrid and the old client.
                fit: BoxFit.contain,
                onTap: () => _maximize(cam),
                onEditPtzPanel: () => _editPtzPanel(cam),
              ),
            ),
          );
        }
        return Stack(children: children);
      },
    );
  }
}

/// Placeholder for a view slot with no camera assigned.
class _EmptySlot extends StatelessWidget {
  const _EmptySlot();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade900,
      child: const Center(
        child: Icon(Icons.videocam_off_outlined, color: Colors.white24, size: 26),
      ),
    );
  }
}

/// One live camera pane: fetches its own stream URL then plays it. Independent
/// load/error state so a slow or dead camera doesn't stall the wall.
class _WallTile extends StatefulWidget {
  const _WallTile({
    super.key,
    required this.api,
    required this.session,
    required this.camera,
    required this.liveStatus,
    required this.showInfoBar,
    required this.onTap,
    this.streamPrefs,
    this.audio,
    this.fit = BoxFit.cover,
    this.zoomToMain = false,
    this.onEditPtzPanel,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final LiveStatusController liveStatus;
  final bool showInfoBar;
  final VoidCallback onTap;
  final StreamPrefsStore? streamPrefs;
  final AudioFollowController? audio;

  /// "Edit PTZ panel…" from the right-click menu (PTZ cameras only): the wall
  /// maximizes this camera and opens the custom-panel editor over it.
  final VoidCallback? onEditPtzPanel;

  /// When true, digitally zooming this tile past 100% temporarily loads its
  /// main stream (reverting to sub at 100%). From the "Zoom switches to main
  /// stream" client option.
  final bool zoomToMain;

  /// How the video fills its tile. The default auto-grid uses `cover` (tiles
  /// are ~16:9, so no visible crop); custom-view cells can be any aspect, so
  /// they use `contain` to letterbox (black bars) instead of cropping tight.
  final BoxFit fit;

  @override
  State<_WallTile> createState() => _WallTileState();
}

class _WallTileState extends State<_WallTile> {
  Player? _player;
  VideoController? _controller;

  /// A replacement player mid stream-swap (main/sub change): it decodes in
  /// the background while the old player keeps rendering, and [_onFirstFrame]
  /// promotes it once it has a real frame — so a stream switch never blanks
  /// the pane while the fresh player waits ~a GOP for its first keyframe.
  Player? _pending;

  String? _error;
  bool _firstFrame = false;

  /// Per-pane stall watchdog: polls the ACTIVE player's frame/position
  /// progress and, on a confirmed freeze (camera reboot, go2rtc restart, PoE
  /// blip), reconnects the pane in place with exponential backoff + a
  /// fleet-wide herd cap. Without it a wedged feed froze on its last frame
  /// forever while still reading "LIVE" (P0-6). Recreated in [_adopt] so it
  /// always tracks the current `_player` across a main/sub stream swap.
  PaneWatchdog? _watchdog;

  /// True while [_watchdog] is actively retrying a stalled feed — drives the
  /// amber live-dot treatment so a frozen pane never reads as live.
  bool _reconnecting = false;

  /// The tile's live controller, offered to the maximized pane as a warm-start
  /// surface. Null until a frame has decoded, and null while a stream swap is
  /// pending — the pending swap will dispose the current player, which must
  /// never happen while the maximized pane is still painting it.
  VideoController? get warmController =>
      _firstFrame && _pending == null ? _controller : null;

  // Per-tile digital zoom: hovering the tile + mouse wheel zooms IN PLACE
  // (the wall stays up); drag pans when zoomed. Double-click still maximizes.
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  static const double _maxZoom = 8.0;

  /// True while a zoom-in has temporarily switched this tile to the main
  /// stream (see [WallScreen.onMaximizedCameraChanged]/zoomSwitchesToMain).
  bool _zoomedToMain = false;

  void _zoomAt(Offset cursor, double factor, Size pane) {
    final newScale = (_scale * factor).clamp(1.0, _maxZoom);
    if (newScale == _scale) return;
    final newOffset = cursor - (cursor - _offset) * (newScale / _scale);
    setState(() {
      _scale = newScale;
      _offset = _clampOffset(newOffset, pane);
    });
    // Optionally swap to the full-res main stream while zoomed in, reverting to
    // sub back at 100% (the zoom transform persists across the reload).
    final wantMain = widget.zoomToMain && newScale > 1.01;
    if (wantMain != _zoomedToMain) {
      _zoomedToMain = wantMain;
      unawaited(_reloadStream());
    }
  }

  Offset _clampOffset(Offset o, Size pane) {
    final minX = pane.width * (1 - _scale);
    final minY = pane.height * (1 - _scale);
    return Offset(
      o.dx.clamp(minX <= 0 ? minX : 0.0, 0.0),
      o.dy.clamp(minY <= 0 ? minY : 0.0, 0.0),
    );
  }

  void _panBy(Offset delta, Size pane) {
    if (_scale <= 1.0) return;
    setState(() => _offset = _clampOffset(_offset + delta, pane));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Track a Player created below so the catch can dispose it if open() throws
    // before the pane adopts it — otherwise a failed initial load leaks the
    // player and its native mpv handle (#132). Cleared once ownership passes to
    // the pane (_adopt) or the pending swap slot.
    Player? spawned;
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      // Per-camera main/sub override (right-click menu) wins over the wall
      // default; falls back to the plain wall preference if no prefs store.
      final url =
          widget.streamPrefs?.liveStreamUrl(
            widget.camera.id,
            streams,
            // Zoomed-in tiles temporarily play main (full-res); otherwise sub.
            isMaximized: _zoomedToMain,
          ) ??
          streams.preferredForWall;
      if (url == null) {
        setState(() => _error = 'no stream');
        return;
      }
      final player = Player();
      final controller = VideoController(player);
      spawned = player;
      final p = player.platform;
      if (p is NativePlayer) {
        for (final kv in const [
          ['rtsp-transport', 'tcp'],
          ['hwdec', 'auto'],
          ['cache', 'yes'],
          ['demuxer-readahead-secs', '2.0'],
          ['demuxer-max-bytes', '32MiB'],
          ['demuxer-max-back-bytes', '1MiB'],
          ['network-timeout', '10'],
          ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
          // Never emit decoder output from before the first keyframe — masks
          // the grey/blocky "difference map" partial frames a mid-GOP RTSP
          // join can otherwise flash before the first clean frame.
          ['vd-lavc-show-all', 'no'],
          ['mute', 'yes'],
        ]) {
          try {
            await p.setProperty(kv[0], kv[1]);
          } catch (_) {
            /* non-fatal */
          }
        }
      }
      player.stream.width.listen((w) {
        if (w != null && w > 0 && mounted) {
          _onFirstFrame(player, controller);
        }
      });
      await player.open(Media(url));
      if (!mounted) {
        player.dispose();
        return;
      }
      if (_player == null) {
        _adopt(player, controller);
      } else {
        // A stream swap: keep the old player rendering while this one decodes
        // toward its first keyframe; _onFirstFrame does the visible swap.
        _pending?.dispose(); // superseded by an even newer swap
        _pending = player;
      }
      spawned = null; // ownership handed off — the catch must not dispose it
    } catch (_) {
      // A Player created before open() failed is orphaned; dispose it so its
      // native mpv handle isn't leaked on a failed initial load (#132). On the
      // success path spawned is nulled above once the pane adopts the player
      // (or hands it to _pending), so the stall-watchdog/reconnect handling is
      // untouched and a live player is never disposed here.
      spawned?.dispose();
      if (mounted) {
        setState(() => _error = 'load failed');
      }
    }
  }

  /// Wire [player] into this pane: register it as the snapshot/audio target
  /// (re-registering the same pane id overwrites the retired player) and make
  /// its controller the one the tile renders.
  void _adopt(Player player, VideoController controller) {
    // Register this pane so the snapshot hotkey/button can grab its frame.
    // The first pane to come up becomes the default capture target.
    SnapshotRegistry.instance.register(
      _paneId,
      SnapshotTarget(player: player, cameraName: widget.camera.name),
    );
    // Register as an audio pane (muted until it becomes the audible pane).
    widget.audio?.registerPane(
      _paneId,
      AudioPane.forPlayer(player, hasAudio: () => mounted),
    );
    if (SnapshotRegistry.instance.activePaneId.value == null) {
      SnapshotRegistry.instance.setActive(_paneId);
      // Mirror the default selection into audio-follow too, so the global
      // audio button has a target from the start — without this, the tile
      // looks selected but the audio toggle reports "select a camera".
      widget.audio?.setSelected(_paneId);
    }
    // (Re)point the stall watchdog at the player we just made active. A
    // main/sub swap adopts a fresh player and disposes the old one, so the
    // watchdog must be rebuilt on the new player rather than left polling a
    // disposed handle. The global herd budget (shared across every pane)
    // survives this teardown, so fleet-wide storm protection is preserved.
    _watchdog?.dispose();
    _watchdog =
        PaneWatchdog(
          player: player,
          reconnect: _reconnectStalled,
          onReconnectingChanged: (on) {
            if (mounted) setState(() => _reconnecting = on);
          },
        )..start();
    setState(() {
      _player = player;
      _controller = controller;
      _error = null;
    });
  }

  /// Watchdog reconnect for a confirmed-stalled pane: refetch the stream URL
  /// (go2rtc's restream address can change across a Crumb reconcile) and
  /// re-open the CURRENT player in place — same as the Tauri client's
  /// `reload_pane` (loadfile into the existing pane). Deliberately distinct
  /// from [_reloadStream], which spins up a second player to avoid a black
  /// flash on a user-initiated main/sub swap; here the pane is already frozen,
  /// so an in-place re-open keeps the watchdog's final `player` handle valid.
  Future<void> _reconnectStalled() async {
    final player = _player;
    if (player == null) return;
    // A user stream-swap is mid-flight (old player still rendering while the
    // replacement decodes) — let that resolve rather than re-opening the
    // outgoing player underneath it; the watchdog retries on its next tick.
    if (_pending != null) return;
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      final url =
          widget.streamPrefs?.liveStreamUrl(
            widget.camera.id,
            streams,
            isMaximized: _zoomedToMain,
          ) ??
          streams.preferredForWall;
      if (url == null) return;
      // Reset the live indicator so a stale/reconnecting pane never reads as
      // live; the width listener flips it back on the first decoded frame.
      if (mounted) setState(() => _firstFrame = false);
      await player.open(Media(url));
      _watchdog?.resetBaseline();
    } catch (_) {
      // Left for the next backoff tick — the watchdog never gives up.
    }
  }

  /// First decoded frame from [player]. For the pane's active player this
  /// just flips the live dot; for a pending stream swap it is the moment the
  /// swap becomes invisible — promote the replacement and retire the old
  /// player, so the pane never blanks while the new stream waits for a
  /// keyframe.
  void _onFirstFrame(Player player, VideoController controller) {
    if (identical(player, _player)) {
      if (!_firstFrame) setState(() => _firstFrame = true);
      return;
    }
    if (!identical(player, _pending)) return; // superseded swap — ignore
    final old = _player;
    _pending = null;
    _firstFrame = true;
    _adopt(player, controller);
    old?.dispose();
  }

  String get _paneId => 'wall:${widget.camera.id}';

  /// Swap to the currently-preferred stream (after a main/sub override change
  /// from the right-click menu, or a zoom-to-main toggle). Re-fetches the URLs
  /// so a server-side change is picked up too. The old player keeps rendering
  /// until the replacement decodes its first frame (see [_onFirstFrame]) —
  /// blanking the pane for that wait was the 1–2 s black flash.
  Future<void> _reloadStream() => _load();

  /// Right-click menu: per-camera PTZ-controls toggle + stream main/sub
  /// override (overriding the global "wall uses sub" setting).
  Future<void> _showTileMenu(Offset globalPos) async {
    final prefs = widget.streamPrefs;
    SnapshotRegistry.instance.setActive(_paneId); // select on right-click
    widget.audio?.setSelected(_paneId); // keep audio-follow in step
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final eff = prefs?.effectiveFor(widget.camera.id);
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.camera.ptz && prefs != null) ...[
          PopupMenuItem(
            value: 'ptz',
            child: Text(
              prefs.ptzDisabledFor(widget.camera.id)
                  ? 'Enable PTZ controls'
                  : 'Disable PTZ controls',
            ),
          ),
          // Custom panel builder — pointless while PTZ controls are disabled
          // (the maximized pane hides the panel behind the same gate).
          if (widget.onEditPtzPanel != null &&
              !prefs.ptzDisabledFor(widget.camera.id))
            const PopupMenuItem(
              value: 'ptz-panel',
              child: Text('Edit PTZ panel…'),
            ),
          const PopupMenuDivider(),
        ],
        CheckedPopupMenuItem(
          value: 'main',
          checked: eff == StreamQuality.main,
          child: const Text('Main stream'),
        ),
        CheckedPopupMenuItem(
          value: 'sub',
          checked: eff == StreamQuality.sub,
          child: const Text('Sub stream'),
        ),
        if (prefs?.hasOverride(widget.camera.id) ?? false)
          const PopupMenuItem(
            value: 'reset',
            child: Text('Reset to wall default'),
          ),
      ],
    );
    if (result == null || !mounted) return;
    switch (result) {
      case 'ptz':
        prefs?.setPtzDisabled(
          widget.camera.id,
          !prefs.ptzDisabledFor(widget.camera.id),
        );
        setState(() {}); // no reload needed — only affects maximized PTZ UI
      case 'ptz-panel':
        widget.onEditPtzPanel?.call();
      case 'main':
        prefs?.setOverride(widget.camera.id, StreamQuality.main);
        await _reloadStream();
      case 'sub':
        prefs?.setOverride(widget.camera.id, StreamQuality.sub);
        await _reloadStream();
      case 'reset':
        prefs?.setOverride(widget.camera.id, null);
        await _reloadStream();
    }
  }

  @override
  void dispose() {
    _watchdog?.dispose();
    SnapshotRegistry.instance.unregister(_paneId);
    widget.audio?.unregisterPane(_paneId);
    _pending?.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Header-bar mode: a title strip on top, video inset below it (the video is
    // not covered by any floating overlay). Otherwise: video fills the tile with
    // floating badge row + name label composited over it.
    final content = Container(
      color: Colors.grey.shade900,
      child: widget.showInfoBar
          ? Column(
              children: [_infoBar(), Expanded(child: _videoArea())],
            )
          : _videoArea(),
    );
    // Selected (single-tapped / snapshot-target) tile gets an outline in the
    // app-wide accent (the active tab's colour).
    return ValueListenableBuilder<String?>(
      valueListenable: SnapshotRegistry.instance.activePaneId,
      builder: (context, activeId, _) {
        final selected = activeId == _paneId;
        return Stack(
          fit: StackFit.expand,
          children: [
            content,
            if (selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The per-tile title strip (header-bar mode). Listens to the shared
  /// LiveStatusController so only the strip rebuilds on a poll tick.
  Widget _infoBar() {
    return ListenableBuilder(
      listenable: widget.liveStatus,
      builder: (context, _) {
        final status = widget.liveStatus.cameraFor(widget.camera.id);
        return TileInfoBar(
          name: widget.camera.name,
          connected: _firstFrame && _error == null,
          hasError: _error != null,
          recording: status?.recording ?? false,
          recentMotion: status?.recentMotion ?? false,
          detectionKeys: widget.liveStatus.detectionKeysFor(widget.camera.id),
        );
      },
    );
  }

  /// The interactive video pane: the player texture with digital zoom/pan, and
  /// — only when the header strip is OFF — the floating badge row + name label
  /// composited over the video.
  Widget _videoArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pane = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          // Hover a tile + mouse wheel → digital zoom IN PLACE (wall stays up).
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              final factor = math.pow(1.0013, -e.scrollDelta.dy) as double;
              _zoomAt(e.localPosition, factor, pane);
            }
          },
          child: GestureDetector(
            // Single click selects this pane (snapshot + audio target);
            // double-click maximizes; right-click opens the per-tile menu.
            onTap: () {
              SnapshotRegistry.instance.setActive(_paneId);
              widget.audio?.setSelected(_paneId);
            },
            onDoubleTap: widget.onTap,
            onSecondaryTapDown: (d) => _showTileMenu(d.globalPosition),
            onPanUpdate: (d) => _panBy(d.delta, pane),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_controller != null)
                  ClipRect(
                    child: Transform(
                      transform: Matrix4.identity()
                        ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                        ..scaleByDouble(_scale, _scale, 1, 1),
                      child: Video(
                        controller: _controller!,
                        controls: NoVideoControls,
                        fit: widget.fit,
                      ),
                    ),
                  )
                else
                  Center(
                    child: _error != null
                        ? Icon(
                            Icons.videocam_off,
                            color: Colors.red.shade300,
                            size: 28,
                          )
                        : const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  ),

                // Floating overlays: only when the header strip is OFF (in
                // header-bar mode the name + indicators live in the strip).
                if (!widget.showInfoBar) ...[
                  // REC/motion/detection badges (top-left), driven by the shared
                  // LiveStatusController poll — only this row rebuilds on a tick.
                  Positioned(
                    left: 6,
                    top: 6,
                    child: ListenableBuilder(
                      listenable: widget.liveStatus,
                      builder: (context, _) {
                        final status = widget.liveStatus.cameraFor(
                          widget.camera.id,
                        );
                        return LiveStatusBadgeRow(
                          recording: status?.recording ?? false,
                          recentMotion: status?.recentMotion ?? false,
                          detectionKeys: widget.liveStatus.detectionKeysFor(
                            widget.camera.id,
                          ),
                        );
                      },
                    ),
                  ),

                  // Camera-name label (bottom-left), with a live/offline dot
                  // and a subtle "Reconnecting…" badge while the watchdog is
                  // retrying a stalled feed.
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                        border: _reconnecting
                            ? Border.all(color: Colors.amber.shade400, width: 1)
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _error != null
                                  ? Colors.red
                                  : (_reconnecting || !_firstFrame
                                        ? Colors.amber
                                        : Colors.greenAccent),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            widget.camera.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          if (_reconnecting) ...[
                            const SizedBox(width: 6),
                            const Text(
                              'Reconnecting…',
                              style: TextStyle(
                                color: Colors.amberAccent,
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Maximized single-camera view: plays the MAIN stream (higher res than the wall
/// sub) with Flutter-native digital zoom/pan (wheel = zoom-to-cursor, drag = pan,
/// double-tap = reset) — the same model proven in the P0 spike. Fills the wall.
class _MaximizedPane extends StatefulWidget {
  const _MaximizedPane({
    super.key,
    required this.api,
    required this.session,
    required this.camera,
    required this.liveStatus,
    required this.onClose,
    this.streamPrefs,
    this.audio,
    this.warmController,
    this.ptzPanel,
    this.ptzClickMode = PtzClickMode.center,
    this.ptzStyle = PtzStyle.edges,
    this.ptzWheelCorner = PtzWheelCorner.bottomLeft,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final LiveStatusController liveStatus;
  final VoidCallback onClose;
  final StreamPrefsStore? streamPrefs;
  final AudioFollowController? audio;

  /// The wall tile's live controller for this camera, if it was already
  /// decoding when we maximized. Painted full-pane (sub stream, upscaled) as
  /// a stand-in until this pane's own main-stream player decodes its first
  /// frame — so maximizing never flashes black while mpv waits for a
  /// keyframe. The tile stays mounted (and decoding) under this overlay, so
  /// the controller stays valid for the handoff window.
  final VideoController? warmController;

  /// Custom per-camera PTZ panel controller (shared, owned by the wall).
  /// When this camera has a saved custom panel (or is being edited) the
  /// panel overlay REPLACES the stock edge-arrows/wheel controls; with no
  /// panel the stock controls and click/wheel interaction are untouched —
  /// the old client's `ptzActivePanel` fallback rule.
  final PtzPanelController? ptzPanel;

  /// What a click on a PTZ-capable video does (center / pan / off).
  final PtzClickMode ptzClickMode;

  /// On-video PTZ control affordance: edge-pinned arrows or the corner wheel
  /// box (Options → "PTZ style"), plus which corner the wheel box pins to.
  final PtzStyle ptzStyle;
  final PtzWheelCorner ptzWheelCorner;

  @override
  State<_MaximizedPane> createState() => _MaximizedPaneState();
}

class _MaximizedPaneState extends State<_MaximizedPane> {
  Player? _player;
  VideoController? _controller;
  String? _error;

  /// True once this pane's own (main-stream) player has decoded a frame —
  /// until then the warm-start controller (if any) covers the wait.
  bool _firstFrame = false;

  /// Per-pane stall watchdog for the maximized (main-stream) player: without
  /// it a camera reboot / go2rtc restart / PoE blip froze the full-pane view
  /// on its last frame forever (P0-6). Reconnects in place with backoff.
  PaneWatchdog? _watchdog;

  /// True while the watchdog is retrying a stalled main stream — drives the
  /// "Reconnecting…" caption by the camera name.
  bool _reconnecting = false;

  /// Decoded video dimensions — needed to undo the BoxFit.contain letterbox
  /// when mapping a click on the pane to a point ON THE VIDEO for PTZ.
  int? _videoW;
  int? _videoH;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  static const double _maxZoom = 8.0;

  /// Mirror of the custom-panel controller state for THIS camera: whether a
  /// custom panel is active (saved layout or edit session) and whether it's
  /// in edit mode. Kept as fields updated by a change-comparing listener so
  /// the pane only rebuilds on panel-mode transitions — the controller also
  /// notifies on every drag tick, which only [PtzPanelOverlay] (with its own
  /// AnimatedBuilder) needs to repaint for.
  bool _panelActive = false;
  bool _panelEditing = false;

  void _onPtzPanelChanged() {
    if (!mounted) return;
    final rec = widget.ptzPanel?.activePanelFor(widget.camera.id);
    final active = rec != null;
    final editing = rec?.$2 ?? false;
    if (active != _panelActive || editing != _panelEditing) {
      setState(() {
        _panelActive = active;
        _panelEditing = editing;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    widget.ptzPanel?.addListener(_onPtzPanelChanged);
    final rec = widget.ptzPanel?.activePanelFor(widget.camera.id);
    _panelActive = rec != null;
    _panelEditing = rec?.$2 ?? false;
    _load();
  }

  Future<void> _load() async {
    // Track a Player created below so the catch can dispose it if open() throws
    // before this pane adopts it — a failed initial load otherwise leaks the
    // player and its native mpv handle (#132). Cleared once ownership passes to
    // the pane (`_player`/`_controller`).
    Player? spawned;
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      // Prefer MAIN for the maximized view; fall back to sub.
      final url = streams.rtspMain ?? streams.preferredForWall;
      if (url == null) {
        setState(() => _error = 'no stream');
        return;
      }
      final player = Player();
      final controller = VideoController(player);
      spawned = player;
      final p = player.platform;
      if (p is NativePlayer) {
        for (final kv in const [
          ['rtsp-transport', 'tcp'],
          ['hwdec', 'auto'],
          ['cache', 'yes'],
          ['demuxer-readahead-secs', '2.0'],
          ['demuxer-max-bytes', '32MiB'],
          ['demuxer-max-back-bytes', '1MiB'],
          ['network-timeout', '10'],
          ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
          // Never emit decoder output from before the first keyframe — masks
          // the grey/blocky "difference map" partial frames a mid-GOP RTSP
          // join can otherwise flash before the first clean frame.
          ['vd-lavc-show-all', 'no'],
          // Muted by default — the global audio button unmutes the active pane.
          ['mute', 'yes'],
        ]) {
          try {
            await p.setProperty(kv[0], kv[1]);
          } catch (_) {
            /* non-fatal */
          }
        }
      }
      player.stream.width.listen((w) {
        if (w != null && w > 0) _videoW = w;
        if (w != null && w > 0 && !_firstFrame && mounted) {
          // First decoded frame from the main stream — drop the warm-start
          // stand-in and hand the pane to this player.
          setState(() => _firstFrame = true);
        }
      });
      player.stream.height.listen((h) {
        if (h != null && h > 0) _videoH = h;
      });
      await player.open(Media(url));
      if (!mounted) {
        player.dispose();
        return;
      }
      // While maximized, this pane is the snapshot + audio target.
      SnapshotRegistry.instance.register(
        'maximized',
        SnapshotTarget(player: player, cameraName: widget.camera.name),
      );
      SnapshotRegistry.instance.setActive('maximized');
      widget.audio?.registerPane(
        'max:${widget.camera.id}',
        AudioPane.forPlayer(player, hasAudio: () => mounted),
      );
      _watchdog =
          PaneWatchdog(
            player: player,
            reconnect: _reconnectStalled,
            onReconnectingChanged: (on) {
              if (mounted) setState(() => _reconnecting = on);
            },
          )..start();
      setState(() {
        _player = player;
        _controller = controller;
      });
      spawned = null; // ownership handed off — the catch must not dispose it
    } catch (_) {
      // A Player created before open() failed is orphaned; dispose it so its
      // native mpv handle isn't leaked on a failed initial load (#132). On the
      // success path spawned is nulled above (after _player/_controller adopt
      // it), so a live/reconnecting player is never disposed here.
      spawned?.dispose();
      if (mounted) setState(() => _error = 'load failed');
    }
  }

  /// Watchdog reconnect for a confirmed-stalled maximized pane: refetch the
  /// main stream URL and re-open the current player in place (the pane is
  /// already frozen, so no black-flash concern). The full-pane view keeps its
  /// last frame until the reconnected stream decodes, then resumes seamlessly.
  Future<void> _reconnectStalled() async {
    final player = _player;
    if (player == null) return;
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      final url = streams.rtspMain ?? streams.preferredForWall;
      if (url == null) return;
      await player.open(Media(url));
      _watchdog?.resetBaseline();
    } catch (_) {
      // Left for the next backoff tick — the watchdog never gives up.
    }
  }

  void _zoomAt(Offset cursor, double factor, Size pane) {
    final newScale = (_scale * factor).clamp(1.0, _maxZoom);
    if (newScale == _scale) return;
    final newOffset = cursor - (cursor - _offset) * (newScale / _scale);
    setState(() {
      _scale = newScale;
      _offset = _clampOffset(newOffset, pane);
    });
  }

  Offset _clampOffset(Offset o, Size pane) {
    final minX = pane.width * (1 - _scale);
    final minY = pane.height * (1 - _scale);
    return Offset(
      o.dx.clamp(minX <= 0 ? minX : 0.0, 0.0),
      o.dy.clamp(minY <= 0 ? minY : 0.0, 0.0),
    );
  }

  void _panBy(Offset delta, Size pane) {
    if (_scale <= 1.0) return;
    setState(() => _offset = _clampOffset(_offset + delta, pane));
  }

  /// PTZ usable here: camera supports it AND the operator hasn't disabled PTZ
  /// controls for this camera via the right-click menu.
  bool get _ptzEnabled =>
      widget.camera.ptz &&
      !(widget.streamPrefs?.ptzDisabledFor(widget.camera.id) ?? false);

  // While the custom-panel EDITOR is open, clicks/drags on the video arrange
  // buttons — they must not also steer the camera, so the click-to-center /
  // hold-to-pan interactions pause for the edit session (view mode keeps
  // them: panel buttons are opaque hit targets, empty video falls through).
  bool get _ptzCenter =>
      _ptzEnabled &&
      !_panelEditing &&
      widget.ptzClickMode == PtzClickMode.center;
  bool get _ptzPan =>
      _ptzEnabled && !_panelEditing && widget.ptzClickMode == PtzClickMode.pan;

  // ── PTZ optical zoom via the mouse wheel ────────────────────────────────
  // The wheel is discrete but ONVIF zoom is continuous (move → stop), so each
  // notch starts a zoom in the wheel's direction and a debounced timer sends
  // stop shortly after scrolling settles — smooth optical zoom while spinning.
  Timer? _ptzZoomStop;

  void _ptzWheelZoom(double scrollDy) {
    const v = 0.5;
    final zoom = scrollDy < 0 ? v : -v; // wheel up = zoom in
    // Single motion channel: a pending recenter-pulse stop must not cut this
    // zoom short (and vice versa) — clear BOTH timers, like the old client.
    _ptzPulseStop?.cancel();
    _ptzZoomStop?.cancel();
    widget.api
        .ptzMove(widget.session, widget.camera.id, zoom: zoom)
        .catchError((_) {});
    _ptzZoomStop = Timer(const Duration(milliseconds: 220), () {
      widget.api.ptzStop(widget.session, widget.camera.id).catchError((_) {});
    });
  }

  // ── PTZ click-to-center / click-hold-to-pan (ported from app.js
  //    ptzVideoClick / ptzVideoSteer). Offset from the VIDEO centre, normalised
  //    to [-1,1], drives an ONVIF velocity move.
  Timer? _ptzPulseStop;
  bool _ptzSteering = false;
  ({double nx, double ny})? _ptzLastSteer;

  /// Normalized offset (-1..1 each axis) of a pane-local point from the centre
  /// of the DISPLAYED video. The video sits in the pane via BoxFit.contain, so
  /// when aspect ratios differ the click must be mapped against the letterboxed
  /// video rect, not the pane (same trap the clips zoom hit). Clicks in the
  /// letterbox bars clamp to the nearest video edge.
  ({double nx, double ny}) _normOffset(Offset local, Size pane) {
    double vx = 0, vy = 0, vw = pane.width, vh = pane.height;
    final w = _videoW, h = _videoH;
    if (w != null && h != null && w > 0 && h > 0) {
      final s = math.min(pane.width / w, pane.height / h);
      vw = w * s;
      vh = h * s;
      vx = (pane.width - vw) / 2;
      vy = (pane.height - vh) / 2;
    }
    final nx = ((local.dx - vx) / vw * 2 - 1).clamp(-1.0, 1.0);
    final ny = ((local.dy - vy) / vh * 2 - 1).clamp(-1.0, 1.0);
    return (nx: nx, ny: ny);
  }

  /// Center mode: an open-loop recenter pulse aimed at the clicked point. The
  /// backend only exposes ONVIF ContinuousMove/Stop (no absolute or relative
  /// move, no position read-back), so "make the clicked point the centre" is a
  /// timed velocity pulse: a fixed above-deadband speed pointed straight at the
  /// click, held for a duration proportional to how far off-centre it is.
  /// (Scaling the VELOCITY by the offset instead — the old behaviour — falls
  /// under many cameras' minimum ONVIF velocity for mid-frame clicks, which is
  /// why small corrections did nothing at all.)
  void _ptzCenterPulse(Offset local, Size pane) {
    final o = _normOffset(local, pane);
    final len = math.sqrt(o.nx * o.nx + o.ny * o.ny);
    if (len < 0.06) return; // dead-centre click
    const speed = 0.7;
    _ptzPulseStop?.cancel();
    _ptzZoomStop?.cancel();
    widget.api
        .ptzMove(
          widget.session,
          widget.camera.id,
          pan: (o.nx / len * speed).clamp(-1.0, 1.0),
          tilt: (-o.ny / len * speed).clamp(-1.0, 1.0),
        )
        .catchError((_) {});
    _ptzPulseStop = Timer(
      Duration(milliseconds: (90 + 420 * len).round()),
      () => widget.api.ptzStop(widget.session, widget.camera.id).catchError(
        (_) {},
      ),
    );
  }

  /// Pan mode: continuous velocity toward the cursor, held until release.
  /// Driven from raw pointer events (not a drag gesture), so the move starts
  /// the instant the button goes down — no drag-slop movement required — and
  /// keeps going until [_ptzStopSteer]. Re-sends only when the direction
  /// meaningfully changes, so dragging doesn't flood the API.
  void _ptzSteer(Offset local, Size pane) {
    final o = _normOffset(local, pane);
    final last = _ptzLastSteer;
    if (_ptzSteering &&
        last != null &&
        (o.nx - last.nx).abs() < 0.04 &&
        (o.ny - last.ny).abs() < 0.04) {
      return;
    }
    _ptzPulseStop?.cancel();
    _ptzZoomStop?.cancel();
    _ptzSteering = true;
    _ptzLastSteer = o;
    widget.api
        .ptzMove(widget.session, widget.camera.id, pan: o.nx, tilt: -o.ny)
        .catchError((_) {});
  }

  void _ptzStopSteer() {
    if (!_ptzSteering) return;
    _ptzSteering = false;
    _ptzLastSteer = null;
    widget.api.ptzStop(widget.session, widget.camera.id).catchError((_) {});
  }

  @override
  void didUpdateWidget(covariant _MaximizedPane old) {
    super.didUpdateWidget(old);
    // A mode switch mid-hold must not leave the camera panning.
    if (old.ptzClickMode != widget.ptzClickMode) _ptzStopSteer();
  }

  @override
  void dispose() {
    _watchdog?.dispose();
    widget.ptzPanel?.removeListener(_onPtzPanelChanged);
    SnapshotRegistry.instance.unregister('maximized');
    widget.audio?.unregisterPane('max:${widget.camera.id}');
    // Guaranteed stop: if any PTZ motion could still be in flight (an active
    // hold-to-pan, or a pulse/zoom move whose auto-stop timer hasn't fired),
    // send Stop — cancelling the timers alone would leave the camera moving
    // forever. This also covers unmount mid-drag (e.g. double-click restore).
    final ptzMotionPending =
        _ptzSteering ||
        (_ptzZoomStop?.isActive ?? false) ||
        (_ptzPulseStop?.isActive ?? false);
    _ptzZoomStop?.cancel();
    _ptzPulseStop?.cancel();
    if (ptzMotionPending) {
      _ptzSteering = false;
      widget.api.ptzStop(widget.session, widget.camera.id).catchError((_) {});
    }
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pane = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: [
                Positioned.fill(
                  // Until the main-stream player decodes its first frame,
                  // paint the wall tile's still-live video (if we got one) in
                  // its place — never a black pane while mpv waits for a
                  // keyframe. Errors still show the camera-off icon.
                  child: _controller == null || !_firstFrame
                      ? (_error != null
                            ? Center(
                                child: Icon(
                                  Icons.videocam_off,
                                  color: Colors.red.shade300,
                                  size: 40,
                                ),
                              )
                            : widget.warmController != null
                            ? Video(
                                controller: widget.warmController!,
                                controls: NoVideoControls,
                                fit: BoxFit.contain,
                              )
                            : const Center(child: CircularProgressIndicator()))
                      : Listener(
                          onPointerDown: (e) {
                            // Mouse "back" button returns to the wall.
                            if (e.buttons & kBackMouseButton != 0) {
                              widget.onClose();
                              return;
                            }
                            // PTZ pan mode: press-and-hold starts a continuous
                            // move IMMEDIATELY (raw pointer event, no drag-slop
                            // wait); released/cancelled below.
                            if (_ptzPan &&
                                e.buttons & kPrimaryMouseButton != 0) {
                              _ptzSteer(e.localPosition, pane);
                            }
                          },
                          // While held, dragging re-steers toward the cursor.
                          // Move/up/cancel are delivered to this Listener for
                          // the whole interaction even if the pointer leaves
                          // the pane, so release always stops the motion.
                          onPointerMove: (e) {
                            if (_ptzSteering) _ptzSteer(e.localPosition, pane);
                          },
                          onPointerUp: (_) => _ptzStopSteer(),
                          onPointerCancel: (_) => _ptzStopSteer(),
                          onPointerSignal: (e) {
                            if (e is PointerScrollEvent) {
                              // Panel editor open: the wheel must not move
                              // the camera (or scale the video under the
                              // fixed-position editor overlay).
                              if (_panelEditing) return;
                              if (_ptzEnabled) {
                                // PTZ camera → drive OPTICAL zoom, not digital.
                                _ptzWheelZoom(e.scrollDelta.dy);
                              } else {
                                final factor =
                                    math.pow(1.0013, -e.scrollDelta.dy)
                                        as double;
                                _zoomAt(e.localPosition, factor, pane);
                              }
                            }
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            // Double-click in the maximized view returns to the
                            // wall (matches the old client).
                            onDoubleTap: widget.onClose,
                            // PTZ center mode: single click recenters on the
                            // clicked point. (PTZ pan mode is driven by the
                            // raw-pointer Listener above, so a stationary hold
                            // works.) Otherwise the drag digitally pans a
                            // zoomed frame — a no-op for PTZ cameras, whose
                            // wheel drives optical zoom and never scales.
                            onTapUp: _ptzCenter
                                ? (d) => _ptzCenterPulse(d.localPosition, pane)
                                : null,
                            onPanUpdate: (d) => _panBy(d.delta, pane),
                            child: ClipRect(
                              child: Transform(
                                transform: Matrix4.identity()
                                  ..translateByDouble(
                                    _offset.dx,
                                    _offset.dy,
                                    0,
                                    1,
                                  )
                                  ..scaleByDouble(_scale, _scale, 1, 1),
                                child: Video(
                                  controller: _controller!,
                                  controls: NoVideoControls,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                        ),
                ),

                // Custom PTZ panel: the operator-composed button cluster,
                // drawn over the video but under the HUD chrome below (view
                // mode drives PTZ/imaging via press-hold/tap; edit mode
                // drags/resizes). Renders nothing when inactive.
                if (_ptzEnabled && widget.ptzPanel != null && _panelActive)
                  Positioned.fill(
                    child: PtzPanelOverlay(
                      controller: widget.ptzPanel!,
                      cameraId: widget.camera.id,
                    ),
                  ),

                // Close (back to wall) + camera name + zoom level.
                Positioned(
                  top: 12,
                  left: 12,
                  child: Row(
                    children: [
                      Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          color: Colors.white,
                          onPressed: widget.onClose,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Text(
                              widget.camera.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_scale > 1.01) ...[
                              const SizedBox(width: 10),
                              Text(
                                '${_scale.toStringAsFixed(1)}×',
                                style: const TextStyle(
                                  color: Colors.cyanAccent,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                            if (_reconnecting) ...[
                              const SizedBox(width: 10),
                              const Text(
                                'Reconnecting…',
                                style: TextStyle(
                                  color: Colors.amberAccent,
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Live status badges (REC / motion / detection), top-right —
                // the maximized view must show the same indicators as the wall.
                Positioned(
                  top: 14,
                  right: 14,
                  child: ListenableBuilder(
                    listenable: widget.liveStatus,
                    builder: (context, _) {
                      final status = widget.liveStatus.cameraFor(
                        widget.camera.id,
                      );
                      return LiveStatusBadgeRow(
                        recording: status?.recording ?? false,
                        recentMotion: status?.recentMotion ?? false,
                        detectionKeys: widget.liveStatus.detectionKeysFor(
                          widget.camera.id,
                        ),
                      );
                    },
                  ),
                ),

                // PTZ controls (PTZ-capable cameras with PTZ not disabled):
                // Options "PTZ style" picks edge-pinned arrows or the compact
                // corner wheel box (pinned per "Wheel corner"). A custom
                // panel (saved layout or open editor) replaces these stock
                // controls — the `ptzActivePanel` rule from the old client.
                if (_ptzEnabled && !_panelActive)
                  Positioned.fill(
                    child: _PtzControls(
                      api: widget.api,
                      session: widget.session,
                      camera: widget.camera,
                      style: widget.ptzStyle,
                      wheelCorner: widget.ptzWheelCorner,
                    ),
                  ),

                // Panel-editor chrome: live presets/imaging on the right (so
                // the operator can exercise the camera while arranging) and
                // the palette/properties toolbar along the bottom (its Done
                // button ends the edit; Esc does too, via the wall hotkeys).
                if (_ptzEnabled &&
                    widget.ptzPanel != null &&
                    _panelEditing) ...[
                  Positioned(
                    right: 14,
                    top: 64,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        PtzPresetsPanel(
                          api: widget.api,
                          session: widget.session,
                          cameraId: widget.camera.id,
                        ),
                        const SizedBox(height: 6),
                        PtzImagingControls(
                          api: widget.api,
                          session: widget.session,
                          cameraId: widget.camera.id,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: PtzPanelEditorBar(controller: widget.ptzPanel!),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// On-video PTZ controls for a PTZ-capable camera in the maximized view.
/// Continuous-velocity model: press-and-hold a direction to move, release to
/// stop (matching the ONVIF continuous-move API). Home recenters. Errors (e.g.
/// ONVIF not reachable) surface as a brief caption rather than a crash.
///
/// Renders one of the two Options "PTZ style" affordances (fills the pane;
/// only the buttons themselves are hit-testable, everything else falls
/// through to the video):
/// - [PtzStyle.edges] — directional arrow tabs pinned mid-edge on all four
///   sides, zoom −/+ in the bottom corners and Home beside zoom + (the old
///   client's `ptzBuildEdgeAss`/`ptzCtrlGeom` layout).
/// - [PtzStyle.wheel] — the compact zoom-column + D-pad box pinned to the
///   corner picked by [wheelCorner].
class _PtzControls extends StatefulWidget {
  const _PtzControls({
    required this.api,
    required this.session,
    required this.camera,
    required this.style,
    required this.wheelCorner,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final PtzStyle style;
  final PtzWheelCorner wheelCorner;

  @override
  State<_PtzControls> createState() => _PtzControlsState();
}

class _PtzControlsState extends State<_PtzControls> {
  static const double _v = 0.6; // pan/tilt/zoom velocity
  String? _error;

  /// A hold-button's move is in flight (down received, stop not yet sent) —
  /// so unmounting mid-hold can send the guaranteed stop.
  bool _holdActive = false;

  @override
  void didUpdateWidget(covariant _PtzControls old) {
    super.didUpdateWidget(old);
    // A style switch mid-hold unmounts the held button (its pointer-up would
    // be lost) — stop any in-flight motion rather than leave it running.
    if (old.style != widget.style && _holdActive) _stop();
  }

  @override
  void dispose() {
    if (_holdActive) {
      widget.api.ptzStop(widget.session, widget.camera.id).catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    try {
      await widget.api.ptzMove(
        widget.session,
        widget.camera.id,
        pan: pan,
        tilt: tilt,
        zoom: zoom,
      );
      if (mounted && _error != null) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'PTZ unavailable');
    }
  }

  Future<void> _stop() async {
    _holdActive = false;
    try {
      await widget.api.ptzStop(widget.session, widget.camera.id);
    } catch (_) {
      /* ignore stop errors */
    }
  }

  Future<void> _home() async {
    try {
      await widget.api.ptzHome(widget.session, widget.camera.id);
    } catch (_) {
      if (mounted) setState(() => _error = 'PTZ unavailable');
    }
  }

  /// A press-and-hold button: down → start motion, up/cancel → stop.
  Widget _hold(
    IconData icon, {
    double pan = 0,
    double tilt = 0,
    double zoom = 0,
    double w = 40,
    double h = 40,
  }) {
    return Listener(
      onPointerDown: (_) {
        _holdActive = true;
        _move(pan: pan, tilt: tilt, zoom: zoom);
      },
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: Container(
        margin: const EdgeInsets.all(2),
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _tap(
    IconData icon,
    VoidCallback onTap, {
    double w = 40,
    double h = 40,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.style == PtzStyle.edges
        ? _buildEdges(context)
        : _buildWheelBox(context);
  }

  /// Edge-arrows style: hold-to-move arrow tabs pinned mid-edge on all four
  /// sides of the video, zoom − / zoom + in the bottom corners and Home just
  /// left of zoom + — the same layout as the old client's `ptzCtrlGeom`.
  /// The enclosing Stack claims hits only on the buttons; the rest of the
  /// pane still receives click-to-center / hold-to-pan / wheel-zoom.
  Widget _buildEdges(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        const m = 10.0;
        final aLong = (w * 0.13).clamp(46.0, 78.0); // arrow long dimension
        final aShort = (h * 0.10).clamp(30.0, 46.0); // arrow short dimension
        final zs = aShort; // zoom/home button side
        return Stack(
          children: [
            Positioned(
              left: (w - aLong) / 2,
              top: m,
              child: _hold(
                Icons.keyboard_arrow_up,
                tilt: _v,
                w: aLong,
                h: aShort,
              ),
            ),
            Positioned(
              left: (w - aLong) / 2,
              bottom: m,
              child: _hold(
                Icons.keyboard_arrow_down,
                tilt: -_v,
                w: aLong,
                h: aShort,
              ),
            ),
            Positioned(
              left: m,
              top: (h - aLong) / 2,
              child: _hold(
                Icons.keyboard_arrow_left,
                pan: -_v,
                w: aShort,
                h: aLong,
              ),
            ),
            Positioned(
              right: m,
              top: (h - aLong) / 2,
              child: _hold(
                Icons.keyboard_arrow_right,
                pan: _v,
                w: aShort,
                h: aLong,
              ),
            ),
            Positioned(
              left: m,
              bottom: m,
              child: _hold(Icons.zoom_out, zoom: -_v, w: zs, h: zs),
            ),
            Positioned(
              right: m,
              bottom: m,
              child: _hold(Icons.zoom_in, zoom: _v, w: zs, h: zs),
            ),
            Positioned(
              right: m + zs + 6,
              bottom: m,
              child: _tap(Icons.home, _home, w: zs, h: zs),
            ),
            if (_error != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: m + aShort + 10,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Colors.red.shade300,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Corner-wheel style: the compact zoom-column + D-pad box, pinned to the
  /// Options-picked corner (extra top inset clears the name/badge rows).
  Widget _buildWheelBox(BuildContext context) {
    final corner = widget.wheelCorner;
    return Align(
      alignment: switch (corner) {
        PtzWheelCorner.bottomLeft => Alignment.bottomLeft,
        PtzWheelCorner.bottomRight => Alignment.bottomRight,
        PtzWheelCorner.topLeft => Alignment.topLeft,
        PtzWheelCorner.topRight => Alignment.topRight,
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, corner.isTop ? 64 : 16, 16, 16),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6, right: 2),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Colors.red.shade300, fontSize: 11),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Zoom column
                  Column(
                    children: [
                      _hold(Icons.zoom_in, zoom: _v),
                      _hold(Icons.zoom_out, zoom: -_v),
                    ],
                  ),
                  const SizedBox(width: 8),
                  // Pan/tilt D-pad
                  Column(
                    children: [
                      _hold(Icons.keyboard_arrow_up, tilt: _v),
                      Row(
                        children: [
                          _hold(Icons.keyboard_arrow_left, pan: -_v),
                          _tap(Icons.home, _home),
                          _hold(Icons.keyboard_arrow_right, pan: _v),
                        ],
                      ),
                      _hold(Icons.keyboard_arrow_down, tilt: -_v),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
