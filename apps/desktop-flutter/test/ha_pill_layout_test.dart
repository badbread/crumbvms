// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pill LAYOUT (`overlay_pill_width` / `overlay_text_align`, migration 0078,
// issue #497): the operator can pin a pill to a fixed width and choose where
// the icon + label group sits inside it.
//
// The whole point of a small closed vocabulary is that four renderers agree,
// so these lock the parts a desktop change could silently break:
//  1. parsing degrades gracefully against a server that doesn't send the
//     fields (null = today's rendering);
//  2. the resolution rule is EXACTLY the contract — auto/unknown ⇒ measured
//     content width, and the three fixed modes are exact multiples of the
//     pill's HEIGHT, not of anything label-dependent;
//  3. a fixed width really is fixed: it does not vary with the label, which is
//     what makes several badges set to the same mode line up;
//  4. an edit session (drag, resize, a tweak to some OTHER field) carries both
//     values through capture/restore and the style reset clears them.
//
// Pure, headless assertions — every rule under test is a plain function.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_controller.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_layer.dart';

HaLink _link({
  String? pillWidth,
  String? textAlign,
  String label = 'Front Door',
  String shape = 'pill',
}) =>
    HaLink.fromJson({
      'id': 'l1',
      'entity_id': 'binary_sensor.front_door',
      'role': 'sensor',
      'sort_order': 0,
      'label': label,
      'overlay_x': 0.3,
      'overlay_y': 0.4,
      'overlay_size': 1.0,
      'overlay_shape': shape,
      if (pillWidth != null) 'overlay_pill_width': pillWidth,
      if (textAlign != null) 'overlay_text_align': textAlign,
    });

