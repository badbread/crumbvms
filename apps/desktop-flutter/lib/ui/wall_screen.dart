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
import 'package:crumb_desktop/services/audio_follow_controller.dart';
import 'package:crumb_desktop/services/snapshot_registry.dart';
import 'package:crumb_desktop/src/rust/api/host.dart';
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/state/stream_prefs.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/live_status/live_status_badges.dart';
import 'package:crumb_desktop/ui/live_status/live_status_controller.dart';
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
    this.onMaximizedCameraChanged,
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

  /// Per-camera stream (main/sub) + PTZ-disable prefs. Drives the right-click
  /// menu on a tile and which stream each pane plays.
  final StreamPrefsStore? streamPrefs;

  /// The applied saved view (its custom layout + slot→camera map). Null → the
  /// default auto-grid of every enabled camera (the "All Cameras" wall).
  final AppliedView? view;

  /// Reports which camera is currently maximized (full-pane) on the wall, or
  /// null when restored — so the host can carry that maximize into Playback.
  final ValueChanged<String?>? onMaximizedCameraChanged;

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
  HostStats? _stats;
  double? _cpuPercent;
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
    // A different applied view (or none) → re-parse its special-tile specs.
    if (!identical(old.view, widget.view) || old.view?.id != widget.view?.id) {
      _applyViewSpecs();
    }
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
    setState(() {
      _stats = s;
      _cpuPercent = cpuPct;
      _lastCpuTime = s.cpuTimeSecs;
      _lastSample = now;
    });
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _liveStatus.removeListener(_onLiveStatusTick);
    _special.dispose();
    _liveStatus.dispose();
    super.dispose();
  }

  /// Maximize a camera + make it the audio-active pane.
  void _maximize(Camera cam) {
    widget.audio?.setMaximized('max:${cam.id}');
    widget.onMaximizedCameraChanged?.call(cam.id);
    setState(() => _maximized = cam);
  }

  /// Restore from the maximized pane back to the grid.
  void _restore() {
    widget.audio?.setMaximized(null);
    widget.onMaximizedCameraChanged?.call(null);
    setState(() => _maximized = null);
  }

  @override
  Widget build(BuildContext context) {
    final cams = _shown;
    final cols = cams.isEmpty ? 1 : math.sqrt(cams.length).ceil();
    final s = _stats;
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

          // Top bar: camera count + host stats (FRB) + logout.
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${cams.length} cameras',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.cyanAccent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'CPU ${_cpuPercent?.toStringAsFixed(0) ?? "—"}%  '
                      'GPU ${s?.gpuUtil?.toStringAsFixed(0) ?? "—"}%  '
                      'NVDEC ${s?.gpuDecUtil?.toStringAsFixed(0) ?? "—"}%  '
                      'RSS ${s?.memMb.toStringAsFixed(0) ?? "—"}MB',
                    ),
                    const SizedBox(width: 12),
                    InkWell(
                      onTap: widget.onLogout,
                      child: const Icon(
                        Icons.logout,
                        size: 16,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

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
              ptzClickMode:
                  widget.clientOptions?.ptzClickMode ?? PtzClickMode.center,
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
      onGoToCamera: (id) {
        for (final c in cams) {
          if (c.id == id) {
            _maximize(c);
            break;
          }
        }
      },
      onEscape: _maximized == null ? null : _restore,
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
            child = cam == null
                ? const _EmptySlot()
                : _WallTile(
                    key: ValueKey('${view.id}:$i:${cam.id}'),
                    api: widget.api,
                    session: widget.session,
                    camera: cam,
                    liveStatus: _liveStatus,
                    streamPrefs: widget.streamPrefs,
                    audio: widget.audio,
                    showInfoBar: showInfoBar,
                    // Custom cells can be any aspect — letterbox, don't crop.
                    fit: BoxFit.contain,
                    onTap: () {
                      // Clicking a camera retargets classic (click) hotspots.
                      _special.routeHotspotClick(i, cam.id);
                      _maximize(cam);
                    },
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

  /// The tile grid. Pulled out of [build] so it can be rebuilt on a client-
  /// option change (via the ListenableBuilder above) without disturbing the
  /// rest of the wall. `showInfoBar` chooses the per-tile header strip vs the
  /// floating name/badge overlays.
  Widget _grid(List<Camera> cams, int cols, bool showInfoBar) {
    return GridView.count(
      crossAxisCount: cols,
      mainAxisSpacing: 2,
      crossAxisSpacing: 2,
      childAspectRatio: 16 / 9,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final cam in cams)
          _WallTile(
            key: ValueKey(cam.id),
            api: widget.api,
            session: widget.session,
            camera: cam,
            liveStatus: _liveStatus,
            streamPrefs: widget.streamPrefs,
            audio: widget.audio,
            showInfoBar: showInfoBar,
            onTap: () => _maximize(cam),
          ),
      ],
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
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final LiveStatusController liveStatus;
  final bool showInfoBar;
  final VoidCallback onTap;
  final StreamPrefsStore? streamPrefs;
  final AudioFollowController? audio;

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
  String? _error;
  bool _firstFrame = false;

  // Per-tile digital zoom: hovering the tile + mouse wheel zooms IN PLACE
  // (the wall stays up); drag pans when zoomed. Double-click still maximizes.
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  static const double _maxZoom = 8.0;

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
            isMaximized: false,
          ) ??
          streams.preferredForWall;
      if (url == null) {
        setState(() => _error = 'no stream');
        return;
      }
      final player = Player();
      final controller = VideoController(player);
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
        if (w != null && w > 0 && !_firstFrame && mounted) {
          setState(() => _firstFrame = true);
        }
      });
      await player.open(Media(url));
      if (!mounted) {
        player.dispose();
        return;
      }
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
      setState(() {
        _player = player;
        _controller = controller;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'load failed');
      }
    }
  }

  String get _paneId => 'wall:${widget.camera.id}';

  /// Re-open the player with the currently-preferred stream (after a main/sub
  /// override change from the right-click menu). Re-fetches the URLs so a
  /// server-side change is picked up too.
  Future<void> _reloadStream() async {
    final old = _player;
    SnapshotRegistry.instance.unregister(_paneId);
    if (mounted) {
      setState(() {
        _player = null;
        _controller = null;
        _firstFrame = false;
        _error = null;
      });
    }
    old?.dispose();
    await _load();
  }

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
    SnapshotRegistry.instance.unregister(_paneId);
    widget.audio?.unregisterPane(_paneId);
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

                  // Camera-name label (bottom-left), with a live/offline dot.
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
                                  : (_firstFrame
                                        ? Colors.greenAccent
                                        : Colors.amber),
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
    this.ptzClickMode = PtzClickMode.center,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final LiveStatusController liveStatus;
  final VoidCallback onClose;
  final StreamPrefsStore? streamPrefs;
  final AudioFollowController? audio;

  /// What a click on a PTZ-capable video does (center / pan / off).
  final PtzClickMode ptzClickMode;

  @override
  State<_MaximizedPane> createState() => _MaximizedPaneState();
}

