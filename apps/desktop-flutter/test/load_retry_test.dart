// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A live tile whose first stream-URL fetch failed has no player and therefore
// no stall watchdog; LoadRetry re-runs its load on the watchdog's backoff
// schedule, forever (D1).

import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/ui/live/load_retry.dart';
import 'package:crumb_desktop/ui/live/pane_watchdog.dart';

void main() {
  test('backoff doubles from 1 s to 15 s, then settles at 60 s', () {
    const cfg = StallWatchdogConfig();
    final secs = [
      for (var i = 1; i <= 10; i++) LoadRetry.baseDelay(i, cfg).inSeconds,
    ];
    expect(secs, [1, 2, 4, 8, 15, 15, 15, 15, 60, 60]);
  });

  testWidgets('keeps retrying with growing attempts until reset', (
    tester,
  ) async {
    final retry = LoadRetry();
    var fired = 0;
    void again() {
      fired++;
      retry.schedule(again); // the load failed again
    }

    retry.schedule(again);
    expect(retry.pending, isTrue);
    // Walk simulated time forward; each hop is long enough for the base delay,
    // the <1 s jitter and a few herd-budget deferrals. (The herd budget's
    // window follows the real clock, so only its first 3 slots are usable
    // inside one test run; that is enough to show the retry keeps going.)
    for (var i = 0; i < 40 && fired < 3; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    expect(fired, greaterThanOrEqualTo(3));
    expect(retry.attempts, greaterThan(fired - 1));

    retry.reset(); // a load succeeded
    expect(retry.attempts, 0);
    expect(retry.pending, isFalse);
    final before = fired;
    await tester.pump(const Duration(minutes: 5));
    expect(fired, before, reason: 'reset cancels the pending retry');
    retry.dispose();
  });

  testWidgets('dispose cancels a pending retry', (tester) async {
    final retry = LoadRetry();
    var fired = 0;
    retry.schedule(() => fired++);
    retry.dispose();
    await tester.pump(const Duration(minutes: 5));
    expect(fired, 0);
    retry.schedule(() => fired++); // ignored after dispose
    await tester.pump(const Duration(minutes: 5));
    expect(fired, 0);
  });
}
