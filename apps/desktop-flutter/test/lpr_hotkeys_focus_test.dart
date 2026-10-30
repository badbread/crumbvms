// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression: on the Plates tab Esc (close the profile), j / k / Enter and
// the profile's Space / arrow transport keys did nothing, while typing in the
// search box worked.
//
// Root cause: `textInputHasFocus()` walked DOWN from the primary focus node
// looking for ANY `EditableText`. The app root (`FullscreenEscHandler`,
// `autofocus: true`) permanently owns primary focus, and it is a plain `Focus`
// (not a scope) whose subtree is the whole app, so the Plates tab's search
// box made the gate report "typing" while nothing was focused, and every
// hardware hotkey stood down. Playback worked only because it has no text
// field on screen.
//
// These tests use the real app-root focus geometry.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';
import 'package:crumb_desktop/ui/hotkeys/text_focus.dart';
import 'package:crumb_desktop/ui/plates/plates_screen.dart';

Widget _appRoot(Widget child) => MaterialApp(
  home: FullscreenEscHandler(
    controller: FullscreenController(),
    child: Scaffold(body: child),
  ),
);

/// Records which keys a gated hardware handler would have acted on.
class _Probe extends StatefulWidget {
  const _Probe({required this.log, required this.child});
  final List<String> log;
  final Widget child;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_on);
  }

  bool _on(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    if (hotkeyContextBlocked(context)) return false;
    widget.log.add(e.logicalKey.keyLabel);
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_on);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Map<String, dynamic> _read(int i, {String plate = 'ABC123'}) => {
  'id': 'r$i',
  'camera_id': 'cam',
  'ts': DateTime.now()
      .subtract(Duration(minutes: 10 * i))
      .toUtc()
      .toIso8601String(),
  'plate': plate,
  'plate_raw': plate,
  'confidence': 0.97,
  'region': 'CA',
  'source_id': 'crumb-alpr',
};

http.Client _server() => MockClient((req) async {
  if (req.url.path == '/plates') {
    final body = {
      'plates': [_read(1), _read(2, plate: 'XYZ789')],
      'total': 2,
      'has_more': false,
    };
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
  return http.Response('{}', 404);
});

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(resetHotkeySuppressionForTest);

  group('textInputHasFocus under the real app-root focus', () {
    testWidgets('an unfocused text field elsewhere does not count', (
      tester,
    ) async {
      await tester.pumpWidget(
        _appRoot(
          const Column(
            children: [
              TextField(key: Key('search')),
              Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      );
      await tester.pump();
      // The app root really is the (non-scope) primary focus.
      final primary = FocusManager.instance.primaryFocus!;
      expect(primary is FocusScopeNode, isFalse);
      expect(primary.context!.widget, isNot(isA<EditableText>()));
      expect(textInputHasFocus(), isFalse);
    });

    testWidgets('a focused field still counts, an explicit FocusNode too', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _appRoot(TextField(key: const Key('search'), focusNode: node)),
      );
      await tester.pump();
      expect(textInputHasFocus(), isFalse);
      await tester.tap(find.byKey(const Key('search')));
      await tester.pump();
      expect(textInputHasFocus(), isTrue);
    });

    testWidgets('gated hotkeys fire with a search box on screen, not in it', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(
        _appRoot(
          _Probe(
            log: log,
            child: const Column(
              children: [
                TextField(key: Key('search')),
                Expanded(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      for (final k in [
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.comma,
        LogicalKeyboardKey.period,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyJ,
        LogicalKeyboardKey.enter,
      ]) {
        await tester.sendKeyEvent(k);
      }
      expect(log, hasLength(8));

      log.clear();
      await tester.tap(find.byKey(const Key('search')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(log, isEmpty, reason: 'typing must not trigger shortcuts');
    });
  });

  group('PlatesScreen keyboard (list / grid + profile)', () {
    Future<void> pumpPlates(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // The plates/watchlist calls use a module-level TimeoutClient, which
      // wraps whatever `http.Client()` resolves to when first touched.
      await http.runWithClient(() async {
        await tester.pumpWidget(
        _appRoot(
          PlatesScreen(
            api: CrumbApi(),
            session: Session(base: 'http://127.0.0.1:9', token: 't'),
            cameras: [
              Camera(
                id: 'cam',
                name: 'Cam',
                enabled: true,
                hasSub: false,
                ptz: false,
                servedBy: 'crumb',
              ),
            ],
            onViewFootage: (_, _) {},
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      }, _server);
    }

    final profile = find.byKey(const ValueKey('profile-hero'));

    testWidgets('j then Enter opens the profile and Esc closes it', (
      tester,
    ) async {
      await pumpPlates(tester);
      expect(find.byType(TextField), findsWidgets);
      expect(profile, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 100));
      expect(profile, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));
      expect(profile, findsNothing);
    });

    testWidgets('Esc still closes the profile after clicking inside it', (
      tester,
    ) async {
      await pumpPlates(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 100));
      expect(profile, findsOneWidget);
      await tester.tap(profile, warnIfMissed: false);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));
      expect(profile, findsNothing);
    });

    testWidgets('typing in the search box does not drive the list', (
      tester,
    ) async {
      await pumpPlates(tester);
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 100));
      expect(profile, findsNothing);
    });
  });
}
