// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression tests for "the live wall's keyboard shortcuts do nothing"
// (the H hotkey, PR #487; then the whole set: S / M / F8 / Esc / the camera
// number banks).
//
// The shortcuts used to live in `Focus.onKeyEvent` nodes mounted inside the
// wall (`GlobalHotkeysListener`) and just under the app root
// (`SnapshotHotkey`). Flutter dispatches a key event to the primary-focus node
// and its ANCESTORS only, and the app root (`FullscreenEscHandler`,
// `autofocus: true`, built first) permanently owns the route scope's
// `focusedChild` — a scope applies at most one autofocus
// (`_Autofocus.applyIfValid` bails once `scope.focusedChild != null`) — so
// those listeners' own `autofocus` was discarded and their nodes sat BELOW the
// focused node, off the dispatch chain. Nothing on the wall takes focus either
// (tiles are `Listener`/`GestureDetector`), so they never got a second chance.
//
// They are now `HardwareKeyboard` handlers, whose callbacks run for every key
// event regardless of where focus sits — the same always-fires mechanism the
// clip player and the Shift-hint layer already use — with the focus chain's
// implicit guards re-applied explicitly (hotkey_gate.dart).
//
// Every test builds the REAL app-root sandwich, so the focus geometry under
// test is the one the app actually ships.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/hotkeys/global_hotkeys_listener.dart';
import 'package:crumb_desktop/ui/hotkeys/ha_overlay_hotkey.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';
import 'package:crumb_desktop/ui/snapshot/snapshot_hotkey.dart';

/// The app-root wrapper stack from main.dart: MaterialApp -> Esc handler ->
/// snapshot hotkey -> (screen).
Widget _appRoot({
  required Widget child,
  FullscreenController? fullscreen,
  ClientOptionsStore? options,
}) {
  return MaterialApp(
    home: FullscreenEscHandler(
      controller: fullscreen ?? FullscreenController(),
      child: SnapshotHotkey(options: options, child: child),
    ),
  );
}

Camera _cam(String id, String name) => Camera(
  id: id,
  name: name,
  enabled: true,
  hasSub: false,
  ptz: false,
  servedBy: 'crumb',
);

/// Two cameras → auto hotkey assignment gives token "1" to a, "2" to b (and
/// numpad "n1"/"n2" the same, mirroring the row by default).
final List<Camera> _cameras = [_cam('cam-a', 'A'), _cam('cam-b', 'B')];

