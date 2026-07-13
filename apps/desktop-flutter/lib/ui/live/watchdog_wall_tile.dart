// Drop-in replacement for wall_screen.dart's `_WallTile` that adds the live
// stall watchdog (auto-reconnect on a frozen/black pane) and the
// "Connecting…" placeholder cascade on tab return. See pane_watchdog.dart
// and live_reveal_controller.dart for the ported logic; this file is the UI
// glue, matching `setPaneReconnecting`/`setTileConnecting` in
// apps/desktop/src/app.js (a subtle badge + placeholder, not a hard error
// state — the tile keeps trying forever, it just tells the operator it's
// trying).
//
// Same stream-URL fetch + mpv tuning as the existing `_WallTile` in
// wall_screen.dart (kept in sync deliberately — see integration notes).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

import 'live_reveal_controller.dart';
import 'pane_watchdog.dart';

const List<List<String>> _wallMpvProps = [
  ['rtsp-transport', 'tcp'],
  ['hwdec', 'auto'],
  ['cache', 'yes'],
  ['demuxer-readahead-secs', '2.0'],
  ['demuxer-max-bytes', '32MiB'],
  ['demuxer-max-back-bytes', '1MiB'],
  ['network-timeout', '10'],
  ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
  ['mute', 'yes'],
];

/// One live camera pane with a self-healing stall watchdog.
///
/// Constructor is intentionally a superset of `_WallTile`'s so it can be
/// swapped in directly: `api`/`session`/`camera`/`onTap` behave identically;
/// [active] and [revealController] are additive and both optional.
class WatchdogWallTile extends StatefulWidget {
  const WatchdogWallTile({
    super.key,
    required this.api,
    required this.session,
    required this.camera,
    required this.onTap,
    this.active = true,
    this.revealController,
  });

  final CrumbApi api;
  final Session session;
  final Camera camera;
  final VoidCallback onTap;

  /// Whether this tile's pane is currently on-screen. When false, the
  /// watchdog pauses (mirrors app.js bailing out of `liveStallWatchdog`
  /// while the Live view is hidden or a modal is open) rather than fighting
  /// a background/paused player.
  final bool active;

  /// Optional shared controller driving the "Connecting…" placeholder
  /// cascade when the Live view (re)gains visibility. If the host calls
  /// `revealController.beginReconnect([...paneIds])` including this tile's
  /// `camera.id`, the tile hides its video behind the placeholder until its
  /// first live frame decodes (or the controller's fallback fires).
  final LiveRevealController? revealController;

  @override
  State<WatchdogWallTile> createState() => _WatchdogWallTileState();
}

class _WatchdogWallTileState extends State<WatchdogWallTile> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  bool _firstFrame = false;
  bool _reconnecting = false;
  PaneWatchdog? _watchdog;

  String get _paneId => widget.camera.id;

  @override
  void initState() {
    super.initState();
    widget.revealController?.addListener(_onRevealChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant WatchdogWallTile old) {
    super.didUpdateWidget(old);
    if (old.revealController != widget.revealController) {
      old.revealController?.removeListener(_onRevealChanged);
      widget.revealController?.addListener(_onRevealChanged);
    }
    if (old.active != widget.active) {
      _watchdog?.paused = !widget.active;
    }
  }

  void _onRevealChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      final url = streams.preferredForWall;
      if (url == null) {
        if (mounted) setState(() => _error = 'no stream');
        return;
      }
      final player = Player();
      final controller = VideoController(player);
      final p = player.platform;
      if (p is NativePlayer) {
        for (final kv in _wallMpvProps) {
          try {
            await p.setProperty(kv[0], kv[1]);
          } catch (_) {
            /* non-fatal */
          }
        }
      }
      player.stream.width.listen((w) {
        if (w != null && w > 0) {
          if (!_firstFrame && mounted) setState(() => _firstFrame = true);
          widget.revealController?.notifyFrameDecoded(_paneId);
        }
      });
      await player.open(Media(url));
      if (!mounted) {
        player.dispose();
        return;
      }
      final watchdog = PaneWatchdog(
        player: player,
        reconnect: _reconnect,
        onReconnectingChanged: (on) {
          if (mounted) setState(() => _reconnecting = on);
        },
      )..paused = !widget.active;
      watchdog.start();
      setState(() {
        _player = player;
        _controller = controller;
        _watchdog = watchdog;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'load failed');
    }
  }

  /// Reconnect logic the watchdog calls when it decides this pane is
  /// stalled/wedged: refetch the stream URL (go2rtc's restream address can
  /// change across a Crumb reconcile) and re-open the existing player on it,
  /// same as app.js's `reload_pane` (loadfile into the existing native pane
  /// rather than tearing the whole thing down).
  Future<void> _reconnect() async {
    final player = _player;
    if (player == null) return;
    try {
      final streams = await widget.api.cameraStreams(
        widget.session,
        widget.camera.id,
      );
      final url = streams.preferredForWall;
      if (url == null) return;
      _firstFrame = false;
      await player.open(Media(url));
      _watchdog?.resetBaseline();
    } catch (_) {
      // Left for the next backoff tick — the watchdog never gives up.
    }
  }

  @override
  void dispose() {
    widget.revealController?.removeListener(_onRevealChanged);
    _watchdog?.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connecting =
        widget.revealController?.isConnecting(_paneId) ?? false;
    final showVideo = _controller != null && !connecting;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        color: Colors.grey.shade900,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showVideo)
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
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),

            if (connecting)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.75),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Connecting…',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Camera-name label (bottom-left), with a live/offline dot and a
            // subtle "Reconnecting…" badge while the watchdog is retrying —
            // matches `setPaneReconnecting`'s tile-strip badge in app.js.
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                            : (_reconnecting
                                ? Colors.amber
                                : (_firstFrame
                                    ? Colors.greenAccent
                                    : Colors.amber)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.camera.name,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
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
        ),
      ),
    );
  }
}
