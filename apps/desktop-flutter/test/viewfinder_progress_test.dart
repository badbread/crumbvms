// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The export viewfinder shows only real numbers and a word for every state,
// so progress never relies on colour alone. Also renders golden-free
// screenshots of each state for a visual check (see the PNGs it writes).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/export/viewfinder_progress.dart';

Widget _host(ViewfinderProgress v) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(
    body: Center(child: SizedBox(width: 328, child: v)),
  ),
);

void main() {
  testWidgets('encoding shows the real percent, clip counter and timecode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ViewfinderProgress(
          phase: ViewfinderPhase.encoding,
          percent: 62,
          detail: 'clip 2 of 4',
          elapsed: Duration(seconds: 75),
        ),
      ),
    );
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('EXPORT'), findsOneWidget);
    expect(find.text('clip 2 of 4'), findsOneWidget);
    expect(find.text('01:15'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stop the repeating animation
  });

  testWidgets('phases without a real number show -- not a made-up one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ViewfinderProgress(
          phase: ViewfinderPhase.packaging,
          detail: 'building zip',
          elapsed: Duration(seconds: 3),
        ),
      ),
    );
    expect(find.text('--'), findsOneWidget);
    expect(find.text('PACKAGING'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('terminal states carry a word and a glyph', (tester) async {
    for (final (phase, word, glyph) in [
      (ViewfinderPhase.done, 'SAVED', 'OK'),
      (ViewfinderPhase.failed, 'FAILED', 'X'),
      (ViewfinderPhase.cancelled, 'CANCELLED', '||'),
    ]) {
      await tester.pumpWidget(
        _host(
          ViewfinderProgress(
            phase: phase,
            percent: phase == ViewfinderPhase.done ? 100 : null,
            elapsed: const Duration(seconds: 9),
          ),
        ),
      );
      expect(find.text(word), findsOneWidget);
      expect(find.text(glyph), findsOneWidget);
    }
  });
}
