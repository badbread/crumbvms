// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Per-state HA badge background (`overlay_bg_color_on`, wave A backend
// contract): render-only support on desktop ahead of the editor UI. Covers
// the three things a render-only PR can silently get wrong:
//  1. parsing degrades gracefully against a server that doesn't send the
//     field yet (today's behavior, null);
//  2. the resolution order matches the frozen contract EXACTLY, including
//     the honesty rule that a scene/stale/indeterminate reading never picks
//     the on-color, even when one is set;
//  3. an edit session (drag/resize/style-tweak on some OTHER field) carries
//     the value through capture/restore instead of silently dropping it.
//
// Pure, headless assertions — no widget pump needed since `resolveBadgeBg`
// is a plain function.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_icons.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_controller.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_layer.dart';

void main() {
  group('HaLink.overlayBgColorOn parsing', () {
    test('an older server payload (field absent) parses to null', () {
      final l = HaLink.fromJson({
        'id': 'l1',
        'entity_id': 'light.kitchen',
        'role': 'actuator',
        'sort_order': 0,
      });
      expect(l.overlayBgColorOn, isNull);
    });

    test('a present value round-trips verbatim', () {
      final l = HaLink.fromJson({
        'id': 'l2',
        'entity_id': 'light.kitchen',
        'role': 'actuator',
        'sort_order': 0,
        'overlay_bg_color': '#101014',
        'overlay_bg_color_on': '#FFCC33',
      });
      expect(l.overlayBgColor, '#101014');
      expect(l.overlayBgColorOn, '#FFCC33');
    });
  });

  group('haEdgeOnFor honesty gate (shared by accent dim + bg resolution)', () {
    test('a known on/off state resolves normally', () {
      expect(
        haEdgeOnFor(domain: 'binary_sensor', state: 'on', stale: false),
        isTrue,
      );
      expect(
        haEdgeOnFor(domain: 'binary_sensor', state: 'off', stale: false),
        isFalse,
      );
    });

    test('no known state yet is indeterminate', () {
      expect(
        haEdgeOnFor(domain: 'light', state: null, stale: false),
        isNull,
      );
    });

    test('a stale feed is indeterminate even for an "on" string', () {
      expect(
        haEdgeOnFor(domain: 'light', state: 'on', stale: true),
        isNull,
      );
    });

    test('a scene is always indeterminate, regardless of state string', () {
      expect(
        haEdgeOnFor(domain: 'scene', state: 'on', stale: false),
        isNull,
      );
    });

    test('unavailable/unknown are indeterminate, never off', () {
      expect(
        haEdgeOnFor(domain: 'binary_sensor', state: 'unavailable', stale: false),
        isNull,
      );
    });
  });

  group('resolveBadgeBg resolution order (frozen wave-A contract)', () {
    const bgOff = Color(0xFF101014);
    const bgOn = Color(0xFFFFCC33);
    const bgDefault = Color(0xFF17171B); // ha_overlay_layer.dart's _kBadgeDefaultBg

    test('ON + both colors set -> bg_color_on', () {
      expect(
        resolveBadgeBg(on: true, bgColor: bgOff, bgColorOn: bgOn),
        bgOn,
      );
    });

    test('ON + no on-color set -> falls back to bg_color', () {
      expect(
        resolveBadgeBg(on: true, bgColor: bgOff, bgColorOn: null),
        bgOff,
      );
    });

    test('ON + neither set -> default', () {
      expect(
        resolveBadgeBg(on: true, bgColor: null, bgColorOn: null),
        bgDefault,
      );
    });

    test('OFF never uses the on-color, even when set', () {
      expect(
        resolveBadgeBg(on: false, bgColor: bgOff, bgColorOn: bgOn),
        bgOff,
      );
    });

    test('indeterminate (null) never uses the on-color', () {
      expect(
        resolveBadgeBg(on: null, bgColor: bgOff, bgColorOn: bgOn),
        bgOff,
      );
    });

    test('indeterminate with no bg_color set falls back to default, '
        'even with an on-color set (scene / stale / unknown honesty rule)',
        () {
      expect(
        resolveBadgeBg(on: null, bgColor: null, bgColorOn: bgOn),
        bgDefault,
      );
    });
  });

  group('HaOverlayBadgeItem carries bgColorOnHex through an edit session', () {
    HaLink link({String? bgColorOn}) => HaLink(
          id: 'l1',
          entityId: 'light.kitchen',
          role: 'actuator',
          sortOrder: 0,
          overlayX: 0.5,
          overlayY: 0.5,
          overlayBgColor: '#101014',
          overlayBgColorOn: bgColorOn,
        );

    test('seeded from the link on construction', () {
      final item = HaOverlayBadgeItem(link(bgColorOn: '#FFCC33'));
      expect(item.bgColorOnHex, '#FFCC33');
    });

    test('null on the link stays null (no UI sets it yet)', () {
      final item = HaOverlayBadgeItem(link());
      expect(item.bgColorOnHex, isNull);
    });

    test('a capture/restore round-trip (e.g. drag, or another field\'s '
        'style edit) never drops a value set elsewhere', () {
      final item = HaOverlayBadgeItem(link(bgColorOn: '#FFCC33'));
      // Simulate an edit-session action unrelated to bg_color_on, e.g. a
      // drag: the generic editor captures/restores full item state on undo
      // or session bookkeeping, and must not lose fields it doesn't itself
      // touch.
      final captured = item.captureState();
      item.bgColorOnHex = 'tampered'; // pretend something else mutated it
      item.restoreState(captured);
      expect(item.bgColorOnHex, '#FFCC33');
    });
  });
}
