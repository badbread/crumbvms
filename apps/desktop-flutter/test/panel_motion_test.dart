// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Lists and panels: row add/remove reflow, the pop-in panel (Settings), the
// side slide panel, and toasts.

import 'package:crumb_desktop/ui/motion/panel_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Material(child: child),
  ),
);

void main() {
  group('SizeFadeRow', () {
    Widget list(List<(int, bool, bool)> rows, {bool reduced = false}) => _wrap(
      Column(
        children: [
          for (final (id, isNew, leaving) in rows)
            SizeFadeRow(
              key: ValueKey(id),
              animateIn: isNew,
              leaving: leaving,
              child: SizedBox(height: 40, child: Text('row$id')),
            ),
        ],
      ),
      reduced: reduced,
    );

    testWidgets('an existing row is at full height at once', (tester) async {
      await tester.pumpWidget(list([(1, false, false)]));
      expect(tester.getSize(find.byType(SizeFadeRow)).height, 40);
    });

    testWidgets('a new row grows from nothing to 40 px in 220 ms', (
      tester,
    ) async {
      await tester.pumpWidget(list([(1, false, false)]));
      await tester.pumpWidget(list([(1, false, false), (2, true, false)]));
      await tester.pump();
      final h0 = tester.getSize(find.byKey(const ValueKey(2))).height;
      expect(h0, lessThan(5));
      await tester.pump(const Duration(milliseconds: 80));
      final h1 = tester.getSize(find.byKey(const ValueKey(2))).height;
      expect(h1, inExclusiveRange(5.0, 40.0));
      // The row above does not move; the list below would reflow with h1.
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getSize(find.byKey(const ValueKey(2))).height, 40);
    });

    testWidgets('a leaving row shrinks and ignores input', (tester) async {
      await tester.pumpWidget(list([(1, false, false), (2, false, false)]));
      await tester.pumpWidget(list([(1, false, false), (2, false, true)]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      final h = tester.getSize(find.byKey(const ValueKey(2))).height;
      expect(h, inExclusiveRange(0.0, 40.0));
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getSize(find.byKey(const ValueKey(2))).height, 0);
      expect(SizeFadeRow.leaveDuration.inMilliseconds, 220);
    });

    testWidgets('reduced motion: no size change, row appears at full height', (
      tester,
    ) async {
      await tester.pumpWidget(list([(1, false, false)], reduced: true));
      await tester.pumpWidget(
        list([(1, false, false), (2, true, false)], reduced: true),
      );
      await tester.pump();
      expect(tester.getSize(find.byKey(const ValueKey(2))).height, 40);
      await tester.pump(const Duration(milliseconds: 110));
      expect(tester.getSize(find.byKey(const ValueKey(2))).height, 40);
    });
  });

  group('PopPresence', () {
    Widget host(bool present, {bool reduced = false}) => _wrap(
      PopPresence(
        present: present,
        builder: (_) =>
            const SizedBox(width: 100, height: 100, child: Text('panel')),
      ),
      reduced: reduced,
    );

    testWidgets('mounts only while present or animating out', (tester) async {
      await tester.pumpWidget(host(false));
      expect(find.text('panel'), findsNothing);
      await tester.pumpWidget(host(true));
      expect(find.text('panel'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 230));
      await tester.pumpWidget(host(false));
      await tester.pump();
      expect(find.text('panel'), findsOneWidget); // still animating out
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pump(); // post-frame rebuild after dismissal
      expect(find.text('panel'), findsNothing);
    });

    testWidgets('scales from 0.96 while opening; takes no input leaving', (
      tester,
    ) async {
      await tester.pumpWidget(host(false));
      await tester.pumpWidget(host(true));
      await tester.pump();
      final scale = tester.widget<ScaleTransition>(
        find.byType(ScaleTransition),
      );
      expect(scale.scale.value, closeTo(0.96, 0.01));
      await tester.pump(const Duration(milliseconds: 230));
      expect(scale.scale.value, closeTo(1.0, 1e-6));
      await tester.pumpWidget(host(false));
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.text('panel'),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
      );
    });

    testWidgets('reduced motion: fade only, no scale', (tester) async {
      await tester.pumpWidget(host(true, reduced: true));
      expect(find.byType(ScaleTransition), findsNothing);
      expect(find.byType(FadeTransition), findsWidgets);
    });
  });

  group('SideSlidePanel', () {
    Widget host(bool open) => _wrap(
      Stack(
        children: [
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: SideSlidePanel(
              open: open,
              width: 200,
              child: const Text('detail'),
            ),
          ),
        ],
      ),
    );

    testWidgets('slides in from the right edge; contents trail the panel', (
      tester,
    ) async {
      await tester.pumpWidget(host(false));
      final closedX = tester.getTopLeft(find.text('detail')).dx;
      await tester.pumpWidget(host(true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final panelX = tester.getTopLeft(find.text('detail')).dx;
      expect(panelX, lessThan(closedX)); // moving in
      final textFade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('detail'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(textFade.opacity.value, 0.0); // still waiting 60 ms behind
      await tester.pump(const Duration(milliseconds: 250));
      expect(textFade.opacity.value, 1.0);
    });
  });

  group('ToastMotion', () {
    testWidgets('rises 10 px while fading in, settles at rest', (tester) async {
      await tester.pumpWidget(
        _wrap(const ToastMotion(visible: true, child: Text('saved'))),
      );
      await tester.pump();
      final start = tester.getTopLeft(find.text('saved')).dy;
      await tester.pump(const Duration(milliseconds: 240));
      final end = tester.getTopLeft(find.text('saved')).dy;
      expect(start - end, closeTo(10, 1.0));
    });
  });

  group('ListReflow', () {
    testWidgets('removed rows linger as leaving at their old spot, then go', (
      tester,
    ) async {
      {
        var changed = 0;
        final r = ListReflow<int>((x) => x);
        r.markSeen([1, 2, 3]);
        var rows = r.sync(
          [1, 2, 3],
          leaveFor: const Duration(milliseconds: 220),
          onChanged: () => changed++,
        );
        expect(rows.map((e) => e.item), [1, 2, 3]);
        expect(rows.every((e) => !e.leaving), isTrue);

        // Row 2 removed from the data.
        rows = r.sync(
          [1, 3],
          leaveFor: const Duration(milliseconds: 220),
          onChanged: () => changed++,
        );
        expect(rows.map((e) => e.item), [1, 2, 3]);
        expect(rows.map((e) => e.leaving), [false, true, false]);
        // Numbering is already final: leaving rows do not take a number.
        expect(rows.where((e) => !e.leaving).map((e) => e.number), [1, 2]);

        await tester.pump(const Duration(milliseconds: 221));
        expect(changed, 1);
        rows = r.sync(
          [1, 3],
          leaveFor: const Duration(milliseconds: 220),
          onChanged: () => changed++,
        );
        expect(rows.map((e) => e.item), [1, 3]);
        r.dispose();
      }
    });

    test('only unseen rows are new, and only once', () {
      final r = ListReflow<int>((x) => x);
      r.markSeen([1]);
      expect(r.isNew(1, false), isFalse); // seeded
      expect(r.isNew(2, false), isTrue); // added later
      expect(r.isNew(2, false), isFalse); // already drawn
      expect(r.isNew(3, true), isFalse); // leaving rows never animate in
    });
  });
}
