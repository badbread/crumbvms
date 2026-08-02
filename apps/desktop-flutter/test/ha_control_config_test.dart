// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-link control config (migration 0075, issue #440): the desktop client must
// parse `require_confirm` + `allowed_actions` defensively (an older server that
// omits them behaves exactly as today) and derive the offered action set from
// `allowed_actions` when present.
//
// Pure, headless assertions on the model + the action-set helper.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_actions.dart';

void main() {
  group('HaLink control config parsing', () {
    test('an older server payload (no fields) defaults to today behavior', () {
      final l = HaLink.fromJson({
        'id': 'l1',
        'entity_id': 'light.kitchen',
        'role': 'actuator',
        'sort_order': 0,
      });
      expect(l.requireConfirm, isFalse);
      expect(l.allowedActions, isNull);
      // Null allowed_actions ⇒ every action is permitted.
      expect(l.actionAllowed('turn_on'), isTrue);
      expect(l.actionAllowed('turn_off'), isTrue);
    });

    test('present fields are parsed and gate actions', () {
      final l = HaLink.fromJson({
        'id': 'l2',
        'entity_id': 'light.kitchen',
        'role': 'actuator',
        'sort_order': 0,
        'require_confirm': true,
        'allowed_actions': ['turn_on'],
      });
      expect(l.requireConfirm, isTrue);
      expect(l.allowedActions, ['turn_on']);
      expect(l.actionAllowed('turn_on'), isTrue);
      expect(l.actionAllowed('turn_off'), isFalse);
      expect(l.actionAllowed('toggle'), isFalse);
    });
  });

  group('offered action set honors allowed_actions', () {
    // Mirror the layer's _actionsFor logic without the widget: null ⇒ default
    // set, non-null ⇒ full domain set intersected with the permitted verbs.
    List<String> offered(String domain, List<String>? allowed) {
      final actions = allowed == null
          ? haActionsForDomain(domain)
          : haAllActionsForDomain(domain)
              .where((a) => allowed.contains(a.action))
              .toList();
      return actions.map((a) => a.action).toList();
    }

    test('null keeps the default light set (On/Off), unchanged from today', () {
      expect(offered('light', null), ['turn_on', 'turn_off']);
    });

    test('a light restricted to turn_on offers only On', () {
      expect(offered('light', ['turn_on']), ['turn_on']);
    });

    test('a light may be restricted to exactly toggle (superset button)', () {
      expect(offered('light', ['toggle']), ['toggle']);
    });

    test('a cover restricted to open/close drops stop', () {
      expect(
        offered('cover', ['open_cover', 'close_cover']),
        ['open_cover', 'close_cover'],
      );
    });
  });
}
