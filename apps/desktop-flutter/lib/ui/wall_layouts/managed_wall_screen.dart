// The managed live wall: layout preset picker + camera sidebar + a slot grid
// where each tile is independently assignable, selectable, and can be
// maximized. This is the richer sibling of wall_screen.dart's fixed
// auto-grid — it's the port of the Tauri client's slot-management system
// (app.js: buildLayoutPresets, buildCameraList, selectSlot,
// assignCameraToSelectedSlot, advanceSelectedSlot, autoFillSlots,
// applyAllCamerasView, liveStreamUrl / getStreamPref / setStreamPref).
//
// Video playback reuses the media_kit/libmpv setup proven in wall_screen.dart
// (see that file's `_WallTile` for the canonical property list); this file
// does not change how a stream is decoded, only which URL each slot plays
// and how slots are assigned/selected/maximized.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/layout_controller.dart';
import 'package:crumb_desktop/state/stream_prefs.dart';
import 'package:crumb_desktop/state/wall_layout.dart';
import 'camera_sidebar.dart';
import 'layout_preset_bar.dart';

/// Fractional (0..1) geometry for each slot of the current layout. Mirrors
/// the CSS grid templates app.js used per layout id; '1plus5' is the one
/// non-uniform pattern (one big pane + 5 small, app.js:2168-2176's SVG
/// mirrors the same proportions).
List<Rect> _slotRects(LayoutController controller) {
  if (controller.isAllCameras) {
    final g = controller.autoGrid ?? const AutoGrid(cols: 1, rows: 1);
    return _uniformGrid(g.cols, g.rows);
  }
  final preset = controller.preset;
  if (preset.isOnePlusFive) {
    const third = 1 / 3;
    const twoThirds = 2 / 3;
    return const [
      Rect.fromLTWH(0, 0, twoThirds, twoThirds), // big pane
      Rect.fromLTWH(twoThirds, 0, third, third),
      Rect.fromLTWH(twoThirds, third, third, third),
      Rect.fromLTWH(0, twoThirds, third, third),
      Rect.fromLTWH(third, twoThirds, third, third),
      Rect.fromLTWH(twoThirds, twoThirds, third, third),
    ];
  }
  final cols = preset.crossAxisCount;
  final rows = (preset.tiles / cols).ceil();
  return _uniformGrid(cols, rows);
}

List<Rect> _uniformGrid(int cols, int rows) {
  final cw = 1.0 / cols;
  final ch = 1.0 / rows;
  final rects = <Rect>[];
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      rects.add(Rect.fromLTWH(c * cw, r * ch, cw, ch));
    }
  }
  return rects;
}

class ManagedWallScreen extends StatefulWidget {
  const ManagedWallScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.onLogout,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;
  final VoidCallback onLogout;

  @override
  State<ManagedWallScreen> createState() => _ManagedWallScreenState();
}

class _ManagedWallScreenState extends State<ManagedWallScreen> {
  late final LayoutController _controller;
  StreamPrefsStore? _prefs;

  @override
  void initState() {
    super.initState();
    final visible = widget.cameras.where((c) => c.enabled).toList(growable: false);
    _controller = LayoutController(cameras: visible);
    StreamPrefsStore.load().then((p) {
      if (mounted) setState(() => _prefs = p);
    });
  }

