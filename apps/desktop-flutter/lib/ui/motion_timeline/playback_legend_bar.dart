// The Playback camera-color legend + timeline usage hints, rendered as a single
// horizontal strip meant to live INSIDE the app's existing gray bottom status
// bar (not as its own extra bar under the timeline). The legend swatches are
// right-clickable to recolor a camera's motion track (persisted via the
// camera-color override store); the hints advertise the non-obvious scrubber
// gestures. Extracted from motion_timeline_view.dart so the timeline strip
// itself carries no legend/hints chrome.

import 'package:flutter/material.dart';

import '../../api/models.dart';
import 'camera_colors.dart';
import 'motion_timeline_controller.dart';
import 'motion_timeline_view.dart' show kLegendCameraMax;

class PlaybackLegendBar extends StatefulWidget {
  const PlaybackLegendBar({
    super.key,
    required this.motion,
    required this.cameras,
  });

  final MotionTimelineController motion;
  final List<Camera> cameras;

  @override
  State<PlaybackLegendBar> createState() => _PlaybackLegendBarState();
}

class _PlaybackLegendBarState extends State<PlaybackLegendBar> {
  @override
  void initState() {
    super.initState();
    // Pick up persisted per-camera color overrides so the swatches (and the
    // timeline ribbons, which read the same store) show the chosen colors.
    loadCameraColorOverrides().then((_) {
      if (mounted) setState(() {});
    });
  }

  String _nameFor(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c.name;
    }
    return id.length > 6 ? id.substring(0, 6) : id;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.motion,
      builder: (context, _) {
        // Only cameras with ACTUAL activity in the current timeline window earn
        // a legend swatch: real motion (a bucket at/above the motion floor) or a
        // detection. `buckets.isNotEmpty` alone let idle cameras (all-zero
        // buckets) clutter the row — the operator asked to see only the cameras
        // that actually did something in view.
        final detectionCams = widget.motion.detections
            .map((d) => d.cameraId)
            .toSet();
        final entries = widget.motion.intensityByCam.entries
            .where(
              (e) =>
                  e.value.buckets.any((b) => b >= kMotionAbsFloor) ||
                  detectionCams.contains(e.key),
            )
            .map((e) => e.key)
            .toList()
          ..sort((a, b) => _nameFor(a).compareTo(_nameFor(b)));
        final shown = entries.take(kLegendCameraMax).toList();
        final extra = entries.length - shown.length;
        final hintColor = scheme.onSurfaceVariant.withValues(alpha: 0.55);

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final id in shown) _swatch(id, scheme),
              if (extra > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '+$extra',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (shown.isNotEmpty)
                Container(
                  width: 1,
                  height: 12,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: scheme.outlineVariant,
                ),
              // Timeline usage hints (the non-obvious right-click gestures).
              DefaultTextStyle(
                style: TextStyle(fontSize: 10.5, color: hintColor),
                child: const Row(
                  children: [
                    Text('Right-drag: export range'),
                    _HintDot(),
                    Text('Scroll: zoom'),
                    _HintDot(),
                    Text('Right-click a camera dot: recolor'),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _swatch(String id, ColorScheme scheme) {
    return Tooltip(
      message: 'Motion color for ${_nameFor(id)} — right-click to change',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onSecondaryTap: () => _pickCameraColor(id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: cameraMotionColor(id),
                    shape: BoxShape.circle,
                  ),
                ),
                Text(
                  _nameFor(id),
                  style: TextStyle(fontSize: 11, color: scheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Palette color picker (right-click a swatch). Colors already used by another
  /// camera are flagged (badge + tooltip) but stay selectable.
  Future<void> _pickCameraColor(String cameraId) async {
    final current = cameraMotionColor(cameraId);
    final overridden = hasCameraColorOverride(cameraId);
    final usedBy = <int, List<String>>{};
    for (final c in widget.cameras) {
      if (c.id == cameraId) continue;
      (usedBy[cameraMotionColor(c.id).toARGB32()] ??= []).add(c.name);
    }
    final chosen = await showDialog<Object?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Color for ${_nameFor(cameraId)}'),
        content: SizedBox(
          width: 300,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final color in kCameraPickerPalette)
                _colorSwatch(ctx, color, current, usedBy[color.toARGB32()]),
            ],
          ),
        ),
        actions: [
          if (overridden)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'reset'),
              child: const Text('Reset to default'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    if (chosen == 'reset') {
      await setCameraColorOverride(cameraId, null);
    } else if (chosen is Color) {
      await setCameraColorOverride(cameraId, chosen);
    }
    if (mounted) setState(() {});
  }

  Widget _colorSwatch(
    BuildContext ctx,
    Color color,
    Color current,
    List<String>? usedByNames,
  ) {
    final isCurrent = color == current;
    final used = usedByNames != null && usedByNames.isNotEmpty;
    final swatch = InkWell(
      onTap: () => Navigator.pop(ctx, color),
      customBorder: const CircleBorder(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isCurrent ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: used
            ? Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, size: 9, color: Colors.white),
                ),
              )
            : null,
      ),
    );
    if (!used) return swatch;
    return Tooltip(message: 'In use by ${usedByNames.join(', ')}', child: swatch);
  }
}

class _HintDot extends StatelessWidget {
  const _HintDot();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 8),
    child: Text('·'),
  );
}
