// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The HA overlay editor restructure (PR F): sticky top bar + badge-anchored
// popover, replacing the floating style panel, the bottom editor bar and the
// two modal pickers.
//
// Everything asserted here is the PURE logic the new chrome sits on, so it can
// be tested headlessly (no widget pump, no video pane, no server):
//  1. the edit-session STATE PREVIEW substitution — the one piece with a
//     state-honesty question attached, so its blast radius has to be exact:
//     Live must be a pass-through, and a forced preview must reach every
//     downstream visual identically to a real reading;
//  2. "Reset style" semantics — a whole-badge reset that must clear every
//     style field and must NOT touch position, size or label (undoing an
//     operator's placement work would be the expensive mistake here);
//  3. the popover's anchor-side chooser — flip/fallback/clamp rules, which are
//     invisible in a screenshot and easy to regress;
//  4. the session lifecycle around the new cancel-without-saving path.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_badge_popover.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_icons.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_controller.dart';
import 'package:crumb_desktop/ui/ha_overlay/ha_overlay_layer.dart';
import 'package:crumb_desktop/ui/overlay_editor/overlay_editor_controller.dart';
import 'package:crumb_desktop/ui/overlay_editor/overlay_item.dart';

HaLink _link({
  String id = 'l1',
  String entityId = 'light.kitchen',
  bool placed = true,
  Map<String, Object?> extra = const {},
}) =>
    HaLink.fromJson({
      'id': id,
      'entity_id': entityId,
      'role': 'actuator',
      'sort_order': 0,
      if (placed) 'overlay_x': 0.4,
      if (placed) 'overlay_y': 0.6,
      ...extra,
    });

