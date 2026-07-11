// Visual pieces for the live-status-poll feature: the per-tile REC/motion
// dots + detection glyph row, and the connection-lost banner. Pure display
// widgets — all state comes from `LiveStatusController` (see
// live_status_controller.dart); wire them up with an `AnimatedBuilder` /
// `ListenableBuilder` listening to the controller.

import 'package:flutter/material.dart';

import 'detection_icons.dart';

/// Small top-strip badge row for one camera tile: a REC dot (active when
/// `recording`), a MOTION dot (active when `recentMotion` and there are no
/// specific detection glyphs — specific icons take precedence over the
/// generic motion runner, matching app.js's tile-strip behavior), and the
/// active detection glyphs.
class LiveStatusBadgeRow extends StatelessWidget {
  const LiveStatusBadgeRow({
    super.key,
    required this.recording,
    required this.recentMotion,
    required this.detectionKeys,
  });

  final bool recording;
  final bool recentMotion;
  final Set<String> detectionKeys;

  @override
  Widget build(BuildContext context) {
    final showGenericMotion = recentMotion && detectionKeys.isEmpty;
    if (!recording && !showGenericMotion && detectionKeys.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Recording is just a red dot (no "REC" label), matching the old client.
          if (recording) const _Dot(color: Colors.redAccent),
          if (recording && showGenericMotion) const SizedBox(width: 8),
          if (showGenericMotion) ...[
            const _Dot(color: Colors.amber),
            const SizedBox(width: 4),
            const Text('MOTION', style: _labelStyle),
          ],
          if (detectionKeys.isNotEmpty) ...[
            if (recording || showGenericMotion) const SizedBox(width: 8),
            for (final key in detectionKeys)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _DetectionGlyph(iconKey: key),
              ),
          ],
        ],
      ),
    );
  }
}

const _labelStyle = TextStyle(
  color: Colors.white,
  fontSize: 10,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.3,
);

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}

class _DetectionGlyph extends StatelessWidget {
  const _DetectionGlyph({required this.iconKey});
  final String iconKey;

  @override
  Widget build(BuildContext context) {
    final spec = detectionIconFor(iconKey);
    return Tooltip(
      message: iconKey,
      child: Icon(spec.icon, size: 14, color: spec.color),
    );
  }
}

/// Persistent banner shown when the live status poller has failed 3+
/// consecutive times — "the wall looks live but its indicators are stale" is
/// the dangerous failure mode for a security wall, so this is deliberately
/// hard to miss. Renders nothing when `show` is false.
class ConnLostBanner extends StatelessWidget {
  const ConnLostBanner({super.key, required this.show});

  final bool show;

  @override
  Widget build(BuildContext context) {
    // Returns a plain bar (NOT a Positioned) so the caller controls placement —
    // a widget must not assume it lives directly inside a Stack.
    if (!show) return const SizedBox.shrink();
    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8),
        color: Colors.red.shade900.withValues(alpha: 0.9),
        alignment: Alignment.center,
        child: const Text(
          '⚠ Connection lost — indicators may be stale',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
