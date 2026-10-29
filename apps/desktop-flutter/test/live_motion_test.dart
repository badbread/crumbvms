// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Loading / live-state motion: REC breathing (one shared ticker, static under
// reduced motion), the motion border flash envelope, the shimmer skeleton.

import 'package:crumb_desktop/ui/motion/live_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(textDirection: TextDirection.ltr, child: child),
);

void main() {
  group('RecBreath.opacityAt', () {
    test('starts at 1, dips to 0.45 at mid-period, returns to 1', () {
      expect(RecBreath.opacityAt(Duration.zero), 1.0);
      expect(
        RecBreath.opacityAt(const Duration(milliseconds: 1100)),
        closeTo(0.45, 1e-9),
      );
      expect(RecBreath.opacityAt(RecBreath.period), closeTo(1.0, 1e-9));
    });

    test('never leaves 0.45..1 and repeats every 2.2 s', () {
      for (var ms = 0; ms < 6600; ms += 37) {
        final v = RecBreath.opacityAt(Duration(milliseconds: ms));
        expect(v, inInclusiveRange(0.45, 1.0));
        expect(
          RecBreath.opacityAt(Duration(milliseconds: ms + 2200)),
          closeTo(v, 1e-9),
        );
      }
    });
  });

  group('RecDot', () {
    testWidgets('many dots share ONE ticker that stops with the last dot', (
      tester,
    ) async {
      expect(RecBreath.instance.isTicking, isFalse);
      await tester.pumpWidget(
        _wrap(
          Row(
            children: List.generate(12, (_) => const RecDot()),
          ),
        ),
      );
      expect(RecBreath.instance.isTicking, isTrue);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(RecBreath.instance.value, lessThan(0.6));
      // All twelve dots are FadeTransitions over the same animation object.
      final fades = tester.widgetList<FadeTransition>(find.byType(FadeTransition));
      expect(fades.length, 12);
      expect(fades.every((f) => identical(f.opacity, RecBreath.instance)), isTrue);
      await tester.pumpWidget(_wrap(const SizedBox()));
      expect(RecBreath.instance.isTicking, isFalse);
    });

    testWidgets('reduced motion: solid dot, no ticker', (tester) async {
      await tester.pumpWidget(_wrap(const RecDot(), reduced: true));
      expect(find.byType(FadeTransition), findsNothing);
      expect(RecBreath.instance.isTicking, isFalse);
    });
  });

  group('motionFlashAlpha', () {
    test('zero outside the run, peak near 12 percent, fades to zero', () {
      expect(motionFlashAlpha(0), 0);
      expect(motionFlashAlpha(1), 0);
      expect(motionFlashAlpha(0.12), closeTo(1.0, 1e-6));
      expect(motionFlashAlpha(0.5), lessThan(0.5));
      expect(motionFlashAlpha(0.99), lessThan(0.05));
    });
  });

  group('MotionFlash', () {
    testWidgets('flashes on a false-to-true edge, not on mount', (tester) async {
      Widget host(bool active) =>
          _wrap(SizedBox(width: 100, height: 60, child: MotionFlash(active: active)));
      await tester.pumpWidget(host(true)); // already in motion at mount
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true)); // new event
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(MotionFlash.duration + const Duration(milliseconds: 50));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('ShimmerBox', () {
    testWidgets('sweeps while motion is allowed', (tester) async {
      await tester.pumpWidget(_wrap(const SizedBox(width: 80, height: 45, child: ShimmerBox())));
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('static under reduced motion', (tester) async {
      await tester.pumpWidget(
        _wrap(const SizedBox(width: 80, height: 45, child: ShimmerBox()), reduced: true),
      );
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
