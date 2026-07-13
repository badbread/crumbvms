// Playback transport bar — frame-back / play-pause / frame-fwd, speed cycle,
// and the synced time display. Ported from the old client's playback toolbar
// wiring (pbPlayPause/pbSpeedBtn/pb-frame-back/pb-frame-fwd click handlers,
// app.js:6417-6423; pbInjectFrameStepButtons, app.js:8329;
// pbUpdatePlayPauseBtn/pbUpdateSpeedBtn/pbUpdateTimeDisplay, app.js:8130-8153).
//
// Drop this into any playback screen's control row; it only needs a
// [PlaybackTransportController] (see playback_transport_controller.dart) —
// it knows nothing about segments, cameras, or the timeline.

import 'package:flutter/material.dart';

import 'playback_transport_controller.dart';

/// Compact playback transport toolbar: frame-back, play/pause, frame-fwd,
/// speed cycle, and a live HH:MM:SS (or MM/DD HH:MM:SS when the playhead
/// isn't today) time readout.
class PlaybackTransportBar extends StatefulWidget {
  const PlaybackTransportBar({super.key, required this.controller});

  final PlaybackTransportController controller;

  @override
  State<PlaybackTransportBar> createState() => _PlaybackTransportBarState();
}

class _PlaybackTransportBarState extends State<PlaybackTransportBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant PlaybackTransportBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// pbUpdateTimeDisplay (app.js:8140-8153).
  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final isToday =
        t.year == now.year && t.month == now.month && t.day == now.day;
    if (isToday) return '$hh:$mm:$ss';
    final mon = t.month.toString().padLeft(2, '0');
    final day = t.day.toString().padLeft(2, '0');
    return '$mon/$day $hh:$mm:$ss';
  }

  /// pbUpdateSpeedBtn (app.js:8136-8138): "0.5x", "1x", "2x", "4x", "8x".
  String _formatSpeed(double speed) {
    final isWhole = speed == speed.roundToDouble();
    return '${isWhole ? speed.toStringAsFixed(0) : speed.toStringAsFixed(1)}x';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Step back one frame',
            icon: const Icon(Icons.skip_previous, color: Colors.white),
            onPressed: () => c.frameStep(false),
          ),
          IconButton(
            tooltip: c.playing ? 'Pause' : 'Play',
            icon: Icon(
              c.playing ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
            ),
            onPressed: c.togglePlay,
          ),
          IconButton(
            tooltip: 'Step forward one frame',
            icon: const Icon(Icons.skip_next, color: Colors.white),
            onPressed: () => c.frameStep(true),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: c.cycleSpeed,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _formatSpeed(c.speed),
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _formatTime(c.playhead),
            style: const TextStyle(
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
