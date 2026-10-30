// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Rebuild hygiene for the Playback screen: the timeline playhead moves every
// 100 ms while playing and at pointer rate while dragging. PlaybackScreen used
// to setState on each of those notifications just to refresh the transport
// clock and the export-selection bar, rebuilding every pane's Video widget at
// tick rate. Those two now listen to the timeline themselves (the clock via
// [PlaybackTickText], the selection bar via a ListenableBuilder), so the pane
// area above them is built once.
//
// The real panes wrap native mpv players and can't be built headlessly, so a
// build-counting stand-in takes their place in a tree shaped like the screen's
// Column: panes, then the clock, then the selection slot.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/ui/playback/playback_tick_text.dart';
import 'package:crumb_desktop/ui/playback/playback_timeline_controller.dart';

class _CountingPane extends StatelessWidget {
  const _CountingPane(this.onBuild);
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(height: 100, child: ColoredBox(color: Colors.black));
  }
}

String _label(PlaybackTimelineController t) =>
    't=${t.playhead.millisecondsSinceEpoch}';

void main() {
  final base = DateTime.utc(2026, 10, 1, 12);

  Future<(PlaybackTimelineController, int Function())> pumpScreen(
    WidgetTester tester,
  ) async {
    final timeline = PlaybackTimelineController(initialPlayhead: base);
    addTearDown(timeline.dispose);
    var paneBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              _CountingPane(() => paneBuilds++),
              PlaybackTickText(
                listenable: timeline,
                text: () => _label(timeline),
              ),
              ListenableBuilder(
                listenable: timeline,
                builder: (context, _) => timeline.hasSelection
                    ? const Text('selection')
                    : const SizedBox.shrink(),
              ),
              // Scrub surface: a drag moves the playhead per pointer event,
              // like MotionTimelineView's pan handler.
              GestureDetector(
                key: const Key('scrub'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => timeline.setPlayhead(
                  timeline.playhead.add(
                    Duration(milliseconds: (d.delta.dx * 1000).round()),
                  ),
                  now: base.add(const Duration(days: 1)),
                ),
                child: const SizedBox(height: 40, width: 400),
              ),
            ],
          ),
        ),
      ),
    );
    return (timeline, () => paneBuilds);
  }

  testWidgets('play ticks update the clock without rebuilding panes', (
    tester,
  ) async {
    final (timeline, paneBuilds) = await pumpScreen(tester);
    expect(paneBuilds(), 1);

    final now = base.add(const Duration(days: 1));
    for (var i = 1; i <= 50; i++) {
      timeline.setPlayhead(base.add(Duration(milliseconds: 100 * i)), now: now);
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(paneBuilds(), 1);
    expect(
      find.text(
        't=${base.add(const Duration(seconds: 5)).millisecondsSinceEpoch}',
      ),
      findsOneWidget,
    );
  });

  testWidgets('scrubber drag moves the playhead without rebuilding panes', (
    tester,
  ) async {
    final (timeline, paneBuilds) = await pumpScreen(tester);
    final before = timeline.playhead;

    await tester.drag(find.byKey(const Key('scrub')), const Offset(200, 0));
    await tester.pump();

    expect(timeline.playhead.isAfter(before), isTrue);
    expect(find.text(_label(timeline)), findsOneWidget);
    expect(paneBuilds(), 1);
  });

  testWidgets('export selection bar follows the timeline on its own', (
    tester,
  ) async {
    final (timeline, paneBuilds) = await pumpScreen(tester);
    expect(find.text('selection'), findsNothing);

    final ms = base.millisecondsSinceEpoch;
    timeline.setSelection(ms, ms + 30000);
    await tester.pump();
    expect(find.text('selection'), findsOneWidget);

    timeline.clearSelection();
    await tester.pump();
    expect(find.text('selection'), findsNothing);
    expect(paneBuilds(), 1);
  });
}
