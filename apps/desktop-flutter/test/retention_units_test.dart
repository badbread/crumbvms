// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure unit tests for the retention hours<->days conversion used by the Server
// dashboard's policy editor. The backend stores retention in HOURS; the editor
// lets the operator work in whole days so 336 no longer needs mental day-math.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/ui/server/server_dashboard_screen.dart';

void main() {
  group('retentionInitialUnit', () {
    test('whole multiples of a day (>= 1 day) show as days', () {
      expect(retentionInitialUnit(336), retentionUnitDays); // 14 days
      expect(retentionInitialUnit(24), retentionUnitDays); // 1 day
      expect(retentionInitialUnit(48), retentionUnitDays);
    });
    test('non-whole-day values and sub-day values show as hours', () {
      expect(retentionInitialUnit(36), retentionUnitHours);
      expect(retentionInitialUnit(12), retentionUnitHours);
      expect(retentionInitialUnit(0), retentionUnitHours);
    });
  });

  group('retentionDisplayValue', () {
    test('days divides by 24', () {
      expect(retentionDisplayValue(336, retentionUnitDays), 14);
      expect(retentionDisplayValue(48, retentionUnitDays), 2);
    });
    test('hours pass through', () {
      expect(retentionDisplayValue(36, retentionUnitHours), 36);
    });
  });

  group('retentionToHours', () {
    test('days multiply by 24', () {
      expect(retentionToHours(2, retentionUnitDays), 48);
      expect(retentionToHours(14, retentionUnitDays), 336);
      expect(retentionToHours(1.5, retentionUnitDays), 36);
    });
    test('hours round to whole hours', () {
      expect(retentionToHours(36, retentionUnitHours), 36);
      expect(retentionToHours(36.4, retentionUnitHours), 36);
    });
  });

  group('round trip preserves the stored value', () {
    for (final hours in [336, 36, 24, 720, 1]) {
      test('$hours h survives display -> edit -> save', () {
        final unit = retentionInitialUnit(hours);
        final shown = retentionDisplayValue(hours, unit);
        expect(retentionToHours(shown, unit), hours);
      });
    }
  });

  group('retentionValueField trims trailing .0', () {
    test('whole numbers have no decimal', () {
      expect(retentionValueField(14), '14');
      expect(retentionValueField(14.0), '14');
    });
    test('fractional values keep the decimal', () {
      expect(retentionValueField(1.5), '1.5');
    });
  });

  group('retentionHelperText shows the OTHER unit', () {
    test('days value spells out hours', () {
      expect(retentionHelperText(14, retentionUnitDays), '= 336 h');
      expect(retentionHelperText(2, retentionUnitDays), '= 48 h');
    });
    test('hours value spells out days', () {
      expect(retentionHelperText(336, retentionUnitHours), '= 14 days');
      expect(retentionHelperText(24, retentionUnitHours), '= 1 day');
      expect(retentionHelperText(36, retentionUnitHours), '= 1.5 days');
    });
    test('non-positive value yields empty helper', () {
      expect(retentionHelperText(0, retentionUnitHours), '');
      expect(retentionHelperText(0, retentionUnitDays), '');
    });
  });
}
