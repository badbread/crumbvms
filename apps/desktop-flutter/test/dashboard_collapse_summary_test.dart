// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the Server dashboard collapse-section header summaries. The
// long secondary lists (Retention per-camera policies, Connection camera
// status) are collapsed by default, so their headers must carry the counts that
// otherwise only show when expanded. These are pure, deterministic assertions
// on the header text.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/server/server_dashboard_screen.dart';

void main() {
  group('perCameraPoliciesSummary', () {
    test('shows the camera count', () {
      expect(perCameraPoliciesSummary(5), 'Per-camera policies (5)');
      expect(perCameraPoliciesSummary(0), 'Per-camera policies (0)');
      expect(perCameraPoliciesSummary(1), 'Per-camera policies (1)');
    });
  });

  group('cameraStatusSummary', () {
    test('no cameras', () {
      expect(cameraStatusSummary(0, 0, 0), 'No cameras');
    });

    test('recording count only when none are disabled', () {
      expect(cameraStatusSummary(5, 3, 0), '3 recording');
    });

    test('appends the disabled clause when some are disabled', () {
      expect(cameraStatusSummary(5, 3, 1), '3 recording · 1 disabled');
    });

    test('all recording, none disabled', () {
      expect(cameraStatusSummary(4, 4, 0), '4 recording');
    });
  });
}
