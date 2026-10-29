// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The shared press / hover / focus rules applied through the theme.

import 'package:crumb_desktop/ui/motion/crumb_interaction_theme.dart';
import 'package:crumb_desktop/ui/motion/crumb_ripple.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  theme: applyCrumbInteraction(ThemeData.dark(useMaterial3: true)),
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: c!,
  ),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('theme installs the Crumb ripple and hover/focus colours', () {
    final t = applyCrumbInteraction(ThemeData.dark(useMaterial3: true));
    expect(t.splashFactory, same(CrumbRipple.splashFactory));
    expect(t.hoverColor.a, lessThan(0.1));
    expect(t.focusColor.a, greaterThan(t.hoverColor.a));
    expect(t.expansionTileTheme.expansionAnimationStyle?.duration,
        const Duration(milliseconds: 220));
  });

  testWidgets('a button settles to 0.97 on press and back on release', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(FilledButton(onPressed: () => taps++, child: const Text('Go'))),
    );
    double scaleOf() => tester
        .widget<AnimatedScale>(find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(AnimatedScale),
        ))
        .scale;
    expect(scaleOf(), 1.0);
    final g = await tester.startGesture(tester.getCenter(find.text('Go')));
    await tester.pump();
    expect(scaleOf(), kPressScale);
    await g.up();
    await tester.pump();
    expect(scaleOf(), 1.0);
    // Pressing never delays the action.
    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion: no press scale, no travelling ripple', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        FilledButton(onPressed: () {}, child: const Text('Go')),
        reduced: true,
      ),
    );
    final g = await tester.startGesture(tester.getCenter(find.text('Go')));
    await tester.pump();
    final s = tester
        .widget<AnimatedScale>(find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(AnimatedScale),
        ))
        .scale;
    expect(s, 1.0);
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('keyboard focus draws a 2 px ring', (tester) async {
    await tester.pumpWidget(
      _app(
        OutlinedButton(
          onPressed: () {},
          child: const Text('Tab to me'),
        ),
      ),
    );
    // Keyboard traversal marks the focus as visible ("traditional").
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(OutlinedButton),
        matching: find.byType(Material),
      ).first,
    );
    final shape = material.shape as OutlinedBorder;
    expect(shape.side.width, 2);
  });
}
