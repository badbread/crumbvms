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
//     values through capture/restore and the style reset clears them;
//  5. `auto` hugs its content at the height the pill is actually RENDERED at,
//     not just at the reference height — the "Floodli…" truncation the
//     maintainer hit on a wall tile, where the chip's font/icon/padding floors
//     made the content wider than a linearly-scaled box.
//
// Mostly pure, headless assertions — every rule under test is a plain
// function; the last group pumps the real chip to prove the paragraph is not
// ellipsized inside the box the geometry hands it.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_icons.dart';
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
      final measured = HaOverlayBadgeItem.pillWidthAtHeight(
        'Front Door',
        HaOverlayBadgeItem.baseRefPx,
        widthMode: 'auto',
      );
      expect(auto.baseSize().$1, measured);
      // And null behaves identically — the two spellings of "default".
      expect(
        HaOverlayBadgeItem.pillWidthAtHeight(
          'Front Door',
          HaOverlayBadgeItem.baseRefPx,
        ),
        measured,
      );
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

  // ─────────────────────────────────────────────────────────────────────────
  // The live bug this group locks down: a pill on a small wall tile rendered
  // "Floodli…". `auto` measured the label at the REFERENCE height and scaled
  // the result linearly, but `HaBadgeChip._pill` clamps its icon/font/padding
  // at the height it is DRAWN at (floors 10/8/5/3px, ceilings 40/26/16/8px).
  // Below ~21px of rendered height the floors make the content wider than the
  // linearly-scaled box, so `TextOverflow.ellipsis` ate the label; above ~57px
  // the ceilings cap the content while the box kept growing, leaving dead
  // space. Both sides now derive from `HaPillMetrics` at the rendered height.
  group('auto width hugs the content at EVERY rendered height', () {
    // A 320x180 wall tile — pane scale 0.5625, so a default-size badge renders
    // ~12.4px tall and every one of the chip's floors is active. This is the
    // maintainer's screenshot, in numbers.
    const tilePaneScale = 0.5625;
    const label = 'Floodlight';

    double contentWidthAt(double h) => HaPillMetrics.forHeight(h)
        .contentWidth(HaOverlayBadgeItem.labelWidthPerFontPx(label));

    test('the small-tile case: the box fits the CLAMPED content', () {
      final item = HaOverlayBadgeItem(_link(label: label));
      final (w, h) = item.renderedSize(tilePaneScale);
      // Precondition: we really are in floor territory (font floor at h < 20).
      expect(h, lessThan(20.0));
      expect(HaPillMetrics.forHeight(h).fontSize, 8.0);
      expect(w, greaterThanOrEqualTo(contentWidthAt(h)));
    });

    test('...which the old linear scaling did NOT — the regression', () {
      final item = HaOverlayBadgeItem(_link(label: label));
      final (_, h) = item.renderedSize(tilePaneScale);
      final linear = item.baseSize().$1 * tilePaneScale;
      expect(linear, lessThan(contentWidthAt(h)));
    });

    test('no truncation and no dead space across the whole size range', () {
      for (final scale in [0.5, 0.5625, 0.8, 1.0, 1.5, 2.0, 3.0]) {
        for (final size in [0.4, 1.0, 2.5]) {
          final item = HaOverlayBadgeItem(_link(label: label))
            ..setBaseSize(0, HaOverlayBadgeItem.baseRefPx * size);
          final (w, h) = item.renderedSize(scale);
          // Exactly the content: >= is "never truncates", <= is "never pads".
          expect(w, closeTo(contentWidthAt(h), 1e-9), reason: '$scale/$size');
        }
      }
    });

    test('baseSize() is renderedSize(1.0) — the item-space invariant', () {
      for (final mode in [null, 'auto', 'narrow', 'wide']) {
        final item = HaOverlayBadgeItem(_link(pillWidth: mode, label: label));
        expect(item.baseSize(), item.renderedSize(1.0), reason: '$mode');
      }
      // ...and the height half of it is the shape-invariant, at any scale.
      final item = HaOverlayBadgeItem(_link(label: label));
      expect(
        item.renderedSize(2.0).$2,
        closeTo(HaOverlayBadgeItem.baseRefPx * 2.0, 1e-9),
      );
    });

    test('a fixed mode stays EXACTLY n x height at every pane scale', () {
      for (final (mode, factor) in [
        ('narrow', 4.0),
        ('medium', 6.0),
        ('wide', 8.0),
      ]) {
        for (final scale in [0.5, 1.0, 3.0]) {
          final item = HaOverlayBadgeItem(_link(pillWidth: mode, label: label));
          final (w, h) = item.renderedSize(scale);
          expect(w, closeTo(h * factor, 1e-9), reason: '$mode@$scale');
        }
      }
    });

    test('a fixed pill always has room for its icon + padding + gap', () {
      // A fixed width ellipsizes an over-long LABEL by design, but the chrome
      // around it must never overflow the box (a RenderFlex overflow).
      for (final mode in ['narrow', 'medium', 'wide']) {
        for (final h in [8.0, 12.4, 22.0, 120.0]) {
          final m = HaPillMetrics.forHeight(h);
          final chrome = m.padH * 2 + m.iconSize + m.gap;
          final w = HaOverlayBadgeItem.pillWidthAtHeight(
            label,
            h,
            widthMode: mode,
          );
          expect(w, greaterThanOrEqualTo(chrome), reason: '$mode@$h');
        }
      }
    });

    test('a dot is untouched by any of this', () {
      final dot = HaOverlayBadgeItem(_link(shape: 'dot', label: label));
      final (w, h) = dot.renderedSize(tilePaneScale);
      expect(w, h);
    });
  });

  group('HaPillMetrics — one source for the chip clamps', () {
    test('the floors bite on a small tile', () {
      final m = HaPillMetrics.forHeight(10);
      expect(m.iconSize, 10.0);
      expect(m.fontSize, 8.0);
      expect(m.padH, 5.0);
      expect(m.gap, 3.0);
    });

    test('the ceilings bite on a huge badge', () {
      final m = HaPillMetrics.forHeight(200);
      expect(m.iconSize, 40.0);
      expect(m.fontSize, 26.0);
      expect(m.padH, 16.0);
      expect(m.gap, 8.0);
    });

    test('in the linear band nothing is clamped', () {
      final m = HaPillMetrics.forHeight(40);
      expect(m.iconSize, closeTo(22.4, 1e-9));
      expect(m.fontSize, closeTo(16.0, 1e-9));
      expect(m.padH, closeTo(11.2, 1e-9));
      expect(m.gap, closeTo(5.6, 1e-9));
    });

    test('a runaway label is capped — at the same LABEL at every height', () {
      // Unchanged where nothing is clamped: 22.5 em of a 0.40h font is the
      // 9-pill-heights width this has always capped at.
      final ref = HaPillMetrics.forHeight(22);
      expect(ref.contentWidth(1000), lessThanOrEqualTo(22 * 9 + 22 * 1.3));
      expect(
        ref.contentWidth(1000) - ref.contentWidth(0),
        closeTo(22 * 9, 1e-9),
      );
      // And a label that fits under the cap is never trimmed by it, at any
      // height — including where the font floor is active (a height-based cap
      // shrank faster than the floored text and cut a fitting label short).
      for (final h in [8.0, 12.4, 22.0, 120.0]) {
        final m = HaPillMetrics.forHeight(h);
        expect(
          m.contentWidth(8) - m.contentWidth(0),
          closeTo(8 * m.fontSize, 1e-9),
          reason: 'h=$h',
        );
      }
    });
  });

  group('the chip really does not ellipsize in the box it is given', () {
    // The math above says the box fits; this pumps the actual chip in exactly
    // the rect `OverlayGeometry.rectFor` would hand it and asks the laid-out
    // paragraph whether it had to cut anything.
    Future<void> expectLabelIntact(
      WidgetTester tester, {
      required String label,
      required double paneScale,
      double overlaySize = 1.0,
    }) async {
      final item = HaOverlayBadgeItem(_link(label: label))
        ..setBaseSize(0, HaOverlayBadgeItem.baseRefPx * overlaySize);
      final (w, h) = item.renderedSize(paneScale);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: w,
              height: h,
              child: HaBadgeChip(
                visual: const HaVisual(Icons.lightbulb_outline, Colors.amber),
                isPill: true,
                pillLabel: label,
              ),
            ),
          ),
        ),
      );
      final para = tester.renderObject<RenderParagraph>(find.text(label));
      expect(para.didExceedMaxLines, isFalse, reason: 'ellipsized at h=$h');
      expect(
        para.size.width,
        greaterThanOrEqualTo(para.getMaxIntrinsicWidth(double.infinity) - 0.01),
        reason: 'label was squeezed at h=$h',
      );
    }

    testWidgets('"Floodlight" on a 320x180 wall tile', (tester) async {
      await expectLabelIntact(tester, label: 'Floodlight', paneScale: 0.5625);
    });

    testWidgets('a shrunk badge on a small tile (every floor active)',
        (tester) async {
      // 8.8px tall — about as small as a badge gets, since
      // `OverlayGeometry.rectFor` floors the rendered box at 8px.
      await expectLabelIntact(
        tester,
        label: 'Floodlight',
        paneScale: 0.5,
        overlaySize: 0.8,
      );
    });

    testWidgets('and still intact at the sizes that already worked',
        (tester) async {
      for (final (s, size) in [(1.0, 1.0), (2.0, 1.0), (3.0, 2.5)]) {
        await expectLabelIntact(
          tester,
          label: 'Back garden floodlight',
          paneScale: s,
          overlaySize: size,
        );
      }
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
