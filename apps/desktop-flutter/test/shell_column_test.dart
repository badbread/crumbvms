// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Entering fullscreen hides the shell chrome. The tab body (the live wall and
// every mpv player under it) must keep its State when that happens.

import 'package:crumb_desktop/ui/shell_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe extends StatefulWidget {
  const _Probe({required this.log});
  final List<String> log;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.log.add('init');
  }

  @override
  void dispose() {
    widget.log.add('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Widget _shell(bool hidden, List<String> log, {int topCount = 3}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ShellColumn(
      chromeHidden: hidden,
      top: () => [for (var i = 0; i < topCount; i++) const SizedBox(height: 10)],
      body: _Probe(log: log),
      bottom: const SizedBox(height: 10),
    ),
  );
}

void main() {
  testWidgets('entering and leaving fullscreen keeps the body State', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_shell(false, log));
    final state = tester.state(find.byType(_Probe));

    await tester.pumpWidget(_shell(true, log)); // enter fullscreen
    expect(tester.state(find.byType(_Probe)), same(state));

    await tester.pumpWidget(_shell(false, log)); // leave fullscreen
    expect(tester.state(find.byType(_Probe)), same(state));

    expect(log, ['init']); // never re-initialised, never disposed
  });

  testWidgets('chrome is dropped while hidden and the body fills the space', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_shell(false, log));
    expect(tester.getSize(find.byType(_Probe)).height, 600 - 30 - 10);

    await tester.pumpWidget(_shell(true, log));
    expect(tester.getSize(find.byType(_Probe)).height, 600);
  });

  testWidgets('a changing chrome count (e.g. the views row) keeps the body', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_shell(false, log, topCount: 3));
    await tester.pumpWidget(_shell(false, log, topCount: 2));
    await tester.pumpWidget(_shell(true, log, topCount: 2));
    expect(log, ['init']);
  });
}