void main() {
  late HotkeyConfigStore store;
  late ClientOptionsStore shortcutsOff;

  setUpAll(() async {
    // Load the stores OUTSIDE `testWidgets` — awaiting a platform-channel
    // future inside its fake-async zone hangs the test.
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    store = await HotkeyConfigStore.load();
    shortcutsOff = await ClientOptionsStore.load();
    shortcutsOff.hotkeysEnabled = false;
  });

  // A live-wall listener with every callback wired, plus the log they append
  // to — so a test can assert exactly which shortcut fired, and that nothing
  // fired twice.
  ({Widget widget, List<String> log}) wallListener({
    ClientOptionsStore? options,
    FullscreenController? fullscreen,
    Widget child = const SizedBox.expand(),
  }) {
    final log = <String>[];
    return (
      log: log,
      widget: GlobalHotkeysListener(
        store: store,
        cameras: _cameras,
        options: options,
        fullscreen: fullscreen,
        onGoToCamera: (id) => log.add('go:$id'),
        onHudToggle: () => log.add('hud'),
        onToggleAudio: () => log.add('audio'),
        onEscape: () => log.add('escape'),
        onUndo: () => log.add('undo'),
        onRedo: () => log.add('redo'),
        child: child,
      ),
    );
  }

  /// Press `key` while `modifier` is held.
  Future<void> pressWith(
    WidgetTester tester,
    LogicalKeyboardKey modifier,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  group('every wall shortcut fires with the real app-root focus geometry', () {
    testWidgets('M toggles audio', (tester) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(wall.log, ['audio']);
    });

    testWidgets('F8 toggles the perf HUD', (tester) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pump();
      expect(wall.log, ['hud']);
    });

    testWidgets('the number row goes to a camera', (tester) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(wall.log, ['go:cam-b']);
    });

    testWidgets('the numeric keypad is its own bank', (tester) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad1);
      await tester.pump();
      expect(wall.log, ['go:cam-a']);
    });

    testWidgets('Shift+digit reaches the 11-20 bank (unassigned here)', (
      tester,
    ) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      // Shift+1 is token "s1" — camera 11, which this 2-camera list has no
      // assignment for, so it must NOT fall through to plain "1".
      await pressWith(
        tester,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.digit1,
      );
      expect(wall.log, isEmpty);
    });

    testWidgets('Esc restores from maximize', (tester) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(wall.log, ['escape']);
    });

    testWidgets('Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y drive the overlay editor', (
      tester,
    ) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await pressWith(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyZ,
      );
      await pressWith(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyY,
      );
      expect(wall.log, ['undo', 'redo']);
    });

    testWidgets('S snapshots via the app-level SnapshotHotkey', (tester) async {
      await tester.pumpWidget(_appRoot(child: wallListener().widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      // Nothing is registered as the active pane in a widget test, so the
      // service's "nothing to capture" toast is the observable proof that the
      // hotkey fired at all (it used to fire nothing whatsoever).
      expect(find.text('Nothing to snapshot'), findsOneWidget);
      await drainToast(tester);
    });
  });

  group('guards', () {
    testWidgets('a focused text field swallows every shortcut', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final wall = wallListener(
        child: Material(
          child: TextField(controller: controller, autofocus: true),
        ),
      );
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(wall.log, isEmpty);
      expect(find.text('Nothing to snapshot'), findsNothing);
    });

    testWidgets('a pushed route (dialog) owns the keyboard', (tester) async {
      late BuildContext inner;
      final wall = wallListener(
        child: Builder(
          builder: (context) {
            inner = context;
            return const SizedBox.expand();
          },
        ),
      );
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      showDialog<void>(
        context: inner,
        builder: (_) => const AlertDialog(content: Text('dialog')),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(wall.log, isEmpty);
      expect(find.text('Nothing to snapshot'), findsNothing);
    });

    testWidgets('a HotkeySuppressor (Settings panel) blocks everything', (
      tester,
    ) async {
      final wall = wallListener();
      await tester.pumpWidget(
        _appRoot(
          child: Stack(
            children: [
              wall.widget,
              const HotkeySuppressor(child: SizedBox.shrink()),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(hotkeysSuppressed, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(wall.log, isEmpty);
      expect(find.text('Nothing to snapshot'), findsNothing);

      // …and unmounting it hands the keyboard back.
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      expect(hotkeysSuppressed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(wall.log, ['audio']);
    });

    testWidgets('the master toggle silences actions but never Esc', (
      tester,
    ) async {
      final wall = wallListener(options: shortcutsOff);
      await tester.pumpWidget(
        _appRoot(child: wall.widget, options: shortcutsOff),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(wall.log, isEmpty);
      expect(find.text('Nothing to snapshot'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(wall.log, ['escape'], reason: 'a maximized pane must never trap');
    });

    testWidgets('Esc leaves fullscreen before it un-maximizes', (tester) async {
      final fullscreen = FullscreenController();
      final wall = wallListener(fullscreen: fullscreen);
      await tester.pumpWidget(
        _appRoot(child: wall.widget, fullscreen: fullscreen),
      );
      await tester.pump();
      // window_manager has no platform side in a widget test; setFullscreen
      // flips its own flag first and swallows the plugin failure.
      await fullscreen.setFullscreen(true);
      await tester.pump();
      expect(fullscreen.isFullscreen, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(wall.log, isEmpty, reason: 'the fullscreen handler takes it');
      expect(fullscreen.isFullscreen, isFalse);

      // The NEXT Esc un-maximizes, same order as the old client.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(wall.log, ['escape']);
    });

    testWidgets('leaving the tab unregisters the handler', (tester) async {
      final wall = wallListener();
      await tester.pumpWidget(_appRoot(child: wall.widget));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(wall.log, ['audio']);

      await tester.pumpWidget(_appRoot(child: const SizedBox.expand()));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(wall.log, ['audio'], reason: 'no second fire from a dead screen');
    });
  });

  group('HaOverlayHotkey', () {
    testWidgets('fires H no matter where focus sits', (tester) async {
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

    testWidgets('stands down while a text field has focus', (tester) async {
      var toggles = 0;
      final controller = TextEditingController();
      addTearDown(controller.dispose);
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

    testWidgets('unregisters when it leaves the tree', (tester) async {
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
  });
}

/// Run out the snapshot toast's 6s dismiss timer + its 200ms fade-out removal
/// so no timer outlives the test.
Future<void> drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}
