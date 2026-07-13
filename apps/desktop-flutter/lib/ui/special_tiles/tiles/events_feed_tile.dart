// Live detections feed tile: recent GET /events (newest first), click a row
// to jump to that moment in Playback. Port of updateEventTiles /
// wireEventTile / goToPlaybackEvent (apps/desktop/src/app.js ~5632-5762).
//
// Reuses the existing `StatusApi.getEvents` extension (lib/api/status_api.dart)
// and `detectionIconFor` (lib/ui/live_status/detection_icons.dart) rather than
// re-fetching or re-mapping icons. Throttled to a poll every ~5s, matching
// app.js's `eventTileLastFetch` gate.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/status_api.dart';
import 'package:crumb_desktop/api/status_models.dart';
import 'package:crumb_desktop/ui/live_status/detection_icons.dart';

/// Called when the operator clicks a detection row: `(cameraId, timestamp)`.
/// The host is expected to switch to Playback and seek there (goToPlaybackEvent
/// in app.js) — that's playback-screen wiring outside this feature's scope.
typedef EventTileTapCallback = void Function(String cameraId, DateTime ts);

class EventsFeedTile extends StatefulWidget {
  const EventsFeedTile({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    this.onTapEvent,
    this.pollInterval = const Duration(seconds: 5),
    this.lookback = const Duration(minutes: 30),
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;
  final EventTileTapCallback? onTapEvent;
  final Duration pollInterval;
  final Duration lookback;

  @override
  State<EventsFeedTile> createState() => _EventsFeedTileState();
}

class _EventsFeedTileState extends State<EventsFeedTile> {
  Timer? _timer;
  List<DetectionEvent> _events = const [];
  bool _loadedOnce = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_refresh()));
  }

  @override
  void didUpdateWidget(covariant EventsFeedTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cameras.map((c) => c.id).join(',') !=
        widget.cameras.map((c) => c.id).join(',')) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final camIds = widget.cameras.map((c) => c.id).toList(growable: false);
    if (camIds.isEmpty) {
      if (mounted) setState(() => _loadedOnce = true);
      return;
    }
    final seq = ++_seq;
    final now = DateTime.now();
    try {
      final resp = await widget.api.getEvents(
        widget.session,
        cameraIds: camIds,
        start: now.subtract(widget.lookback),
        end: now.add(const Duration(seconds: 5)),
        limit: 40,
      );
      if (!mounted || seq != _seq) return;
      final sorted = List<DetectionEvent>.of(resp.events)
        ..sort((a, b) => b.ts.compareTo(a.ts));
      setState(() {
        _events = sorted.take(40).toList(growable: false);
        _loadedOnce = true;
      });
    } catch (_) {
      // Transient failure — keep the last-known rows on screen (matches
      // app.js: a failed fetch leaves the previous list untouched).
      if (mounted && !_loadedOnce) setState(() => _loadedOnce = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _cameraName(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c.name;
    }
    return 'Camera';
  }

  String _hhmmss(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final local = t.toLocal();
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF111214),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF2A2C30))),
            ),
            child: Row(
              children: const [
                Icon(Icons.notifications_none, size: 14, color: Colors.white70),
                SizedBox(width: 6),
                Text(
                  'Detections',
                  style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          Expanded(
            child: !_loadedOnce
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _events.isEmpty
                ? Center(
                    child: Text(
                      'No recent detections',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: _events.length,
                    itemBuilder: (context, i) {
                      final e = _events[i];
                      final spec = detectionIconFor(e.iconKey);
                      return InkWell(
                        onTap: widget.onTapEvent == null
                            ? null
                            : () => widget.onTapEvent!(e.cameraId, e.ts),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          child: Row(
                            children: [
                              Icon(spec.icon, size: 15, color: spec.color),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _cameraName(e.cameraId),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                e.label.isNotEmpty ? e.label : e.iconKey,
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _hhmmss(e.ts),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 11,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
