// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Plates tab: copy-the-plate and name-the-plate (issue #363).
//
// What these lock down:
//  * COPY TARGET — the plate string, never the human-readable name, even when
//    the name is what the row is showing.
//  * DISPLAY-NAME PRECEDENCE — this client reads the SERVER-resolved
//    `display_name` and never re-derives `COALESCE(plate_labels.label,
//    lpr_watchlist.label)` itself.
//  * ADMIN GATING — a non-admin is never offered the Name/Rename control,
//    because the write is admin-only server-side.
//  * DIALOG CONTRACT — cancel vs save vs "blank clears", and the copy that
//    tells the operator naming is not watchlisting/alerting.
//  * HOTKEY GATE — the Name field suppresses hardware hotkeys while focused,
//    so the pop-up's Ctrl+C cannot fire while the operator is typing a name.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';
import 'package:crumb_desktop/ui/plates/plate_name_dialog.dart';

PlateRead _read({
  String plate = '7ABC123',
  String plateRaw = '7abc 123',
  String? displayName,
}) =>
    PlateRead.fromJson({
      'id': 'r1',
      'camera_id': 'c1',
      'ts': '2026-08-01T12:00:00Z',
      'plate': plate,
      'plate_raw': plateRaw,
      'confidence': 0.9,
      'region': null,
      'source_id': 'crumb-alpr',
      'event_id': null,
      'snapshot_url': null,
      // Omitted entirely when null, so the "older server" case is genuine.
      'display_name': ?displayName,
      'bbox': null,
    });

void main() {
  setUp(resetHotkeySuppressionForTest);
  tearDown(resetHotkeySuppressionForTest);

  group('plateCopyText (copy target)', () {
    test('copies the normalized plate', () {
      expect(plateCopyText(_read()), '7ABC123');
    });

    test('copies the PLATE, not the name, when the plate is named', () {
      // The row shows "Mom's car" over the plate. Copy must still yield the
      // plate — that is what an operator pastes into a search or a report.
      final r = _read(displayName: "Mom's car");
      expect(r.displayName, "Mom's car");
      expect(plateCopyText(r), '7ABC123');
    });

    test("falls back to the provider's raw text when normalized is empty", () {
      expect(plateCopyText(_read(plate: '', plateRaw: 'unreadable')),
          'unreadable');
      expect(plateCopyText(_read(plate: '   ', plateRaw: 'unreadable')),
          'unreadable');
    });

    test('empty when the read carries neither', () {
      expect(plateCopyText(_read(plate: '', plateRaw: '')), '');
    });
  });

  group('display name comes from the server', () {
    test('display_name is parsed off the /plates DTO', () {
      expect(_read(displayName: 'Delivery van').displayName, 'Delivery van');
      expect(plateHasName(_read(displayName: 'Delivery van').displayName),
          isTrue);
    });

    test('an older server omitting display_name leaves the plate unnamed', () {
      expect(_read().displayName, isNull);
      expect(plateHasName(_read().displayName), isFalse);
    });

    test('a blank or whitespace name counts as unnamed', () {
      expect(plateHasName(''), isFalse);
      expect(plateHasName('   '), isFalse);
      expect(plateHasName("Neighbor's truck"), isTrue);
    });

    test('the watchlist DTO carries the same server-resolved name', () {
      final e = PlateWatchlistEntry.fromJson({
        'id': 'w1',
        'plate': '7ABC123',
        // A plate name (plate_labels) wins over this entry's own watchlist
        // label server-side; the client just renders what it is handed.
        'label': 'BOLO',
        'display_name': "Mom's car",
        'notify': true,
        'kind': 'watch',
        'created_at': '2026-08-01T12:00:00Z',
      });
      expect(e.label, 'BOLO');
      expect(e.displayName, "Mom's car");
    });
  });

  group('admin gating for naming', () {
    test('a non-admin is never offered the control', () {
      expect(canOfferPlateName(isAdmin: false, plate: '7ABC123'), isFalse);
    });

    test('an admin is offered it for a real plate', () {
      expect(canOfferPlateName(isAdmin: true, plate: '7ABC123'), isTrue);
    });

    test('a blank plate has no key to name, even for an admin', () {
      expect(canOfferPlateName(isAdmin: true, plate: ''), isFalse);
      expect(canOfferPlateName(isAdmin: true, plate: '  '), isFalse);
    });

    test('the action label mirrors the web console Name/Rename flip', () {
      expect(plateNameActionLabel(null), 'Name');
      expect(plateNameActionLabel(''), 'Name');
      expect(plateNameActionLabel("Mom's car"), 'Rename');
      expect(plateNameActionTooltip(null), contains('Name this plate'));
      expect(plateNameActionTooltip("Mom's car"), contains('Rename this plate'));
    });
  });

  group('showPlateNameDialog', () {
    /// Pump a host and open the dialog on it. For the tests that inspect the
    /// dialog's own UI; the result-returning tests wire their own capture,
    /// since the future only completes once the dialog is dismissed.
    Future<void> open(
      WidgetTester tester, {
      String plate = '7ABC123',
      String? currentName,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showPlateNameDialog(
              context,
              plate: plate,
              currentName: currentName,
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('says naming is not watchlisting and does not alert',
        (tester) async {
      await open(tester);
      expect(
        find.textContaining('does not add it to the watchlist'),
        findsOneWidget,
      );
      expect(find.textContaining('does not raise'), findsOneWidget);
    });

    testWidgets('titles Name for an unnamed plate, Rename for a named one',
        (tester) async {
      await open(tester);
      expect(find.text('Name plate 7ABC123'), findsOneWidget);
      // No name yet, so there is nothing to clear.
      expect(find.text('Clear name'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await open(tester, currentName: "Mom's car");
      expect(find.text('Rename plate 7ABC123'), findsOneWidget);
      expect(find.text('Clear name'), findsOneWidget);
    });

    testWidgets('prefills the field with the current name', (tester) async {
      await open(tester, currentName: "Mom's car");
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        "Mom's car",
      );
    });

    testWidgets('Cancel returns null (no write)', (tester) async {
      String? result = 'sentinel';
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showPlateNameDialog(context, plate: '7ABC123');
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('Save returns the trimmed name', (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showPlateNameDialog(context, plate: '7ABC123');
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  Delivery van  ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, 'Delivery van');
    });

    testWidgets('a blank Save clears, like the web console', (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showPlateNameDialog(
                context,
                plate: '7ABC123',
                currentName: "Mom's car",
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, '');
    });

    testWidgets('Clear name returns the clear sentinel', (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showPlateNameDialog(
                context,
                plate: '7ABC123',
                currentName: "Mom's car",
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear name'));
      await tester.pumpAndSettle();
      expect(result, '');
    });

    testWidgets('the Name field suppresses hardware hotkeys while focused',
        (tester) async {
      // The pop-up's Ctrl+C is a HardwareKeyboard handler, so it fires
      // regardless of focus; hotkeyContextBlocked() is what makes it stand
      // down. The field autofocuses, so the gate must be closed on open.
      expect(hotkeysSuppressed, isFalse);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () =>
                showPlateNameDialog(context, plate: '7ABC123'),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(hotkeysSuppressed, isTrue, reason: 'name field holds focus');
      expect(hotkeyContextBlocked(), isTrue);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(hotkeysSuppressed, isFalse, reason: 'released on dismiss');
    });
  });
}
