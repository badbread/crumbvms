// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression: typing in the HA badge popover's icon search box lost characters
// to global bare-key shortcuts — the owner typed "spotlights" and the leading
// "s" fired the snapshot hotkey instead of reaching the field (PR #495 live
// test).
//
// The diagnosis these tests pin down: `SnapshotHotkey` is a BUBBLE-PHASE
// `Focus.onKeyEvent` at the app root, not a `HardwareKeyboard` handler. A
// focused text field consumes the key long before it can bubble that far — so
// the only way S can fire while the operator believes they are typing is that
// the field did NOT hold focus. Hence two independent assertions per field:
//  1. tapping it actually gives it focus and the character lands in it;
//  2. every bare-key hotkey stands down while it holds focus — and fires again
//     once it does not.
//
// The suppression itself is deliberately EXPLICIT
// (`HotkeySuppressor.whileFocused`) rather than another focus-tree heuristic:
// `textInputHasFocus()` can only answer for a field that has focus, which is
// exactly the state that was in doubt.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_badge_popover.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_entity_palette.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_controller.dart';
import 'package:crumb_desktop/ui/hotkeys/ha_overlay_hotkey.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';
import 'package:crumb_desktop/ui/snapshot/snapshot_hotkey.dart';

HaLink _link({String id = 'l1', String entityId = 'light.floodlight'}) =>
    HaLink.fromJson({
      'id': id,
      'entity_id': entityId,
      'role': 'actuator',
      'sort_order': 0,
      'overlay_x': 0.4,
      'overlay_y': 0.5,
    });

HaOverlayController _host({List<HaLink>? links}) => HaOverlayController(
      api: CrumbApi(),
      session: Session(base: 'http://localhost:8080', token: 't'),
    )..links = links ?? [_link()];

/// The real app-root sandwich (main.dart): the Esc handler owns the route
/// scope's focusedChild, and the snapshot hotkey observes bubbled keys. Both
/// matter — they are the geometry the bug lived in.
Widget _appRoot({required Widget child, required VoidCallback onH}) =>
    MaterialApp(
      home: FullscreenEscHandler(
        controller: FullscreenController(),
        child: SnapshotHotkey(
          child: HaOverlayHotkey(
            onToggle: onH,
            child: Scaffold(backgroundColor: Colors.black, body: child),
          ),
        ),
      ),
    );

