// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The shared clip controls: formatting, scrub mapping, the button row and speed
// menu driving a fake transport, and the keyboard shortcuts. A fake
// ClipTransport stands in for media_kit so no libmpv is needed.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/ui/clips/clip_controls.dart';

class FakeTransport extends ClipTransport {
  Duration _pos = const Duration(seconds: 3);
  final Duration _dur = const Duration(seconds: 12);
  bool _playing = true;
  double _rate = 1;
  bool _muted = true;
  bool _loop = false;
  final List<String> log = [];

  @override
  Duration get position => _pos;
  @override
  Duration get duration => _dur;
  @override
  bool get playing => _playing;
  @override
  double get rate => _rate;
  @override
  bool get muted => _muted;
  @override
  bool get loop => _loop;

  @override
  Future<void> play() async {
    log.add('play');
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    log.add('pause');
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration to) async {
    log.add('seek ${to.inMilliseconds}');
    _pos = to;
    notifyListeners();
  }

  @override
  Future<void> stepFrame(bool forward) async {
    log.add(forward ? 'frame+' : 'frame-');
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> setRate(double rate) async {
    log.add('rate $rate');
    _rate = rate;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {
    log.add('mute $muted');
    _muted = muted;
    notifyListeners();
  }

  @override
  Future<void> setLoop(bool loop) async {
    log.add('loop $loop');
    _loop = loop;
    notifyListeners();
  }
}

Future<FakeTransport> _pump(
  WidgetTester tester, {
  VoidCallback? onFullscreen,
}) async {
  tester.view.physicalSize = const Size(1000, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final t = FakeTransport();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ClipControls(
            transport: t,
            wallStart: DateTime(2026, 10, 1, 17, 36, 10),
            markAt: const Duration(seconds: 8),
            onFullscreen: onFullscreen,
          ),
        ),
      ),
    ),
  );
  return t;
}

void main() {
  test('formatting', () {
    expect(formatClipTime(const Duration(seconds: 65)), '1:05');
    expect(formatClipTime(const Duration(seconds: 3)), '0:03');
    expect(formatClipTime(const Duration(hours: 1, seconds: 2)), '1:00:02');
    expect(formatWallClock(DateTime(2026, 1, 1, 17, 36, 21)), '5:36:21 PM');
    expect(formatWallClock(DateTime(2026, 1, 1, 0, 5, 1)), '12:05:01 AM');
    expect(formatClipSpeed(0.25), '0.25x');
    expect(formatClipSpeed(1), '1x');
    expect(formatClipSpeed(4), '4x');
    expect(kClipSpeeds, [0.25, 0.5, 1, 2, 4]);
  });

  test('scrub fraction maps and clamps', () {
    const total = Duration(seconds: 10);
    expect(scrubFractionToDuration(0.5, total), const Duration(seconds: 5));
    expect(scrubFractionToDuration(-1, total), Duration.zero);
    expect(scrubFractionToDuration(2, total), total);
  });

  test('jump clamps and togglePlay restarts a finished clip', () async {
    final t = FakeTransport();
    await t.jump(const Duration(seconds: -10));
    expect(t.position, Duration.zero);
    await t.jump(const Duration(seconds: 100));
    expect(t.position, t.duration);
    await t.pause();
    t.log.clear();
    await t.togglePlay();
    expect(t.log, ['seek 0', 'play']);
  });

  testWidgets('renders clip time and the wall-clock time of day', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('0:03 / 0:12'), findsOneWidget);
    // wallStart 5:36:10 PM + 3 s.
    expect(find.text('5:36:13 PM'), findsOneWidget);
    expect(find.byKey(const ValueKey('clip-scrub')), findsOneWidget);
    expect(find.byKey(const ValueKey('clip-fullscreen')), findsNothing);
  });

  testWidgets('buttons drive the transport', (tester) async {
    final t = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('clip-play')));
    await tester.tap(find.byKey(const ValueKey('clip-frame-fwd')));
    await tester.tap(find.byKey(const ValueKey('clip-frame-back')));
    await tester.tap(find.byKey(const ValueKey('clip-loop')));
    await tester.tap(find.byKey(const ValueKey('clip-mute')));
    await tester.tap(find.byKey(const ValueKey('clip-restart')));
    await tester.pump();
    expect(t.log, [
      'pause',
      'frame+',
      'frame-',
      'loop true',
      'mute false',
      'seek 0',
      'play',
    ]);
  });

  testWidgets('speed menu sets the rate', (tester) async {
    final t = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('clip-speed')));
    await tester.pumpAndSettle();
    for (final label in ['0.25x', '0.5x', '2x', '4x']) {
      expect(find.text(label), findsWidgets);
    }
    await tester.tap(find.text('2x').last);
    await tester.pumpAndSettle();
    expect(t.rate, 2);
    expect(t.log, ['rate 2.0']);
  });

  testWidgets('full-screen button appears and fires', (tester) async {
    var hit = 0;
    await _pump(tester, onFullscreen: () => hit++);
    await tester.tap(find.byKey(const ValueKey('clip-fullscreen')));
    expect(hit, 1);
  });

  testWidgets('tapping the scrub bar seeks', (tester) async {
    final t = await _pump(tester);
    final r = tester.getRect(find.byKey(const ValueKey('clip-scrub')));
    await tester.tapAt(Offset(r.left + r.width / 2, r.center.dy));
    expect(t.log.single, startsWith('seek '));
    expect(t.position.inSeconds, inInclusiveRange(5, 7));
  });

  testWidgets('hovering the scrub bar previews the time', (tester) async {
    await _pump(tester);
    final r = tester.getRect(find.byKey(const ValueKey('clip-scrub')));
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset(r.left + 1, r.center.dy));
    await g.moveTo(Offset(r.left + r.width / 2, r.center.dy));
    await tester.pump();
    expect(find.byKey(const ValueKey('clip-scrub-tip')), findsOneWidget);
    await g.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(find.byKey(const ValueKey('clip-scrub-tip')), findsNothing);
  });

  group('keyboard', () {
    KeyDownEvent down(LogicalKeyboardKey k) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: k,
      timeStamp: Duration.zero,
    );

    test('space, arrows, comma and period', () {
      final t = FakeTransport();
      expect(handleClipTransportKey(down(LogicalKeyboardKey.space), t), isTrue);
      expect(
        handleClipTransportKey(down(LogicalKeyboardKey.arrowRight), t),
        isTrue,
      );
      expect(
        handleClipTransportKey(down(LogicalKeyboardKey.arrowLeft), t),
        isTrue,
      );
      expect(handleClipTransportKey(down(LogicalKeyboardKey.comma), t), isTrue);
      expect(
        handleClipTransportKey(down(LogicalKeyboardKey.period), t),
        isTrue,
      );
      expect(t.log, ['pause', 'seek 4000', 'seek 3000', 'frame-', 'frame+']);
    });

    test('escape and other keys are not consumed', () {
      final t = FakeTransport();
      expect(
        handleClipTransportKey(down(LogicalKeyboardKey.escape), t),
        isFalse,
      );
      expect(handleClipTransportKey(down(LogicalKeyboardKey.keyA), t), isFalse);
      expect(t.log, isEmpty);
    });
  });
}
