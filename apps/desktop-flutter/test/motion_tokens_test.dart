// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The motion system's constants and its reduced-motion scaling.

import 'package:crumb_desktop/ui/motion/motion_tokens.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MotionTokens', () {
    test('duration tiers are 90 / 150 / 220 / 280 ms and nothing is longer', () {
      expect(MotionTokens.d1.inMilliseconds, 90);
      expect(MotionTokens.d2.inMilliseconds, 150);
      expect(MotionTokens.d3.inMilliseconds, 220);
      expect(MotionTokens.d4.inMilliseconds, 280);
    });

    test('curves match the prototype and never overshoot', () {
      expect(MotionTokens.standard, const Cubic(0.2, 0.0, 0.0, 1.0));
      expect(MotionTokens.decelerate, const Cubic(0.05, 0.7, 0.1, 1.0));
      expect(MotionTokens.accelerate, const Cubic(0.3, 0.0, 0.8, 0.15));
      for (final c in [
        MotionTokens.standard,
        MotionTokens.decelerate,
        MotionTokens.accelerate,
      ]) {
        for (var i = 0; i <= 100; i++) {
          final v = c.transform(i / 100);
          expect(v, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('reverse is one tier shorter', () {
      expect(MotionTokens.reverseOf(MotionTokens.d4), MotionTokens.d3);
      expect(MotionTokens.reverseOf(MotionTokens.d3), MotionTokens.d2);
      expect(MotionTokens.reverseOf(MotionTokens.d2), MotionTokens.d1);
      expect(MotionTokens.reverseOf(MotionTokens.d1), MotionTokens.d1);
    });

    test('reduced motion caps every duration at 100 ms', () {
      for (final d in [
        MotionTokens.d1,
        MotionTokens.d2,
        MotionTokens.d3,
        MotionTokens.d4,
      ]) {
        expect(
          MotionTokens.scaled(d, reduced: true),
          lessThanOrEqualTo(MotionTokens.reducedFadeCap),
        );
        expect(MotionTokens.scaled(d, reduced: false), d);
      }
      expect(
        MotionTokens.scaled(MotionTokens.d1, reduced: true),
        MotionTokens.d1,
      );
    });
  });

  group('MotionPrefsScope', () {
    Widget probe(void Function(bool) report) => MotionPrefsScope(
      child: Builder(
        builder: (context) {
          report(MotionTokens.reduced(context));
          return const SizedBox();
        },
      ),
    );

    tearDown(() => MotionPrefs.reduceMotion.value = false);

    testWidgets('in-app option folds into MediaQuery.disableAnimations', (
      tester,
    ) async {
      var seen = false;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: probe((v) => seen = v),
        ),
      );
      expect(seen, isFalse);
      MotionPrefs.reduceMotion.value = true;
      await tester.pump();
      expect(seen, isTrue);
    });

    testWidgets('the OS flag alone is honoured', (tester) async {
      var seen = false;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: probe((v) => seen = v),
        ),
      );
      expect(seen, isTrue);
    });
  });
}
