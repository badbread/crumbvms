// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Issue #706: a camera that advertises audio but sends none froze mpv's
// clock with the track selected, and the stall watchdog reconnected the pane
// forever. After an unmute the track is dropped again if the clock stalls.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/services/audio_follow_controller.dart';

void main() {
  test('a clock that did not move over the check window is frozen', () {
    const t = Duration(seconds: 12);
    expect(audioLooksFrozen(t, t), isTrue);
    expect(audioLooksFrozen(t, t + const Duration(milliseconds: 400)), isTrue);
  });

  test('a live pane that keeps playing is not frozen', () {
    const t = Duration(seconds: 12);
    expect(audioLooksFrozen(t, t + kSilentAudioCheck), isFalse);
    expect(audioLooksFrozen(t, t + const Duration(seconds: 2)), isFalse);
  });
}