void main() {
  setUp(resetHotkeySuppressionForTest);

  /// The default 800x600 test view is smaller than a real maximized pane, and
  /// a popover positioned outside the view cannot be hit-tested — `tap()` then
  /// lands nowhere and the field never focuses, which looks exactly like the
  /// production bug. Give every test a realistic surface so a failure here
  /// means the app, not the harness.
  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<HaOverlayController> pumpPopover(WidgetTester tester,
      {required VoidCallback onH}) async {
    useDesktopSurface(tester);
    final host = _host();
    host.beginEditFromLoadedLinks();
    host.editor.selectItem(host.editor.items.first.id);
    await tester.pumpWidget(
      _appRoot(
        onH: onH,
        child: HaBadgePopoverLayer(
          host: host,
          videoW: 1920,
          videoH: 1080,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return host;
  }

  group('popover icon search field', () {
    testWidgets('tapping it gives it focus and characters land in it',
        (tester) async {
      final host = await pumpPopover(tester, onH: () {});
      addTearDown(host.dispose);

      // Open the inline icon grid, then focus its search box.
      await tester.tap(find.text('Auto').first);
      await tester.pumpAndSettle();
      final search = find.widgetWithText(TextField, 'Search icons…');
      expect(search, findsOneWidget, reason: 'icon grid should be expanded');

      await tester.tap(search);
      await tester.pumpAndSettle();

      // The field really does hold the keyboard now, so the gate is closed to
      // bare-key shortcuts. Asserted through the GATE rather than
      // `textInputHasFocus()`: the focus-tree heuristic cannot see this field
      // (see text_focus.dart's KNOWN LIMIT), which is the whole reason the
      // popover declares its suppression explicitly.
      expect(hotkeysSuppressed, isTrue);
      expect(hotkeyContextBlocked(), isTrue);

      await tester.enterText(search, 'spot');
      await tester.pump();
      expect(find.widgetWithText(TextField, 'spot'), findsOneWidget);
    });

    testWidgets('S does not snapshot and H does not toggle while it is focused',
        (tester) async {
      var hToggles = 0;
      final host = await pumpPopover(tester, onH: () => hToggles++);
      addTearDown(host.dispose);

      await tester.tap(find.text('Auto').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextField, 'Search icons…'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(hToggles, 0);
      expect(hotkeyContextBlocked(), isTrue);
    });

    testWidgets('hotkeys come back once the field loses focus', (tester) async {
      var hToggles = 0;
      final host = await pumpPopover(tester, onH: () => hToggles++);
      addTearDown(host.dispose);

      await tester.tap(find.text('Auto').first);
      await tester.pumpAndSettle();
      expect(hotkeyContextBlocked(), isTrue);

      // Collapse the grid again — the realistic way out, and the one that
      // disposes the field while it still holds focus. The EXPLICIT
      // suppression must be handed back even though the field never reported
      // losing focus (it was disposed holding it).
      await tester.tap(find.text('Auto').first);
      await tester.pumpAndSettle();
      expect(hotkeysSuppressed, isFalse);

      // Flutter parks focus on the nearest surviving node when the focused one
      // is disposed, which in this popover can be another text field's wrapper
      // — a legitimate reason for the gate to stay closed. Clicking away (the
      // operator's next move) is what actually releases the keyboard.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(hotkeyContextBlocked(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(hToggles, 1);
    });
  });

  group('popover label + size fields', () {
    testWidgets('the label editor takes focus and suppresses hotkeys',
        (tester) async {
      var hToggles = 0;
      final host = await pumpPopover(tester, onH: () => hToggles++);
      addTearDown(host.dispose);

      await tester.tap(find.byTooltip('Rename badge'));
      await tester.pumpAndSettle();

      expect(hotkeyContextBlocked(), isTrue);

      await tester.enterText(
        find.widgetWithText(TextField, 'Badge label'),
        'Side house',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(hToggles, 0);
      expect(host.editor.items.first, isA<HaOverlayBadgeItem>());
      expect(
        (host.editor.items.first as HaOverlayBadgeItem).labelText,
        'Side house',
      );
    });

    testWidgets('the numeric size field suppresses the number/camera hotkeys',
        (tester) async {
      final host = await pumpPopover(tester, onH: () {});
      addTearDown(host.dispose);

      // The size box is the popover's only number field.
      final size = find.descendant(
        of: find.byType(HotkeySuppressor),
        matching: find.byType(TextField),
      );
      await tester.tap(size.last);
      await tester.pumpAndSettle();
      expect(hotkeyContextBlocked(), isTrue);
    });
  });

  group('HotkeySuppressor.whileFocused', () {
    testWidgets('suppression is released when the subtree is disposed',
        (tester) async {
      useDesktopSurface(tester);
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _appRoot(
          onH: () {},
          child: HotkeySuppressor.whileFocused(
            child: TextField(focusNode: node),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Explicit requestFocus, not autofocus: the app root's own
      // `autofocus: true` already owns the route scope's focusedChild, so a
      // second autofocus request in the same scope is discarded (see
      // global_hotkeys_focus_test.dart's note on the same geometry).
      node.requestFocus();
      await tester.pumpAndSettle();
      expect(hotkeysSuppressed, isTrue);

      // Popover closes (Done) while the field still holds focus.
      await tester.pumpWidget(
        _appRoot(onH: () {}, child: const SizedBox.expand()),
      );
      await tester.pumpAndSettle();
      expect(hotkeysSuppressed, isFalse);
    });

    testWidgets('overlapping fields do not release each other', (tester) async {
      // A counter, not a flag: a focus handoff between two suppressed fields
      // must not un-suppress midway.
      final releaseA = pushHotkeySuppression();
      final releaseB = pushHotkeySuppression();
      expect(hotkeysSuppressed, isTrue);
      releaseA();
      expect(hotkeysSuppressed, isTrue);
      releaseB();
      expect(hotkeysSuppressed, isFalse);
      // Double-release is a no-op, not an underflow.
      releaseB();
      expect(hotkeysSuppressed, isFalse);
    });
  });

  group('entity palette search', () {
    testWidgets('suppresses hotkeys while focused', (tester) async {
      useDesktopSurface(tester);
      var hToggles = 0;
      await tester.pumpWidget(
        _appRoot(
          onH: () => hToggles++,
          child: HaEntityPalette(
            links: [for (var i = 0; i < 12; i++) _link(id: 'l$i')],
            placedIds: const {},
            onPick: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextField, 'Search linked entities…'));
      await tester.pumpAndSettle();

      expect(hotkeyContextBlocked(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(hToggles, 0);
    });
  });
}