void main() {
  group('state preview substitution', () {
    test('Live (null) is a pass-through for state and staleness', () {
      expect(haPreviewedState(null, 'open'), 'open');
      expect(haPreviewedState(null, null), isNull);
      expect(haPreviewedStale(null, true), isTrue);
      expect(haPreviewedStale(null, false), isFalse);
    });

    test('On/Off substitute the canonical HA words, whatever the real state',
        () {
      expect(haPreviewedState(true, 'closed'), 'on');
      expect(haPreviewedState(false, 'open'), 'off');
      // …including when there is no live reading at all, which is exactly the
      // case the preview exists for (a badge for an entity the server has not
      // polled yet must still be stylable).
      expect(haPreviewedState(true, null), 'on');
      expect(haPreviewedState(false, null), 'off');
    });

    test('a forced preview clears staleness', () {
      // Otherwise haEdgeOnFor would gate the reading back to indeterminate and
      // the operator would be picking colors against a greyed-out badge.
      expect(haPreviewedStale(true, true), isFalse);
      expect(haPreviewedStale(false, true), isFalse);
    });

    test('the substituted word drives edgeOn exactly like a real reading', () {
      expect(edgeOn(haPreviewedState(true, 'anything')!), isTrue);
      expect(edgeOn(haPreviewedState(false, 'anything')!), isFalse);
    });

    test('preview reaches the per-state background through the real resolver',
        () {
      const base = Color(0xFF102030);
      const onColor = Color(0xFFAA0000);

      Color bgUnder(bool? preview, {String? live, bool stale = false}) {
        final state = haPreviewedState(preview, live);
        final effStale = haPreviewedStale(preview, stale);
        return resolveBadgeBg(
          on: haEdgeOnFor(domain: 'light', state: state, stale: effStale),
          bgColor: base,
          bgColorOn: onColor,
        );
      }

      // Preview On shows the on-color even though the device reads off…
      expect(bgUnder(true, live: 'off'), onColor);
      // …preview Off shows the base even though the device reads on…
      expect(bgUnder(false, live: 'on'), base);
      // …and preview On beats a stale feed (which would otherwise grey it).
      expect(bgUnder(true, live: null, stale: true), onColor);
      // Live is untouched: a stale feed still refuses to claim "on".
      expect(bgUnder(null, live: 'on', stale: true), base);
    });

    test('a scene never previews as on (the domain honesty gate still wins)',
        () {
      final state = haPreviewedState(true, null);
      expect(
        haEdgeOnFor(domain: 'scene', state: state, stale: false),
        isNull,
      );
    });
  });

  group('HaOverlayBadgeItem.resetStyle', () {
    HaOverlayBadgeItem styled() {
      final item = HaOverlayBadgeItem(_link());
      item
        ..labelText = 'Kitchen light'
        ..iconKey = 'lightbulb'
        ..colorHex = '#FF0000'
        ..bgColorHex = '#101010'
        ..bgColorOnHex = '#00FF00'
        ..shape = 'pill'
        ..outline = true
        ..showState = true
        ..showAge = true
        ..opacity = 0.4;
      item.setBaseSize(44, 44);
      item.x = 0.25;
      item.y = 0.75;
      return item;
    }

    test('clears every style field the popover can set', () {
      final item = styled()..resetStyle();
      expect(item.iconKey, isNull);
      expect(item.colorHex, isNull);
      expect(item.bgColorHex, isNull);
      expect(item.bgColorOnHex, isNull);
      expect(item.shape, isNull);
      expect(item.isPill, isFalse);
      expect(item.outline, isFalse);
      expect(item.showState, isFalse);
      expect(item.showAge, isFalse);
      expect(item.opacity, 1.0);
    });

    test('keeps position, size and label — a style reset is not a re-place',
        () {
      final item = styled();
      final size = item.baseSize().$2;
      item.resetStyle();
      expect(item.x, 0.25);
      expect(item.y, 0.75);
      expect(item.baseSize().$2, size);
      expect(item.labelText, 'Kitchen light');
      expect(item.displayLabel, 'Kitchen light');
    });

    test('is one undoable step: capture/restore round-trips across it', () {
      final item = styled();
      final before = item.captureState();
      item.resetStyle();
      expect(item.colorHex, isNull);
      item.restoreState(before);
      expect(item.colorHex, '#FF0000');
      expect(item.bgColorOnHex, '#00FF00');
      expect(item.shape, 'pill');
      expect(item.outline, isTrue);
      expect(item.showState, isTrue);
      expect(item.showAge, isTrue);
      expect(item.opacity, closeTo(0.4, 1e-9));
      expect(item.iconKey, 'lightbulb');
    });
  });

  group('resolveHaPopoverPlacement', () {
    const popover = Size(300, 460);
    const pane = Size(1280, 720);

    test('opens to the RIGHT of the badge when there is room', () {
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(200, 300, 24, 24),
        popover: popover,
        pane: pane,
      );
      expect(p.side, HaPopoverSide.right);
      expect(p.left, 200 + 24 + 12);
      // Vertically centered on the badge.
      expect(p.top, closeTo(312 - 230, 0.001));
    });

    test('flips LEFT when the right edge is too close', () {
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(1150, 300, 24, 24),
        popover: popover,
        pane: pane,
      );
      expect(p.side, HaPopoverSide.left);
      expect(p.left, 1150 - 12 - 300);
    });

    test('falls to BELOW when neither side fits', () {
      // A narrow pane with the badge dead center: no horizontal room either
      // way, but plenty of vertical room underneath.
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(160, 40, 24, 24),
        popover: const Size(300, 200),
        pane: const Size(360, 720),
      );
      expect(p.side, HaPopoverSide.below);
      expect(p.top, 40 + 24 + 12);
      // Horizontally centered on the badge, clamped into the pane.
      expect(p.left, closeTo(172 - 150, 0.001));
    });

    test('falls to ABOVE when below has no room either', () {
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(160, 600, 24, 24),
        popover: const Size(300, 200),
        pane: const Size(360, 720),
      );
      expect(p.side, HaPopoverSide.above);
      expect(p.top, 600 - 12 - 200);
    });

    test('clamps into the pane rather than hanging off it', () {
      // Badge hard against the top edge: a right-side popover centered on it
      // would start well above 0.
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(100, 0, 24, 24),
        popover: popover,
        pane: pane,
      );
      expect(p.side, HaPopoverSide.right);
      expect(p.top, greaterThanOrEqualTo(0));
      expect(p.top + popover.height, lessThanOrEqualTo(pane.height));
    });

    test('topMargin keeps the popover clear of chrome floating over the frame',
        () {
      // The back button / camera-name pill float over the frame's top-left.
      // Without the reservation the popover clamps to the pane's top edge and
      // lands underneath them. (The editor's own top bar needs no reservation:
      // it is a sibling of the video viewport, not an overlay on it.)
      const chrome = 60.0;
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(100, 56, 24, 24),
        popover: popover,
        pane: pane,
        topMargin: chrome + 8,
      );
      expect(p.top, greaterThanOrEqualTo(chrome));
    });

    test('the arrow stays inside the popover edge even when clamped', () {
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(100, 0, 24, 24),
        popover: popover,
        pane: pane,
      );
      expect(p.arrowOffset, greaterThanOrEqualTo(0));
      expect(p.arrowOffset, lessThanOrEqualTo(popover.height));
    });

    test('degrades to the roomiest side when nothing fits at all', () {
      // Pane smaller than the popover in both axes — must still return a
      // placement inside the pane instead of throwing or going negative.
      final p = resolveHaPopoverPlacement(
        badge: const Rect.fromLTWH(50, 50, 24, 24),
        popover: const Size(300, 460),
        pane: const Size(200, 200),
      );
      expect(p.left, greaterThanOrEqualTo(0));
      expect(p.top, greaterThanOrEqualTo(0));
    });
  });

  group('edit-session lifecycle', () {
    HaOverlayController controller() => HaOverlayController(
          api: CrumbApi(),
          session: Session(base: 'http://localhost:8080', token: 't'),
        );

    test('a session starts on Live and resets to Live on cancel', () {
      final host = controller()..links = [_link()];
      host.beginEditFromLoadedLinks();
      expect(host.previewState, isNull);
      host.previewState = true;
      expect(host.previewState, isTrue);
      host.cancelEdit();
      expect(host.previewState, isNull);
      host.dispose();
    });

    test('a stale preview never leaks into the next session', () {
      final host = controller()..links = [_link()];
      host.beginEditFromLoadedLinks();
      host.previewState = false;
      host.beginEditFromLoadedLinks();
      expect(host.previewState, isNull);
      host.dispose();
    });

    test('cancelEdit ends the session and drops the in-memory items', () {
      final host = controller()..links = [_link()];
      host.beginEditFromLoadedLinks();
      expect(host.editor.editMode, isTrue);
      expect(host.editor.items, hasLength(1));
      host.cancelEdit();
      expect(host.editor.editMode, isFalse);
      expect(host.editor.items, isEmpty);
      host.dispose();
    });

    test('cancelEdit on a closed session is a no-op', () {
      final host = controller();
      host.cancelEdit();
      expect(host.editor.editMode, isFalse);
      host.dispose();
    });

    test('setting the preview notifies, so the badges repaint', () {
      final host = controller()..links = [_link()];
      host.beginEditFromLoadedLinks();
      var notifications = 0;
      host.editor.addListener(() => notifications++);
      host.previewState = true;
      expect(notifications, 1);
      // Idempotent: setting the same value must not churn the badge layer.
      host.previewState = true;
      expect(notifications, 1);
      host.dispose();
    });

    test('only PLACED links become badges (unplaced stay palette entries)', () {
      final host = controller()
        ..links = [
          _link(id: 'a'),
          _link(id: 'b', entityId: 'switch.porch', placed: false),
        ];
      host.beginEditFromLoadedLinks();
      expect(host.placedIdsInSession, {'a'});
      host.dispose();
    });

    test('picking an already-placed entity re-selects instead of duplicating',
        () {
      final host = controller()..links = [_link(id: 'a')];
      host.beginEditFromLoadedLinks();
      host.pickFromPalette(host.links.first);
      expect(host.editor.items, hasLength(1));
      expect(host.editor.primarySelectedId, 'a');
      host.dispose();
    });

    test('picking an unplaced entity places it at frame centre and selects it',
        () {
      final host = controller()
        ..links = [_link(id: 'b', entityId: 'switch.porch', placed: false)];
      host.beginEditFromLoadedLinks();
      expect(host.editor.items, isEmpty);
      host.pickFromPalette(host.links.first);
      expect(host.editor.items, hasLength(1));
      expect(host.editor.primarySelectedId, 'b');
      expect(host.editor.items.first.x, closeTo(0.46, 1e-9));
      host.dispose();
    });
  });

  group('the whole frame is reachable for placement', () {
    // The editor's top bar is a SIBLING of the video viewport (the pane insets
    // the video while editing) rather than an overlay on it, so no drag has to
    // be clamped away from the top strip — which is prime badge real estate in
    // normal viewing. Regression guard for "badges cannot be placed at the top
    // of the frame".
    OverlayEditorController seeded(HaOverlayBadgeItem item) {
      final c = OverlayEditorController();
      c.beginEdit([item], anchor: OverlayAnchor.videoFrame);
      // A 16:9 video in a slightly wider pane: letterboxed left/right, so the
      // frame spans the pane's FULL height and its top edge is the pane's.
      c.updatePaneMetrics(1280, 672, videoW: 1920, videoH: 1080);
      c.selectItem(item.id);
      return c;
    }

    test('a badge drags all the way to the top edge of the frame', () {
      final item = HaOverlayBadgeItem(_link());
      final c = seeded(item);
      c.beginDrag(item.id);
      c.updateDrag(0, -5000, snap: false);
      c.endDrag();
      expect(item.y, 0.0);
      c.dispose();
    });

    test('and all the way to the bottom edge', () {
      final item = HaOverlayBadgeItem(_link());
      final c = seeded(item);
      c.beginDrag(item.id);
      c.updateDrag(0, 5000, snap: false);
      c.endDrag();
      expect(item.y, greaterThan(0.9));
      c.dispose();
    });

    test('a bottom-bar reservation still clamps (the PTZ editor relies on it)',
        () {
      final item = HaOverlayBadgeItem(_link());
      final c = seeded(item)..setEditBottomInset(200);
      c.beginDrag(item.id);
      c.updateDrag(0, 5000, snap: false);
      c.endDrag();
      // 672px frame, 200px reserved => the badge cannot reach the bottom.
      expect(item.y, lessThan(0.75));
      c.dispose();
    });
  });

  group('pill badges hug their content', () {
    // The old width was a character-count estimate that ran well wide of the
    // real text, and since `HaBadgeChip._pill` fills whatever box it is given,
    // the surplus rendered as empty pill after the label.
    test('a longer label makes a wider pill', () {
      expect(
        HaOverlayBadgeItem.pillBaseWidth('Floodlight'),
        greaterThan(HaOverlayBadgeItem.pillBaseWidth('Yard')),
      );
    });

    test('an empty label still leaves room for the icon and paddings', () {
      final bare = HaOverlayBadgeItem.pillBaseWidth('');
      expect(bare, greaterThan(HaOverlayBadgeItem.baseRefPx));
      // Chrome only: 2 paddings + icon + gap = 1.26 * the reference size.
      expect(bare, closeTo(HaOverlayBadgeItem.baseRefPx * 1.26, 0.01));
    });

    test('the width is content-derived, not the old per-character estimate',
        () {
      // The retired formula: 1.5 * ref + chars * ref * 0.42.
      const ref = HaOverlayBadgeItem.baseRefPx;
      double oldEstimate(String s) =>
          ref * 1.5 + s.length.clamp(1, 16) * ref * 0.42;
      for (final label in ['Yard', 'Floodlight', 'Back porch light']) {
        expect(
          HaOverlayBadgeItem.pillBaseWidth(label),
          lessThan(oldEstimate(label)),
          reason: label,
        );
      }
    });

    test('a runaway label is capped rather than spanning the frame', () {
      final huge = HaOverlayBadgeItem.pillBaseWidth('W' * 400);
      expect(huge, lessThanOrEqualTo(HaOverlayBadgeItem.baseRefPx * 10.3));
    });

    test('a dot is square and ignores its label entirely', () {
      final dot = HaOverlayBadgeItem(_link())
        ..labelText = 'A very long caption indeed';
      final (w, h) = dot.baseSize();
      expect(w, h);
      expect(h, HaOverlayBadgeItem.baseRefPx);
    });

    test('pill width scales with the badge size multiplier', () {
      final item = HaOverlayBadgeItem(_link())
        ..shape = 'pill'
        ..labelText = 'Floodlight';
      final w1 = item.baseSize().$1;
      item.setBaseSize(44, 44); // 2x
      final w2 = item.baseSize().$1;
      expect(w2, closeTo(w1 * 2, 0.01));
    });

    test('switching dot -> pill -> dot keeps the height stable', () {
      final item = HaOverlayBadgeItem(_link())..labelText = 'Floodlight';
      final h0 = item.baseSize().$2;
      item.shape = 'pill';
      expect(item.baseSize().$2, h0);
      item.shape = null;
      expect(item.baseSize(), (h0, h0));
    });
  });

  group('popover-editable fields survive undo', () {
    test('capture/restore covers every field the popover writes', () {
      final item = HaOverlayBadgeItem(_link());
      final pristine = item.captureState();
      item
        ..labelText = 'Porch'
        ..iconKey = 'grill'
        ..colorHex = '#123456'
        ..bgColorHex = '#654321'
        ..bgColorOnHex = '#ABCDEF'
        ..shape = 'pill'
        ..outline = true
        ..showState = true
        ..showAge = true
        ..opacity = 0.5;
      item.setBaseSize(50, 50);
      item.restoreState(pristine);
      expect(item.labelText, isNull);
      expect(item.iconKey, isNull);
      expect(item.colorHex, isNull);
      expect(item.bgColorHex, isNull);
      expect(item.bgColorOnHex, isNull);
      expect(item.shape, isNull);
      expect(item.outline, isFalse);
      expect(item.showState, isFalse);
      expect(item.showAge, isFalse);
      expect(item.opacity, 1.0);
      expect(item.baseSize().$2, HaOverlayBadgeItem.baseRefPx);
    });

    test('every icon slug the grid offers renders a real glyph', () {
      // The popover's grid iterates kHaBadgeIconChoices directly, so a slug
      // added without a glyph would silently render the fallback.
      for (final entry in kHaBadgeIconChoices.entries) {
        expect(entry.value.$1, isNotNull, reason: entry.key);
        expect(entry.value.$2, isNotEmpty, reason: entry.key);
      }
    });
  });
}
