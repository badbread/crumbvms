// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Wheel zoom / pan / reset maths (pure), the ZoomableVideo widget (wheel zoom
// does not scroll the list behind it), and the bookmark button + `B` key on the
// shared ClipControls, driven by the fake transport.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/ui/clips/clip_bookmark.dart';
import 'package:crumb_desktop/ui/clips/clip_controls.dart';
import 'package:crumb_desktop/ui/clips/zoomable_video.dart';

import 'clip_controls_test.dart' show FakeTransport;

void main() {
  const pane = Size(400, 200);

  group('zoom maths', () {
    test('wheel step matches the Clips tab', () {
      expect(wheelZoomFactor(-100), 1.15);
      expect(wheelZoomFactor(100), closeTo(1 / 1.15, 1e-12));
      expect(kClipZoomMax, 30.0);
    });

    test('zooming about the cursor keeps the point under it', () {
      const cursor = Offset(300, 50);
      final z = zoomAboutCursor(ZoomState.identity, 2.0, cursor, pane);
      expect(z.scale, 2.0);
      // The image point under the cursor must still map to the cursor after
      // the transform (translate, then scale about the pane centre).
      const c = Offset(200, 100);
      final mapped = (cursor - c) * z.scale + c + z.offset;
      expect(mapped.dx, closeTo(cursor.dx, 1e-9));
      expect(mapped.dy, closeTo(cursor.dy, 1e-9));
    });

    test('scale clamps to the ceiling', () {
      var z = ZoomState.identity;
      for (var i = 0; i < 100; i++) {
        z = zoomAboutCursor(z, 1.15, const Offset(200, 100), pane);
      }
      expect(z.scale, kClipZoomMax);
    });

    test('zooming out to 1x snaps back to identity', () {
      var z = zoomAboutCursor(
        ZoomState.identity,
        1.15,
        const Offset(390, 10),
        pane,
      );
      expect(z.scale, greaterThan(1));
      z = zoomAboutCursor(z, 1 / 1.15, const Offset(390, 10), pane);
      expect(z, ZoomState.identity);
      expect(
        zoomAboutCursor(ZoomState.identity, 1 / 1.15, const Offset(1, 1), pane),
        ZoomState.identity,
      );
    });

    test('pan clamps so the image cannot leave the pane', () {
      const z = ZoomState(2.0, Offset.zero);
      final far = panZoom(z, const Offset(5000, -5000), pane);
      expect(far.offset, const Offset(200, -100)); // (s-1)*size/2
      expect(
        panZoom(ZoomState.identity, const Offset(30, 30), pane),
        ZoomState.identity,
      );
    });

    test('clampZoom re-clamps the offset', () {
      final z = clampZoom(1.5, const Offset(500, 500), pane);
      expect(z.offset, const Offset(100, 50));
      expect(clampZoom(0.2, const Offset(9, 9), pane), ZoomState.identity);
    });

    test('zoom level label', () {
      expect(formatZoomLevel(1.3225), '1.3x');
    });
  });

  group('ZoomableVideo', () {
    testWidgets('wheel zooms and does not scroll the list behind', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: controller,
              children: [
                SizedBox(
                  height: 300,
                  child: ZoomableVideo(child: Container(color: Colors.blue)),
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      );
      final center = tester.getCenter(
        find.byKey(const ValueKey('zoom-listener')),
      );
      final ptr = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(ptr.hover(center));
      await tester.sendEventToBinding(ptr.scroll(const Offset(0, -100)));
      await tester.pump();
      expect(controller.offset, 0);
      expect(find.byKey(const ValueKey('zoom-reset')), findsOneWidget);
      expect(find.text('1.1x'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('zoom-reset')));
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-reset')), findsNothing);
      await tester.pump(kZoomBadgeHold * 2);
    });

    testWidgets('double click resets', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 200,
                child: ZoomableVideo(child: Container(color: Colors.blue)),
              ),
            ),
          ),
        ),
      );
      final center = tester.getCenter(
        find.byKey(const ValueKey('zoom-listener')),
      );
      final ptr = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(ptr.hover(center));
      await tester.sendEventToBinding(ptr.scroll(const Offset(0, -100)));
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-reset')), findsOneWidget);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pump();
      expect(find.byKey(const ValueKey('zoom-reset')), findsNothing);
      await tester.pump(kZoomBadgeHold * 2);
    });
  });

  group('bookmark', () {
    Future<void> pumpControls(
      WidgetTester tester,
      FakeTransport t, {
      ValueChanged<DateTime>? onBookmark,
      DateTime? wallStart,
    }) async {
      tester.view.physicalSize = const Size(1000, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ClipControls(
                transport: t,
                wallStart: wallStart,
                onBookmark: onBookmark,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('button passes the wall-clock time at the playhead', (
      tester,
    ) async {
      final t = FakeTransport(); // playhead at 3 s
      DateTime? got;
      await pumpControls(
        tester,
        t,
        wallStart: DateTime(2026, 10, 1, 17, 36, 10),
        onBookmark: (d) => got = d,
      );
      await tester.tap(find.byKey(const ValueKey('clip-bookmark')));
      expect(got, DateTime(2026, 10, 1, 17, 36, 13));
      await t.seek(const Duration(seconds: 9));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('clip-bookmark')));
      expect(got, DateTime(2026, 10, 1, 17, 36, 19));
    });

    testWidgets('hidden without a handler or without a wall clock', (
      tester,
    ) async {
      final t = FakeTransport();
      await pumpControls(tester, t, wallStart: DateTime(2026, 10, 1));
      expect(find.byKey(const ValueKey('clip-bookmark')), findsNothing);
      await pumpControls(tester, t, onBookmark: (_) {});
      expect(find.byKey(const ValueKey('clip-bookmark')), findsNothing);
    });

    test('B key triggers the bookmark only when permitted', () {
      final t = FakeTransport();
      var n = 0;
      final b = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyB,
        logicalKey: LogicalKeyboardKey.keyB,
        timeStamp: Duration.zero,
      );
      expect(handleClipTransportKey(b, t, onBookmark: () => n++), isTrue);
      expect(n, 1);
      expect(handleClipTransportKey(b, t), isFalse);
      expect(n, 1);
    });

    test('default note carries plate, known name and camera', () {
      expect(
        clipBookmarkDescription(
          plate: 'ABC123',
          displayName: 'Mom',
          cameraName: 'Driveway',
        ),
        'ABC123 (Mom) · Driveway',
      );
      expect(
        clipBookmarkDescription(plate: 'ABC123', cameraName: 'Driveway'),
        'ABC123 · Driveway',
      );
      expect(
        clipBookmarkDescription(plate: '', displayName: ' ', cameraName: ''),
        'Plate',
      );
    });
  });
}
