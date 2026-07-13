// Dumb render layer over [GaplessSegmentPaneController] — just the video
// texture plus "no footage" / error state. All the gapless boundary/prefetch
// logic lives in the controller; this widget only repaints when it changes.

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'gapless_segment_pane_controller.dart';

class GaplessSegmentPane extends StatelessWidget {
  const GaplessSegmentPane({super.key, required this.controller});

  final GaplessSegmentPaneController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(
                controller: controller.videoController,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              ),
              if (controller.noFootage)
                const Center(
                  child: Text(
                    'No recording at this time',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              if (controller.error != null)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      controller.error!,
                      style: TextStyle(
                        color: Colors.red.shade300,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
