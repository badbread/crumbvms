// SPDX-License-Identifier: AGPL-3.0-or-later
//
// State machine behind the wall's maximize / restore animation: forward,
// reverse, interrupt (retarget from the current geometry), snap, reduced motion.

import 'package:crumb_desktop/ui/motion/maximize_transition.dart';
import 'package:crumb_desktop/ui/motion/motion_tokens.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness extends StatefulWidget {
  const _Harness({required this.onReady});
  final void Function(MaximizeTransition) onReady;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final MaximizeTransition t = MaximizeTransition(vsync: this);
  @override
  void initState() {
    super.initState();
    widget.onReady(t);
  }

  @override
  void dispose() {
    t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Future<MaximizeTransition> _make(WidgetTester tester) async {
  late MaximizeTransition t;
  await tester.pumpWidget(_Harness(onReady: (x) => t = x));
  return t;
}

void main() {
  testWidgets('starts collapsed and idle', (tester) async {
    final t = await _make(tester);
    expect(t.isCollapsed, isTrue);
    expect(t.progress, 0);
    expect(t.recede, 0);
  });

  testWidgets('expand runs 280 ms and settles maximized', (tester) async {
    final t = await _make(tester);
    t.expand();
    expect(t.isAnimating, isTrue);
    expect(t.targetExpanded, isTrue);
    await tester.pump(); // start the ticker
    await tester.pump(const Duration(milliseconds: 140));
    expect(t.progress, greaterThan(0.5)); // decelerate: well past halfway
    expect(t.progress, lessThan(1.0));
    await tester.pump(const Duration(milliseconds: 141));
    expect(t.isAnimating, isFalse);
    expect(t.isExpanded, isTrue);
    expect(t.progress, 1.0);
    expect(t.recede, 1.0);
  });

  testWidgets('collapse is one tier shorter (220 ms)', (tester) async {
    final t = await _make(tester);
    t.snapExpanded();
    expect(t.isExpanded, isTrue);
    t.collapse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 219));
    expect(t.isAnimating, isTrue);
    await tester.pump(const Duration(milliseconds: 2));
    expect(t.isCollapsed, isTrue);
    expect(t.progress, 0.0);
    expect(t.recede, 0.0);
  });

  testWidgets('siblings leave over the first 80 percent and return late', (
    tester,
  ) async {
    final t = await _make(tester);
    t.expand();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 230)); // just past 80% of 280
    expect(t.recede, closeTo(1.0, 1e-6));
    await tester.pump(const Duration(milliseconds: 100));
    t.collapse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40)); // < 25% of 220 (55 ms)
    expect(t.recede, closeTo(1.0, 1e-6)); // still fully receded
    await tester.pump(const Duration(milliseconds: 200));
    expect(t.recede, 0.0);
  });

  testWidgets('interrupt mid-expand reverses from the current geometry', (
    tester,
  ) async {
    final t = await _make(tester);
    t.expand();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final before = t.progress;
    expect(before, inExclusiveRange(0.0, 1.0));
    t.collapse(); // Esc mid-animation
    // No jump: the first value after reversal equals where we were.
    expect(t.progress, closeTo(before, 1e-9));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(t.progress, lessThan(before)); // heading back
    expect(t.targetExpanded, isFalse);
    await tester.pump(const Duration(milliseconds: 300));
    expect(t.isCollapsed, isTrue);
    expect(t.progress, 0.0);
  });

  testWidgets('interrupt mid-collapse re-expands without a jump', (
    tester,
  ) async {
    final t = await _make(tester);
    t.snapExpanded();
    t.collapse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = t.progress;
    expect(mid, inExclusiveRange(0.0, 1.0));
    t.expand();
    expect(t.progress, closeTo(mid, 1e-9));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 281));
    expect(t.isExpanded, isTrue);
    expect(t.progress, 1.0);
  });

  testWidgets('toggle flips the target', (tester) async {
    final t = await _make(tester);
    expect(t.toggle(), isTrue);
    expect(t.toggle(), isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(t.isCollapsed, isTrue);
  });

  testWidgets('animate false snaps with no running animation', (tester) async {
    final t = await _make(tester);
    t.expand(animate: false);
    expect(t.isAnimating, isFalse);
    expect(t.isExpanded, isTrue);
    expect(t.progress, 1.0);
    t.collapse(animate: false);
    expect(t.isCollapsed, isTrue);
    expect(t.recede, 0.0);
  });

  testWidgets('reduced motion: geometry never travels, fade <= 100 ms', (
    tester,
  ) async {
    final t = await _make(tester);
    t.reduced = true;
    expect(t.durationFor(expanding: true), MotionTokens.reducedFadeCap);
    expect(t.durationFor(expanding: false), MotionTokens.reducedFadeCap);
    t.expand();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(t.progress, 1.0); // already at the full rect
    expect(t.paneOpacity, inExclusiveRange(0.0, 1.0)); // fading in place
    await tester.pump(const Duration(milliseconds: 80));
    expect(t.isExpanded, isTrue);
    expect(t.paneOpacity, 1.0);
  });

  testWidgets('status listener fires completed when a run ends', (
    tester,
  ) async {
    final t = await _make(tester);
    final seen = <AnimationStatus>[];
    t.addStatusListener(seen.add);
    t.expand();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(seen.last, AnimationStatus.completed);
  });
}