  @override
  void didUpdateWidget(covariant ManagedWallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cameras != widget.cameras) {
      _controller.setCameras(
        widget.cameras.where((c) => c.enabled).toList(growable: false),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    return Scaffold(
      backgroundColor: Colors.black,
      body: prefs == null
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                CameraSidebar(controller: _controller),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        color: Colors.black.withValues(alpha: 0.5),
                        child: Row(
                          children: [
                            Expanded(
                              child: LayoutPresetBar(controller: _controller),
                            ),
                            IconButton(
                              tooltip: 'Log out',
                              icon: const Icon(
                                Icons.logout,
                                size: 18,
                                color: Colors.white70,
                              ),
                              onPressed: widget.onLogout,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: AnimatedBuilder(
                          animation: _controller,
                          builder: (context, _) {
                            final maximized = _controller.maximized;
                            if (maximized != null) {
                              return _WallSlotTile(
                                key: ValueKey('max-${maximized.id}'),
                                api: widget.api,
                                session: widget.session,
                                camera: maximized,
                                prefs: prefs,
                                slotIndex: -1,
                                isSelected: true,
                                isMaximized: true,
                                controller: _controller,
                              );
                            }
                            return _WallGrid(
                              controller: _controller,
                              api: widget.api,
                              session: widget.session,
                              prefs: prefs,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _WallGrid extends StatelessWidget {
  const _WallGrid({
    required this.controller,
    required this.api,
    required this.session,
    required this.prefs,
  });

  final LayoutController controller;
  final CrumbApi api;
  final Session session;
  final StreamPrefsStore prefs;

  @override
  Widget build(BuildContext context) {
    final rects = _slotRects(controller);
    if (rects.isEmpty) {
      return const Center(
        child: Text(
          'No cameras visible to this account.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            for (var i = 0; i < rects.length; i++)
              Positioned(
                left: rects[i].left * constraints.maxWidth,
                top: rects[i].top * constraints.maxHeight,
                width: rects[i].width * constraints.maxWidth,
                height: rects[i].height * constraints.maxHeight,
                child: Padding(
                  padding: const EdgeInsets.all(1.5),
                  child: _SlotDropTarget(
                    slotIndex: i,
                    controller: controller,
                    child: _buildSlot(i),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildSlot(int slotIndex) {
    final camId = controller.slotMap[slotIndex];
    final selected = controller.selectedSlot == slotIndex;
    if (camId == null) {
      return _EmptySlot(
        selected: selected,
        onTap: () => controller.selectSlot(slotIndex),
      );
    }
    final cam = controller.cameras
        .where((c) => c.id == camId)
        .cast<Camera?>()
        .firstWhere((c) => c != null, orElse: () => null);
    if (cam == null) {
      return _EmptySlot(
        selected: selected,
        onTap: () => controller.selectSlot(slotIndex),
      );
    }
    return _WallSlotTile(
      key: ValueKey('slot-$slotIndex-${cam.id}'),
      api: api,
      session: session,
      camera: cam,
      prefs: prefs,
      slotIndex: slotIndex,
      isSelected: selected,
      isMaximized: false,
      controller: controller,
    );
  }
}

class _SlotDropTarget extends StatelessWidget {
  const _SlotDropTarget({
    required this.slotIndex,
    required this.controller,
    required this.child,
  });

  final int slotIndex;
  final LayoutController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<CameraDragData>(
      onWillAcceptWithDetails: (_) => controller.maximized == null,
      onAcceptWithDetails: (details) =>
          controller.assignCameraToSlot(details.data.cameraId, slotIndex),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (hovering)
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.cyanAccent, width: 2),
                  color: Colors.cyanAccent.withValues(alpha: 0.12),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EmptySlot extends StatelessWidget {
  const _EmptySlot({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(
            color: selected ? Colors.cyanAccent : Colors.white12,
            width: selected ? 2 : 1,
          ),
        ),
        child: const Center(
          child: Icon(Icons.add, color: Colors.white24, size: 22),
        ),
      ),
    );
  }
}

/// One assigned slot: fetches this camera's stream URLs, resolves the
/// effective quality via [StreamPrefsStore], and plays it. Click selects the
/// slot; double-click maximizes/restores; right-click opens the stream
/// quality + clear-slot menu (app.js's tile context menu, app.js:5865-5874
/// for the Stream submenu specifically).
class _WallSlotTile extends StatefulWidget {
  const _WallSlotTile({
    super.key,
    required this.api,
    required this.session,
    required this.camera,
    required this.prefs,
    required this.slotIndex,
    required this.isSelected,
    required this.isMaximized,
    required this.controller,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final StreamPrefsStore prefs;
  final int slotIndex;
  final bool isSelected;
  final bool isMaximized;
  final LayoutController controller;

  @override
  State<_WallSlotTile> createState() => _WallSlotTileState();
}

class _WallSlotTileState extends State<_WallSlotTile> {
  Player? _player;
  VideoController? _controller;
  StreamUrls? _streams;
  String? _error;
  bool _firstFrame = false;
  Timer? _mainCheckTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _WallSlotTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.camera.id != widget.camera.id) {
      _teardown();
      _load();
    } else if (oldWidget.isMaximized != widget.isMaximized && _streams != null) {
      _applyUrl();
    }
  }

  Future<void> _load() async {
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      if (!mounted) return;
      _streams = streams;
      final url = _resolveUrl(streams);
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
      setState(() {
        _player = player;
        _controller = controller;
      });
      // If maximized and this camera's main stream never produces a frame,
      // fall back to sub instead of leaving the pane black (app.js's
      // scheduleMaximizedMainCheck / mainUnavailable).
      if (widget.isMaximized) {
        _mainCheckTimer = Timer(const Duration(seconds: 4), () {
          if (!mounted || _firstFrame) return;
          widget.prefs.markMainUnavailable(widget.camera.id);
          _applyUrl();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'load failed');
    }
  }

  String? _resolveUrl(StreamUrls streams) => widget.prefs.liveStreamUrl(
    widget.camera.id,
    streams,
    isMaximized: widget.isMaximized,
  );

  Future<void> _applyUrl() async {
    final streams = _streams;
    final player = _player;
    if (streams == null || player == null) return;
    final url = _resolveUrl(streams);
    if (url == null) return;
    setState(() => _firstFrame = false);
    await player.open(Media(url));
  }

  void _teardown() {
    _mainCheckTimer?.cancel();
    _player?.dispose();
    _player = null;
    _controller = null;
    _streams = null;
    _firstFrame = false;
    _error = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _showContextMenu(Offset globalPosition) {
    final effective = widget.prefs.effectiveFor(widget.camera.id);
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        PopupMenuItem<void>(
          enabled: false,
          child: Text(
            widget.camera.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<void>(
          checked: effective == StreamQuality.main,
          onTap: () {
            widget.prefs.setOverride(widget.camera.id, StreamQuality.main);
            _applyUrl();
          },
          child: const Text('Main stream'),
        ),
        CheckedPopupMenuItem<void>(
          checked: effective == StreamQuality.sub,
          onTap: () {
            widget.prefs.setOverride(widget.camera.id, StreamQuality.sub);
            _applyUrl();
          },
          child: const Text('Sub stream'),
        ),
        if (!widget.isMaximized) ...[
          const PopupMenuDivider(),
          PopupMenuItem<void>(
            onTap: () => widget.controller.clearSlot(widget.slotIndex),
            child: const Text('Clear tile'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isMaximized
          ? null
          : () => widget.controller.selectSlot(widget.slotIndex),
      onDoubleTap: () {
        if (widget.isMaximized) {
          widget.controller.restoreFromMaximize();
        } else {
          widget.controller.maximizeSlot(widget.slotIndex);
        }
      },
      onSecondaryTapDown: (details) =>
          _showContextMenu(details.globalPosition),
      child: Container(
        color: Colors.grey.shade900,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_controller != null)
              Video(
                controller: _controller!,
                controls: NoVideoControls,
                fit: BoxFit.cover,
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
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),

            if (widget.isSelected && !widget.isMaximized)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.cyanAccent, width: 2),
                    ),
                  ),
                ),
              ),

            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                            : (_firstFrame ? Colors.greenAccent : Colors.amber),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.camera.name,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            if (widget.isMaximized)
              Positioned(
                top: 10,
                left: 10,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    color: Colors.white,
                    onPressed: widget.controller.restoreFromMaximize,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

