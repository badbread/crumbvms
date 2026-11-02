// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Issue #705: the time used to hide behind a second dialog that only opened
// after OK on the date. One dialog now shows both fields.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/date_time_picker_dialog.dart';

void main() {
  test('dates: ISO and US forms, impossible dates rejected', () {
    expect(parsePickerDate('2026-11-01'), DateTime(2026, 11, 1));
    expect(parsePickerDate(' 2026/3/7 '), DateTime(2026, 3, 7));
    expect(parsePickerDate('11/01/2026'), DateTime(2026, 11, 1));
    expect(parsePickerDate('2026-02-31'), isNull);
    expect(parsePickerDate('2026-13-01'), isNull);
    expect(parsePickerDate('yesterday'), isNull);
  });

  test('times: 24-hour, optional seconds, 12-hour with am/pm', () {
    expect(parsePickerTime('14:30'), (14, 30, 0));
    expect(parsePickerTime('09:05:42'), (9, 5, 42));
    expect(parsePickerTime('2:30 pm'), (14, 30, 0));
    expect(parsePickerTime('2:30PM'), (14, 30, 0));
    expect(parsePickerTime('12:15 am'), (0, 15, 0));
    expect(parsePickerTime('12 pm'), (12, 0, 0));
    expect(parsePickerTime('7a'), (7, 0, 0));
    expect(parsePickerTime('24:00'), isNull);
    expect(parsePickerTime('13:00 pm'), isNull);
    expect(parsePickerTime('14'), isNull);
    expect(parsePickerTime('10:61'), isNull);
  });

  test('formatting round-trips through the parsers', () {
    final d = DateTime(2026, 1, 9, 7, 3, 4);
    expect(fmtPickerDate(d), '2026-01-09');
    expect(fmtPickerTime(d), '07:03:04');
    expect(parsePickerDate(fmtPickerDate(d)), DateTime(2026, 1, 9));
    expect(parsePickerTime(fmtPickerTime(d)), (7, 3, 4));
  });

  Future<void> open(WidgetTester tester, DateTime initial) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await showDateTimePickerDialog(
              context,
              initial: initial,
              firstDate: DateTime(2021),
              lastDate: DateTime(2026, 11, 1),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('date and time are both on screen at once', (tester) async {
    await open(tester, DateTime(2026, 11, 1, 18, 45, 10));
    expect(find.text('2026-11-01'), findsOneWidget);
    expect(find.text('18:45:10'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('typing a time and pressing Enter returns date + time',
      (tester) async {
    DateTime? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            got = await showDateTimePickerDialog(
              context,
              initial: DateTime(2026, 11, 1, 18, 45, 10),
              firstDate: DateTime(2021),
              lastDate: DateTime(2026, 11, 1),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dtp-date')), '10/31/2026');
    await tester.enterText(find.byKey(const Key('dtp-time')), '9:15 pm');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(got, DateTime(2026, 10, 31, 21, 15, 0));
    expect(find.byKey(const Key('dtp-time')), findsNothing);
  });

  testWidgets('bad input stays open with a message', (tester) async {
    await open(tester, DateTime(2026, 11, 1, 18, 45, 10));
    await tester.enterText(find.byKey(const Key('dtp-date')), '2026-11-02');
    await tester.enterText(find.byKey(const Key('dtp-time')), '25:00');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('The latest date is 2026-11-01'), findsOneWidget);
    expect(find.textContaining('24-hour'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
