// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression: in the fullscreen camera wall neither Esc nor F11 left
// fullscreen and the operator was trapped. Entering fullscreen via the
// toolbar button hides the toolbar, which DISPOSES the focused button, and
// Flutter parks primary focus on the route's FocusScope, an ANCESTOR of the
// app-root Focus node, so its Focus.onKeyEvent never saw the key. The handler
// is now also a HardwareKeyboard handler, and a hover-revealed exit button is
// the visible safety net.

import 'dart:async' show unawaited;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';

void main() {
  late FullscreenController controller;
  late ValueNotifier<bool> showButton;

  setUp(() {
    controller = FullscreenController();
    showButton = ValueNotifier(true);
  });

  Future<void> pumpWall(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenEscHandler(
          controller: controller,
          child: Scaffold(
            body: Stack(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: showButton,
                  builder: (context, show, _) => show
                      ? Align(
                          alignment: Alignment.topLeft,
                          child: ElevatedButton(
                            onPressed: () => controller.setFullscreen(true),
                            child: const Text('go'),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                FullscreenExitCorner(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Click the toolbar button, enter fullscreen, and hide the toolbar: the
  /// real-world sequence that strands focus above the handler.
  Future<void> enterFullscreenLikeTheToolbar(WidgetTester tester) async {
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(controller.isFullscreen, isTrue);
    showButton.value = false;
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Esc leaves fullscreen after the focused toolbar button is gone', (
    tester,
  ) async {
    await pumpWall(tester);
    await enterFullscreenLikeTheToolbar(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.isFullscreen, isFalse);
  });

  testWidgets('F11 toggles fullscreen both ways', (tester) async {
    await pumpWall(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(controller.isFullscreen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(controller.isFullscreen, isFalse);
  });

  testWidgets('Esc in a text field does not leave fullscreen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenEscHandler(
          controller: controller,
          child: const Scaffold(body: TextField(key: Key('t'))),
        ),
      ),
    );
    unawaited(controller.setFullscreen(true));
    await tester.pump();
    await tester.tap(find.byKey(const Key('t')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.isFullscreen, isTrue);
  });

  testWidgets('the corner exit button appears on hover and leaves fullscreen', (
    tester,
  ) async {
    await pumpWall(tester);
    final corner = find.byKey(const ValueKey('fullscreen-exit-corner'));
    expect(corner, findsNothing, reason: 'nothing while windowed');
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(corner, findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(tester.getCenter(corner));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    expect(controller.isFullscreen, isFalse);
  });
}