void main() {
  group('pill layout parsing', () {
    test('an older server payload (fields absent) parses to null', () {
      final l = HaLink.fromJson({
        'id': 'l1',
        'entity_id': 'light.kitchen',
        'role': 'actuator',
        'sort_order': 0,
      });
      expect(l.overlayPillWidth, isNull);
      expect(l.overlayTextAlign, isNull);
    });

    test('present values round-trip verbatim', () {
      final l = _link(pillWidth: 'medium', textAlign: 'center');
      expect(l.overlayPillWidth, 'medium');
      expect(l.overlayTextAlign, 'center');
    });
  });

  group('haPillWidthFactor — the frozen width vocabulary', () {
    test('auto and null mean "measure the content" (no factor)', () {
      expect(haPillWidthFactor(null), isNull);
      expect(haPillWidthFactor('auto'), isNull);
    });

    test('the three fixed modes are exact height multiples', () {
      expect(haPillWidthFactor('narrow'), 4.0);
      expect(haPillWidthFactor('medium'), 6.0);
      expect(haPillWidthFactor('wide'), 8.0);
    });

    test('an unknown value from a newer server degrades to auto', () {
      // Never guess: a mode this build has not shipped renders as today's
      // hug-the-content pill rather than some invented width.
      for (final bad in ['', 'AUTO', 'huge', 'fixed', '8']) {
        expect(haPillWidthFactor(bad), isNull, reason: bad);
      }
    });

    test('the vocabulary list matches the server contract exactly', () {
      // services/api/src/ha.rs HA_PILL_WIDTH_MODES / HA_TEXT_ALIGNS.
      expect(kHaPillWidthModes, ['auto', 'narrow', 'medium', 'wide']);
      expect(kHaTextAligns, ['start', 'center', 'end']);
      // Every non-auto mode must actually resolve to a factor, or the console
      // could author a value this renderer silently ignores.
      for (final m in kHaPillWidthModes.where((m) => m != 'auto')) {
        expect(haPillWidthFactor(m), isNotNull, reason: m);
      }
    });
  });

  group('haPillAlignment — the frozen alignment vocabulary', () {
    test('null and start are the leading edge (today)', () {
      expect(haPillAlignment(null), MainAxisAlignment.start);
      expect(haPillAlignment('start'), MainAxisAlignment.start);
    });

    test('center and end map to their Flex alignments', () {
      expect(haPillAlignment('center'), MainAxisAlignment.center);
      expect(haPillAlignment('end'), MainAxisAlignment.end);
    });

    test('an unknown value degrades to start, never to a surprise', () {
      for (final bad in ['', 'left', 'right', 'justify', 'CENTER']) {
        expect(haPillAlignment(bad), MainAxisAlignment.start, reason: bad);
      }
    });
  });

  group('HaOverlayBadgeItem.baseSize with a width mode', () {
    test('auto keeps the measured hug-the-content width, unchanged', () {
      final auto = HaOverlayBadgeItem(_link());
      final measured =
          HaOverlayBadgeItem.pillBaseWidth('Front Door', widthMode: 'auto');
      expect(auto.baseSize().$1, measured);
      // And null behaves identically — the two spellings of "default".
      expect(HaOverlayBadgeItem.pillBaseWidth('Front Door'), measured);
    });

    test('a fixed mode is an exact multiple of the badge HEIGHT', () {
      for (final (mode, factor) in [
        ('narrow', 4.0),
        ('medium', 6.0),
        ('wide', 8.0),
      ]) {
        final item = HaOverlayBadgeItem(_link(pillWidth: mode));
        final (w, h) = item.baseSize();
        expect(w, closeTo(h * factor, 1e-9), reason: mode);
      }
    });

    test('a fixed width does not move with the label — badges line up', () {
      final short = HaOverlayBadgeItem(_link(pillWidth: 'medium', label: 'A'));
      final long = HaOverlayBadgeItem(
        _link(pillWidth: 'medium', label: 'Back garden floodlight'),
      );
      expect(short.baseSize().$1, long.baseSize().$1);
      // ...whereas auto very much does (that is what "auto" means).
      final autoShort = HaOverlayBadgeItem(_link(label: 'A'));
      final autoLong =
          HaOverlayBadgeItem(_link(label: 'Back garden floodlight'));
      expect(autoShort.baseSize().$1, lessThan(autoLong.baseSize().$1));
    });

    test('a DOT ignores the width mode and stays square', () {
      final dot = HaOverlayBadgeItem(
        _link(shape: 'dot', pillWidth: 'wide', textAlign: 'end'),
      );
      final (w, h) = dot.baseSize();
      expect(w, h);
    });

    test('the fixed width scales with overlay_size, like everything else', () {
      final big = HaOverlayBadgeItem(
        HaLink.fromJson({
          'id': 'l1',
          'entity_id': 'binary_sensor.front_door',
          'role': 'sensor',
          'sort_order': 0,
          'overlay_x': 0.3,
          'overlay_y': 0.4,
          'overlay_size': 2.5,
          'overlay_shape': 'pill',
          'overlay_pill_width': 'wide',
        }),
      );
      final (w, h) = big.baseSize();
      expect(h, closeTo(HaOverlayBadgeItem.baseRefPx * 2.5, 1e-9));
      expect(w, closeTo(h * 8.0, 1e-9));
    });
  });

  group('edit-session round trip', () {
    test('capture/restore carries both fields', () {
      final item = HaOverlayBadgeItem(
        _link(pillWidth: 'narrow', textAlign: 'end'),
      );
      final snapshot = item.captureState();
      item.pillWidthMode = 'wide';
      item.textAlign = 'center';
      item.restoreState(snapshot);
      expect(item.pillWidthMode, 'narrow');
      expect(item.textAlign, 'end');
    });

    test('resetStyle clears both back to the default rendering', () {
      final item = HaOverlayBadgeItem(
        _link(pillWidth: 'wide', textAlign: 'center'),
      );
      item.resetStyle();
      expect(item.pillWidthMode, isNull);
      expect(item.textAlign, isNull);
      // The reset is a STYLE reset: position and label survive it.
      expect(item.x, 0.3);
      expect(item.labelText, 'Front Door');
    });
  });
}
