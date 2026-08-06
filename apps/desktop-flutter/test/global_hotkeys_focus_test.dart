// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression test for "the H hotkey does nothing on the live wall" (PR #487).
//
// The action hotkeys used to live ONLY in [GlobalHotkeysListener], a
// `Focus.onKeyEvent` node mounted deep inside the wall. Flutter dispatches a
// key event to the primary-focus node and its ANCESTORS only, and the app root
// (`FullscreenEscHandler`, `autofocus: true`, built first) permanently owns the
// route scope's `focusedChild` — a scope applies at most one autofocus
// (`_Autofocus.applyIfValid` bails once `scope.focusedChild != null`), so the
// wall listener's own `autofocus: true` is discarded and its node sits BELOW
// the focused node, off the dispatch chain. Nothing on the wall takes focus
// either (tiles are `Listener`/`GestureDetector`), so the node never gets a
// second chance.
//
// The fix routes the HA-overlay toggle through `HardwareKeyboard`, whose
// handlers run for every key event regardless of where focus sits — the same
// always-fires mechanism the clip player and the Shift-hint layer already use.
//
// These tests build the REAL app-root sandwich so the focus geometry under
// test is the one the app actually ships.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/hotkeys/ha_overlay_hotkey.dart';
import 'package:crumb_desktop/ui/snapshot/snapshot_hotkey.dart';

/// The app-root wrapper stack from main.dart: MaterialApp -> Esc handler ->
/// snapshot hotkey -> (screen).
Widget _appRoot({required Widget child}) {
  return MaterialApp(
    home: FullscreenEscHandler(
      controller: FullscreenController(),
      child: SnapshotHotkey(child: child),
    ),
  );
}

void main() {
  late HotkeyConfigStore store;

  setUpAll(() async {
    // Load the store OUTSIDE `testWidgets` — awaiting a platform-channel future
    // inside its fake-async zone hangs the test.
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    store = await HotkeyConfigStore.load();
  });

  testWidgets('a focus-chain listener under the app root never sees a key', (
    tester,
  ) async {
    var seen = 0;
    await tester.pumpWidget(
      _appRoot(
        child: GlobalHotkeysListener(
          store: store,
          cameras: const [],
          autofocus: true, // discarded — the root already owns the scope
          onToggleAudio: () => seen++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    // Not an endorsement — this pins down the geometry that broke H, and is
    // why the toggle below is a HardwareKeyboard hotkey instead.
    expect(seen, 0);
  });

  testWidgets('HaOverlayHotkey fires H no matter where focus sits', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _appRoot(
        child: HaOverlayHotkey(
          onToggle: () => toggles++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(toggles, 1);
  });

  testWidgets('HaOverlayHotkey stands down while a text field has focus', (
    tester,
  ) async {
    var toggles = 0;
    final controller = TextEditingController();
    await tester.pumpWidget(
      _appRoot(
        child: HaOverlayHotkey(
          onToggle: () => toggles++,
          child: Material(
            child: TextField(controller: controller, autofocus: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(toggles, 0);
  });

  testWidgets('HaOverlayHotkey unregisters when it leaves the tree', (
    tester,
  ) async {
    var toggles = 0;
    await tester.pumpWidget(
      _appRoot(
        child: HaOverlayHotkey(
          onToggle: () => toggles++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(toggles, 1);

    // Leaving the Live tab tears the wall (and this widget) down.
    await tester.pumpWidget(_appRoot(child: const SizedBox.expand()));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(toggles, 1);
  });
}