class _MaximizedPaneState extends State<_MaximizedPane> {
  Player? _player;
  VideoController? _controller;
  String? _error;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  static const double _maxZoom = 8.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
      setState(() {
        _player = player;
        _controller = controller;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'load failed');
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

  bool get _ptzCenter =>
      _ptzEnabled && widget.ptzClickMode == PtzClickMode.center;
  bool get _ptzPan => _ptzEnabled && widget.ptzClickMode == PtzClickMode.pan;

  // ── PTZ optical zoom via the mouse wheel ────────────────────────────────
  // The wheel is discrete but ONVIF zoom is continuous (move → stop), so each
  // notch starts a zoom in the wheel's direction and a debounced timer sends
  // stop shortly after scrolling settles — smooth optical zoom while spinning.
  Timer? _ptzZoomStop;

  void _ptzWheelZoom(double scrollDy) {
    const v = 0.5;
    final zoom = scrollDy < 0 ? v : -v; // wheel up = zoom in
    widget.api
        .ptzMove(widget.session, widget.camera.id, zoom: zoom)
        .catchError((_) {});
    _ptzZoomStop?.cancel();
    _ptzZoomStop = Timer(const Duration(milliseconds: 220), () {
      widget.api.ptzStop(widget.session, widget.camera.id).catchError((_) {});
    });
  }

  // ── PTZ click-to-center / click-hold-to-pan (ported from app.js
  //    ptzVideoClick / ptzVideoSteer). Offset from tile centre, normalised to
  //    [-1,1], drives an ONVIF velocity move.
  Timer? _ptzPulseStop;
  bool _ptzSteering = false;

  ({double nx, double ny}) _normOffset(Offset local, Size pane) {
    final nx = (local.dx / pane.width * 2 - 1).clamp(-1.0, 1.0);
    final ny = (local.dy / pane.height * 2 - 1).clamp(-1.0, 1.0);
    return (nx: nx, ny: ny);
  }

  /// Center mode: a proportional recenter pulse — click near the centre is a
  /// no-op, edges pan harder/longer — then auto-stop.
  void _ptzCenterPulse(Offset local, Size pane) {
    final o = _normOffset(local, pane);
    final mag = math.max(o.nx.abs(), o.ny.abs());
    if (mag < 0.06) return; // dead-centre click
    widget.api
        .ptzMove(
          widget.session,
          widget.camera.id,
          pan: (o.nx * 0.7).clamp(-1.0, 1.0),
          tilt: (-o.ny * 0.7).clamp(-1.0, 1.0),
        )
        .catchError((_) {});
    _ptzPulseStop?.cancel();
    _ptzPulseStop = Timer(
      Duration(milliseconds: (80 + 320 * mag).round()),
      () => widget.api.ptzStop(widget.session, widget.camera.id).catchError(
        (_) {},
      ),
    );
  }

  /// Pan mode: continuous velocity toward the cursor, held until release.
  void _ptzSteer(Offset local, Size pane) {
    final o = _normOffset(local, pane);
    _ptzSteering = true;
    widget.api
        .ptzMove(widget.session, widget.camera.id, pan: o.nx, tilt: -o.ny)
        .catchError((_) {});
  }

  void _ptzStopSteer() {
    if (!_ptzSteering) return;
    _ptzSteering = false;
    widget.api.ptzStop(widget.session, widget.camera.id).catchError((_) {});
  }

  @override
  void dispose() {
    SnapshotRegistry.instance.unregister('maximized');
    widget.audio?.unregisterPane('max:${widget.camera.id}');
    _ptzZoomStop?.cancel();
    _ptzPulseStop?.cancel();
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
                  child: _controller == null
                      ? Center(
                          child: _error != null
                              ? Icon(
                                  Icons.videocam_off,
                                  color: Colors.red.shade300,
                                  size: 40,
                                )
                              : const CircularProgressIndicator(),
                        )
                      : Listener(
                          onPointerDown: (e) {
                            // Mouse "back" button returns to the wall.
                            if (e.buttons & kBackMouseButton != 0) {
                              widget.onClose();
                            }
                          },
                          onPointerSignal: (e) {
                            if (e is PointerScrollEvent) {
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
                            // clicked point. PTZ pan mode: press-hold steers
                            // toward the cursor (drag re-steers), release stops.
                            // Otherwise the drag digitally pans a zoomed frame.
                            onTapUp: _ptzCenter
                                ? (d) => _ptzCenterPulse(d.localPosition, pane)
                                : null,
                            onPanStart: _ptzPan
                                ? (d) => _ptzSteer(d.localPosition, pane)
                                : null,
                            onPanUpdate: _ptzPan
                                ? (d) => _ptzSteer(d.localPosition, pane)
                                : (d) => _panBy(d.delta, pane),
                            onPanEnd: _ptzPan ? (_) => _ptzStopSteer() : null,
                            onPanCancel: _ptzPan ? _ptzStopSteer : null,
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

                // PTZ controls (PTZ-capable cameras with PTZ not disabled).
                if (_ptzEnabled)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _PtzControls(
                      api: widget.api,
                      session: widget.session,
                      camera: widget.camera,
                    ),
                  ),
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
class _PtzControls extends StatefulWidget {
  const _PtzControls({
    required this.api,
    required this.session,
    required this.camera,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;

  @override
  State<_PtzControls> createState() => _PtzControlsState();
}

class _PtzControlsState extends State<_PtzControls> {
  static const double _v = 0.6; // pan/tilt/zoom velocity
  String? _error;

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
  }) {
    return Listener(
      onPointerDown: (_) => _move(pan: pan, tilt: tilt, zoom: zoom),
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: Container(
        margin: const EdgeInsets.all(2),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _tap(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        width: 40,
        height: 40,
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
    return Container(
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
    );
  }
}
