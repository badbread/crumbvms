// Auto-sizing wall clock tile (fitClock / startClockTicker / reflowClocks in
// apps/desktop/src/app.js ~5677-5720). No config — dropping a `{type:"clock"}`
// spec onto a slot is enough.

import 'dart:async';

import 'package:flutter/material.dart';

class ClockTile extends StatefulWidget {
  const ClockTile({super.key});

  @override
  State<ClockTile> createState() => _ClockTileState();
}

class _ClockTileState extends State<ClockTile> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final d = _now;
    final time = '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
    final date = '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}, ${d.year}';
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          if (w <= 0 || h <= 0) return const SizedBox.shrink();
          // Mirrors fitClock's deterministic formula: 8 monospace glyphs at
          // ~0.6em advance + 7px letter-spacing filling ~90% of the width,
          // capped so time + date fit the height (time ~= 60% of h).
          final fsW = (w * 0.90 - 7) / (8 * 0.60);
          final fsH = h * 0.60;
          final fs = fsW.clamp(0.0, fsH).clamp(12.0, 140.0);
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  time,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: fs,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    letterSpacing: 7,
                    fontFamily: 'monospace',
                  ),
                ),
                SizedBox(height: fs * 0.06),
                Text(
                  date,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: (fs * 0.34).clamp(10.0, 48.0),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
