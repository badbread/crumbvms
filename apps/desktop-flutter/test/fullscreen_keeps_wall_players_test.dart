// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Entering / leaving the fullscreen camera wall must not remount a single live
// tile: every tile's State (and so its libmpv Player + VideoController) has to
// be the same object before, during and after the toggle. Tested at the REAL
// app-shell level: the production `MainShell` (top bar, view row, tab
// transition, status bar, `ShellColumn`) under the production app-root
// `FullscreenEscHandler`, with the window resized the way the OS does it, and
// driven through the toolbar button, F11 and Esc.
//
// Why this exists: an unkeyed shell Column made every tile remount on each
// toggle (fixed by ShellColumn, #680), which tore down and re-created eleven
// hardware video textures at once and intermittently froze the Windows view.
// This test pins the whole shell, not just ShellColumn, so no other wrapper
// (tab transition, hotkey wrappers, theme, chrome rows) can quietly undo it.
//
// The server is a MockClient that denies every stream fetch (403), so no
// media_kit Player is ever created in the test; tile identity is checked on the
// tile States themselves, and on the `wall tile` lifecycle trace the tile
// prints (the same lines a tester greps in a console log).

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show DebugPrintCallback;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/media_token_cache.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/main.dart';
import 'package:crumb_desktop/session/session_controller.dart';
import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/notifications/status_bar_controller.dart';
import 'package:crumb_desktop/ui/recording_alerts/recording_alerts_controller.dart';
import 'package:crumb_desktop/ui/shell_column.dart';
import 'package:crumb_desktop/ui/updates/update_check_controller.dart';

const _kCameraCount = 11;

final _session = Session(base: 'http://192.0.2.10:8080', token: 't');

List<Camera> _cameras() => [
  for (var i = 0; i < _kCameraCount; i++)
    Camera(
      id: 'cam$i',
      name: 'Camera $i',
      enabled: true,
      hasSub: true,
      ptz: false,
      servedBy: 'crumb',
    ),
];

/// Denies stream fetches (403: the tile gives up without retrying, so no
/// Player and no retry timers), 404 for everything else.
http.Client _server() => MockClient((req) async {
  if (req.url.path.endsWith('/streams')) {
    return http.Response('{"error":"forbidden"}', 403);
  }
  return http.Response('{}', 404);
});

/// The live wall's tile widgets (private type; matched by name).
Finder _tiles() =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_WallTile');

class _Harness {
  _Harness(this.tester) : api = CrumbApi(client: _server()) {
    sessionController = SessionController(api: api, initialSession: _session);
    mediaTokens = MediaTokenCache(
      api: api,
      session: _session,
      onUnauthorized: () {},
    );
    recordingAlerts = RecordingAlertsController(api: api, session: _session);
    updateCheck = UpdateCheckController(api: api, session: _session);
  }

  final WidgetTester tester;
  final CrumbApi api;
  final FullscreenController fullscreen = FullscreenController();
  final StatusBarController statusBar = StatusBarController();
  late final SessionController sessionController;
  late final MediaTokenCache mediaTokens;
  late final RecordingAlertsController recordingAlerts;
  late final UpdateCheckController updateCheck;
  final List<String> trace = [];
  late DebugPrintCallback _prevDebugPrint;

  /// The exact production app-root shape (see `_CrumbClientAppState.build`):
  /// `MaterialApp(home: FullscreenEscHandler(child: MainShell(...)))`.
  Future<void> pump() async {
    _prevDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.startsWith('wall tile ')) {
        trace.add(message);
      }
    };
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenEscHandler(
          controller: fullscreen,
          child: MainShell(
            api: api,
            sessionController: sessionController,
            mediaTokens: mediaTokens,
            cameras: _cameras(),
            onLogout: () {},
            recordingAlerts: recordingAlerts,
            updateCheck: updateCheck,
            fullscreen: fullscreen,
            statusBar: statusBar,
          ),
        ),
      ),
    );
    // Let the stream fetches fail and the tiles settle.
    await tester.pump();
    await tester.pump();
  }

  /// Unmount everything so the wall's pollers and timers are disposed before
  /// the test ends (flutter_test fails a test that leaves timers pending).
  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    // The binding checks debugPrint is back to default at the end of the test
    // body, before tearDowns run, so restore it here (the tiles' `disposed`
    // lines from the unmount above are already in [trace]).
    debugPrint = _prevDebugPrint;
    fullscreen.dispose();
    recordingAlerts.dispose();
    updateCheck.dispose();
    statusBar.dispose();
    sessionController.dispose();
  }

  List<State> tileStates() => tester.stateList(_tiles()).toList();

  bool get chromeHidden =>
      tester.widget<ShellColumn>(find.byType(ShellColumn)).chromeHidden;

  /// Simulate the OS resizing the window to the monitor (or back) the way
  /// window_manager's fullscreen does on Windows.
  Future<void> resizeView(Size logical) async {
    tester.view.physicalSize = logical * tester.view.devicePixelRatio;
    await tester.pump();
  }
}

