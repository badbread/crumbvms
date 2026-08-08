// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for `visibleTimelineCameras`, the pure decision that backs the
// Playback timeline's "solo the selected camera" toggle: given the toggle
// state and the current selection, which camera intensity tracks does the
// strip render?
//
//  * solo ON + a loaded selection  -> just that camera (decluttered view);
//  * solo ON + no / unloaded selection -> ALL cameras (never a misleading
//    empty strip);
//  * solo OFF -> ALL cameras (the default stacked histogram).
//
// Pure, headless, deterministic.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_controller.dart';

void main() {
  const all = ['cam-a', 'cam-b', 'cam-c'];

  group('visibleTimelineCameras', () {
    test('solo on with a selected camera renders only that camera', () {
      expect(
        visibleTimelineCameras(
          solo: true,
          selectedCameraId: 'cam-b',
          allCameraIds: all,
        ),
        ['cam-b'],
      );
    });

    test('solo on with no selection falls back to all cameras', () {
      expect(
        visibleTimelineCameras(
          solo: true,
          selectedCameraId: null,
          allCameraIds: all,
        ),
        all,
      );
    });

    test('solo on but the selection is not loaded falls back to all', () {
      // Selected camera has no intensity data yet (absent from allCameraIds):
      // showing just it would be a misleading empty strip, so show everything.
      expect(
        visibleTimelineCameras(
          solo: true,
          selectedCameraId: 'cam-z',
          allCameraIds: all,
        ),
        all,
      );
    });

    test('solo off always renders all cameras (even with a selection)', () {
      expect(
        visibleTimelineCameras(
          solo: false,
          selectedCameraId: 'cam-b',
          allCameraIds: all,
        ),
        all,
      );
    });

    test('solo on with an empty camera set stays empty (no crash)', () {
      expect(
        visibleTimelineCameras(
          solo: true,
          selectedCameraId: 'cam-b',
          allCameraIds: const <String>[],
        ),
        isEmpty,
      );
    });
  });
}
