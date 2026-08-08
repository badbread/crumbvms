// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Unit tests for the per-camera policy-source label precedence on the Server
// dashboard. Under the ratified policy model a non-null `policy_id` no longer
// means "custom": a camera on Default and one pinned to a shared named policy
// both carry a non-null id, so the label must be decided by GROUP -> DEFAULT ->
// NAMED -> CUSTOM precedence, not by `policy_id != null`.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/server_dashboard_models.dart';

CameraConfigSummary _cam({
  String? groupId,
  String? policyId,
  bool isDefault = false,
  String? policyName,
}) {
  return CameraConfigSummary.fromJson({
    'id': 'cam-1',
    'name': 'Cam',
    'enabled': true,
    'policy_id': policyId,
    'group_id': groupId,
    'policy': {
      'id': 'pol-1',
      'name': policyName,
      'is_default': isDefault,
      'mode': 'continuous',
      'live_retention_hours': 336,
      'archive_enabled': false,
      'motion_pre_seconds': 0,
      'motion_post_seconds': 0,
      'motion_sensitivity': 'dynamic',
      'motion_keyframes_only': false,
      'record_stream': 'main',
      'record_audio': false,
    },
  });
}

void main() {
  group('resolvePolicySource precedence', () {
    test('grouped camera -> Group: <name>, group-managed', () {
      final s = resolvePolicySource(_cam(groupId: 'g1', isDefault: true), {
        'g1': 'Motion Cameras',
      });
      expect(s.kind, PolicySourceKind.group);
      expect(s.label, 'Group: Motion Cameras');
      expect(s.isGroupManaged, isTrue);
    });

    test(
      'grouped camera with unknown group id falls back to a generic label',
      () {
        final s = resolvePolicySource(_cam(groupId: 'g-missing'), const {});
        expect(s.kind, PolicySourceKind.group);
        expect(s.label, 'Group profile');
        expect(s.isGroupManaged, isTrue);
      },
    );

    test('group wins even when the resolved policy is the default', () {
      // A grouped camera resolves to the default policy row (is_default=true)
      // but must still read as group-managed, never "Default policy".
      final s = resolvePolicySource(_cam(groupId: 'g1', isDefault: true), {
        'g1': 'Front',
      });
      expect(s.kind, PolicySourceKind.group);
    });

    test(
      'camera on Default (non-null policy_id = Default.id) -> Default policy',
      () {
        final s = resolvePolicySource(
          _cam(policyId: 'default-id', isDefault: true),
          const {},
        );
        expect(s.kind, PolicySourceKind.defaultPolicy);
        expect(s.label, 'Default policy');
        expect(s.isGroupManaged, isFalse);
      },
    );

    test('camera on a shared named policy -> Policy: <name>', () {
      final s = resolvePolicySource(
        _cam(policyId: 'p-24x7', policyName: '24x7 High'),
        const {},
      );
      expect(s.kind, PolicySourceKind.named);
      expect(s.label, 'Policy: 24x7 High');
      expect(s.isGroupManaged, isFalse);
    });

    test(
      'anonymous per-camera fork (name null, not default) -> Custom policy',
      () {
        final s = resolvePolicySource(_cam(policyId: 'fork-id'), const {});
        expect(s.kind, PolicySourceKind.custom);
        expect(s.label, 'Custom policy');
      },
    );
  });
}
