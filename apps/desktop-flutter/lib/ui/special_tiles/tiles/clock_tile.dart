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
    // Lay the time + date out at a fixed natural size, then let a FittedBox
    // scale the WHOLE block uniformly to fit the cell — both lines always fit
    // and stay proportional, whatever the cell's width/height/aspect. (The old
    // hand-rolled font-size formula sized from the time string only, so the
    // longer date line overflowed and clipped in short/narrow cells.)
    return ColoredBox(
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  time,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 64,
                    fontFeatures: [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    letterSpacing: 6,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  date,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 22,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
