// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MarqueeText: static (ellipsised) when the text fits or reduced motion is
// on, an eased ping-pong with fade masks only when it overflows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/ui/plates/marquee_text.dart';

const _style = TextStyle(fontSize: 12);
const _long = 'Charles · white Tesla Model Y from next door';

Widget _host(double width, String text, {bool reduceMotion = false}) {
  Widget child = Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: width, child: MarqueeText(text, style: _style)),
  );
  if (reduceMotion) {
    child = MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: child,
    );
  }
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('text that fits does not animate or mask', (tester) async {
    await tester.pumpWidget(_host(300, 'Charles'));
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('Charles'), findsOneWidget);
  });

  testWidgets('overflowing text scrolls under a fade mask, eased', (
    tester,
  ) async {
    await tester.pumpWidget(_host(80, _long));
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);

    final x0 = tester.getTopLeft(find.text(_long)).dx;
    // Still in the opening hold.
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getTopLeft(find.text(_long)).dx, x0);
    // Mid-leg: moved left.
    await tester.pump(const Duration(seconds: 4));
    final xMid = tester.getTopLeft(find.text(_long)).dx;
    expect(xMid, lessThan(x0 - 20));
    // It never travels past the end of the text.
    await tester.pump(const Duration(seconds: 6));
    final xEnd = tester.getTopLeft(find.text(_long)).dx;
    expect(xEnd, lessThan(xMid));
    final textW = tester.getSize(find.text(_long)).width;
    expect(x0 - xEnd, closeTo(textW - 80 + 6, 1));
    // Unmount to stop the repeating controller.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion ellipsizes instead of scrolling', (tester) async {
    await tester.pumpWidget(_host(80, _long, reduceMotion: true));
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    final t = tester.widget<Text>(find.text(_long));
    expect(t.overflow, TextOverflow.ellipsis);
  });

  test('progress holds at both ends and eases between', () {
    expect(marqueeProgress(0), 0);
    expect(marqueeProgress(0.1), 0);
    expect(marqueeProgress(0.9), 1);
    expect(marqueeProgress(1), 1);
    expect(marqueeProgress(0.5), closeTo(0.5, 0.02));
    // Ease: slower than linear near the ends.
    expect(marqueeProgress(0.25), lessThan((0.25 - 0.18) / 0.64));
  });

  test('longer overflow takes longer, within 4 to 12 s per leg', () {
    expect(marqueeLegDuration(10).inSeconds, 4);
    expect(marqueeLegDuration(1000).inSeconds, 12);
    expect(
      marqueeLegDuration(200).inMilliseconds,
      greaterThan(marqueeLegDuration(100).inMilliseconds),
    );
  });
}
