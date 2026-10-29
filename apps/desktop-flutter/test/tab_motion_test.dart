// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Tab switching: which transition a switch gets (never keep a video-heavy tab
// alive for a fade), and the widgets that run it.

import 'package:crumb_desktop/ui/motion/tab_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors the app: 0 Live, 1 Playback, 2 Clips, 3 Export, 4 LPR, displayed as
// Live, Playback, Clips, LPR, Export.
const _display = [0, 1, 2, 4, 3];
int _order(int tab) => _display.indexOf(tab);
bool _video(int tab) => tab == 0 || tab == 1;

TabSwitchPlan _plan(int from, int to, {bool reduced = false}) => planTabSwitch(
  from: from,
  to: to,
  order: _order,
  isVideoHeavy: _video,
  reduced: reduced,
);

void main() {
  group('planTabSwitch', () {
    test('leaving a video-heavy tab never keeps it alive', () {
      expect(_plan(0, 1).keepOutgoing, isFalse); // Live -> Playback
      expect(_plan(1, 0).keepOutgoing, isFalse); // Playback -> Live
      expect(_plan(0, 2).keepOutgoing, isFalse); // Live -> Clips
      expect(_plan(1, 3).keepOutgoing, isFalse); // Playback -> Export
    });

    test('leaving a light tab fades it out under the incoming one', () {
      expect(_plan(2, 0).keepOutgoing, isTrue); // Clips -> Live
      expect(_plan(3, 4).keepOutgoing, isTrue); // Export -> LPR
      expect(_plan(4, 2).keepOutgoing, isTrue);
    });

    test('direction follows the on-screen order, not the numeric index', () {
      expect(_plan(2, 4).direction, 1); // Clips -> LPR is to the right
      expect(_plan(4, 3).direction, 1); // LPR (shown 4th) -> Export (5th)
      expect(_plan(3, 4).direction, -1); // Export -> LPR is to the left
      expect(_plan(1, 0).direction, -1);
      expect(_plan(0, 1).slide, 6);
      expect(_plan(1, 0).slide, -6);
    });

    test('220 ms normally; reduced: no slide and 100 ms', () {
      expect(_plan(2, 3).duration, const Duration(milliseconds: 220));
      final r = _plan(2, 3, reduced: true);
      expect(r.slide, 0);
      expect(r.duration, const Duration(milliseconds: 100));
    });
  });

  group('TabContentTransition', () {
    // Each "page" counts how many times it was initState'd / disposed so we can
    // see exactly which tabs stay mounted.
    final log = <String>[];

    Widget page(String name) => _Probe(key: ValueKey(name), name: name, log: log);

    Widget host(int index, {bool reduced = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: TabContentTransition(
          index: index,
          order: _order,
          isVideoHeavy: _video,
          child: page('tab$index'),
        ),
      ),
    );

    setUp(log.clear);

    testWidgets('video-heavy outgoing tab is disposed immediately', (
      tester,
    ) async {
      await tester.pumpWidget(host(0));
      expect(find.text('tab0'), findsOneWidget);
      await tester.pumpWidget(host(1)); // Live -> Playback
      // Same frame: Live is gone, only Playback exists (fading in).
      expect(find.text('tab0'), findsNothing);
      expect(find.text('tab1'), findsOneWidget);
      expect(log, contains('dispose tab0'));
      await tester.pumpAndSettle();
      expect(find.text('tab1'), findsOneWidget);
    });

    testWidgets('light outgoing tab fades under the incoming then goes', (
      tester,
    ) async {
      await tester.pumpWidget(host(2));
      await tester.pumpWidget(host(3)); // Clips -> Export
      expect(find.text('tab2'), findsOneWidget); // still fading out
      expect(find.text('tab3'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('tab2'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('tab2'), findsNothing);
      expect(find.text('tab3'), findsOneWidget);
      // The incoming page's State was never rebuilt from scratch mid-fade.
      expect(log.where((e) => e == 'init tab3').length, 1);
    });

    testWidgets('outgoing never takes input; incoming does immediately', (
      tester,
    ) async {
      var taps = 0;
      Widget h(int i) => MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: TabContentTransition(
            index: i,
            order: _order,
            isVideoHeavy: _video,
            child: GestureDetector(
              key: ValueKey('t$i'),
              onTap: () => i == 3 ? taps++ : taps += 100,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpWidget(h(2));
      await tester.pumpWidget(h(3));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tapAt(const Offset(20, 20)); // mid-transition
      expect(taps, 1); // only the incoming page received it
    });

    testWidgets('reduced motion still lands on the new tab within 100 ms', (
      tester,
    ) async {
      await tester.pumpWidget(host(2, reduced: true));
      await tester.pumpWidget(host(3, reduced: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 101));
      expect(find.text('tab2'), findsNothing);
      expect(find.text('tab3'), findsOneWidget);
    });
  });

  group('SlidingUnderlineRow', () {
    Widget tabs(int selected, Color color) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SlidingUnderlineRow(
            selected: selected,
            color: color,
            children: const [
              SizedBox(width: 60, height: 40),
              SizedBox(width: 100, height: 40),
              SizedBox(width: 80, height: 40),
            ],
          ),
        ),
      ),
    );

    Rect underline(WidgetTester tester) {
      final c = tester.widgetList<ColoredBox>(find.byType(ColoredBox)).last;
      final f = find.byWidget(c);
      return tester.getRect(f);
    }

    testWidgets('slides and resizes to the new tab over 220 ms', (tester) async {
      await tester.pumpWidget(tabs(0, Colors.orange));
      await tester.pump();
      await tester.pump();
      expect(underline(tester).width, 60);
      await tester.pumpWidget(tabs(1, Colors.cyan));
      await tester.pump(); // post-frame measure
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final mid = underline(tester);
      expect(mid.left, inExclusiveRange(0.0, 60.0));
      expect(mid.width, inExclusiveRange(60.0, 100.0));
      await tester.pumpAndSettle();
      final end = underline(tester);
      expect(end.left, 60);
      expect(end.width, 100);
    });
  });
}

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.name, required this.log});
  final String name;
  final List<String> log;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.log.add('init ${widget.name}');
  }

  @override
  void dispose() {
    widget.log.add('dispose ${widget.name}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.name);
}
