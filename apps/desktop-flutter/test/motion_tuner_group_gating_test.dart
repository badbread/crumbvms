// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the motion tuner's group-gating decision
// (`resolveMotionTunerGating`, lib/api/motion_tuner_api.dart).
//
// A grouped camera's motion sensitivity/threshold are POLICY fields owned by
// its group profile: the server rejects a per-camera policy fork for it
// (`update_camera_policy`, services/api/src/config_routes.rs). The tuner must
// gate those two controls up front — disable them + show a banner — while the
// exclusion mask, authoring grid, live meter, and detector-source toggles are
// per-CAMERA fields that stay editable in every case. These are pure, headless
// assertions on that decision (the "which controls to disable" logic), so the
// widget never has to render to prove it.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/motion_tuner_api.dart';

void main() {
  group('resolveMotionTunerGating', () {
    test('ungrouped camera: sensitivity editable, no banner', () {
      final g = resolveMotionTunerGating(null, const {});
      expect(g.sensitivityLocked, isFalse);
      expect(g.groupName, isNull);
      expect(g.sensitivityBanner, isNull);
    });

    test('grouped camera with known name: locked + banner names the group', () {
      final g = resolveMotionTunerGating('grp-1', const {
        'grp-1': 'Motion Cameras',
      });
      expect(g.sensitivityLocked, isTrue);
      expect(g.groupName, 'Motion Cameras');
      expect(g.sensitivityBanner, isNotNull);
      expect(g.sensitivityBanner, contains("group 'Motion Cameras'"));
      expect(g.sensitivityBanner, contains('ungroup'));
    });

    test('grouped camera with unknown name: still locked, generic banner', () {
      final g = resolveMotionTunerGating('grp-x', const {'grp-1': 'Other'});
      expect(g.sensitivityLocked, isTrue);
      expect(g.groupName, isNull);
      expect(g.sensitivityBanner, isNotNull);
      expect(g.sensitivityBanner, contains("group profile"));
    });

    test('grouped camera with empty name maps to generic banner', () {
      final g = resolveMotionTunerGating('grp-1', const {'grp-1': ''});
      expect(g.sensitivityLocked, isTrue);
      expect(g.groupName, isNull);
      expect(g.sensitivityBanner, contains("group profile"));
    });

    test('no banner ever contains an em dash (copy rule)', () {
      final g = resolveMotionTunerGating('grp-1', const {'grp-1': 'Yard'});
      expect(g.sensitivityBanner!.contains('—'), isFalse);
      expect(g.sensitivityBanner!.contains('–'), isFalse);
    });
  });

  group('CameraMotionConfig.fromJson group_id parsing', () {
    Map<String, dynamic> baseJson() => {
      'id': 'cam-1',
      'name': 'Family Room',
      'sub_url': 'rtsp://198.51.100.10/sub',
      'motion_mask': <dynamic>[],
      'motion_pixel_enabled': true,
      'motion_algorithm': 'census',
      'policy': {'motion_sensitivity': 'dynamic', 'motion_threshold': 0.003},
    };

    test('parses group_id when present', () {
      final j = baseJson()..['group_id'] = 'grp-1';
      final cfg = CameraMotionConfig.fromJson(j);
      expect(cfg.groupId, 'grp-1');
    });

    test('groupId is null when absent (ungrouped camera)', () {
      final cfg = CameraMotionConfig.fromJson(baseJson());
      expect(cfg.groupId, isNull);
    });
  });
}