/// Every window_manager call the controller makes goes through its method
/// channel; answer them (no-op) so the native transition futures complete
/// the way the real plugin's do. Records the `setFullScreen` calls in order.
List<bool> _mockWindowManager(WidgetTester tester) {
  final calls = <bool>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async {
      if (call.method == 'setFullScreen') {
        final args = call.arguments as Map<Object?, Object?>;
        calls.add(args['isFullScreen'] == true);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    ),
  );
  return calls;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  const windowed = Size(1280, 720);
  const monitor = Size(1920, 1080);

  testWidgets(
    'toolbar fullscreen in and out keeps every tile State (no remount)',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(windowed);
      tester.view.physicalSize = windowed;
      final native = _mockWindowManager(tester);
      final h = _Harness(tester);
      await h.pump();

      final before = h.tileStates();
      expect(before, hasLength(_kCameraCount));
      expect(h.chromeHidden, isFalse);
      expect(
        h.trace.where((l) => l.startsWith('wall tile mounted')),
        hasLength(_kCameraCount),
      );
      final traceAtRest = h.trace.length;

      // Enter: the toolbar button flips the Flutter state at once; the window
      // follows with its own resize(s).
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      expect(h.fullscreen.isFullscreen, isTrue);
      expect(h.chromeHidden, isTrue);
      await h.resizeView(monitor);
      await tester.pump();

      final during = h.tileStates();
      expect(during, hasLength(_kCameraCount));
      for (var i = 0; i < _kCameraCount; i++) {
        expect(identical(during[i], before[i]), isTrue,
            reason: 'tile $i was remounted on entering fullscreen');
      }

      // Leave via Esc (the HardwareKeyboard handler), then the window restores.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(h.fullscreen.isFullscreen, isFalse);
      expect(h.chromeHidden, isFalse);
      await h.resizeView(windowed);
      await tester.pump();

      final after = h.tileStates();
      expect(after, hasLength(_kCameraCount));
      for (var i = 0; i < _kCameraCount; i++) {
        expect(identical(after[i], before[i]), isTrue,
            reason: 'tile $i was remounted on leaving fullscreen');
      }
      // The console trace a tester greps: a toggle adds NO `wall tile` lines.
      expect(h.trace.length, traceAtRest,
          reason: 'a fullscreen toggle must not mount/dispose/open anything');
      // And the OS window was asked to follow, in order.
      expect(native, [true, false]);

      await h.dispose();
    },
  );

  testWidgets('F11 toggles both ways from the real shell and keeps the tiles', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(windowed);
    tester.view.physicalSize = windowed;
    _mockWindowManager(tester);
    final h = _Harness(tester);
    await h.pump();
    final before = h.tileStates();
    final traceAtRest = h.trace.length;

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.pump();
    expect(h.fullscreen.isFullscreen, isTrue);
    expect(h.chromeHidden, isTrue);
    await h.resizeView(monitor);

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.pump();
    expect(h.fullscreen.isFullscreen, isFalse);
    expect(h.chromeHidden, isFalse);
    await h.resizeView(windowed);

    final after = h.tileStates();
    for (var i = 0; i < _kCameraCount; i++) {
      expect(identical(after[i], before[i]), isTrue, reason: 'tile $i');
    }
    expect(h.trace.length, traceAtRest);
    await h.dispose();
  });

  testWidgets('rapid toggles are applied in order, one at a time', (
    tester,
  ) async {
    final native = _mockWindowManager(tester);
    final c = FullscreenController();
    addTearDown(c.dispose);
    final a = c.setFullscreen(true);
    final b = c.setFullscreen(false);
    final d = c.setFullscreen(true);
    // Flutter-side state follows the LAST request at once ...
    expect(c.isFullscreen, isTrue);
    await Future.wait([a, b, d]);
    expect(c.isFullscreen, isTrue);
    // ... while the window saw one ordered sequence, never two interleaved
    // transitions; a request superseded before it ran is skipped.
    expect(native, [true, true]);
    unawaited(c.setFullscreen(false));
    await tester.pump();
    expect(c.isFullscreen, isFalse);
    expect(native, [true, true, false]);
  });
}
