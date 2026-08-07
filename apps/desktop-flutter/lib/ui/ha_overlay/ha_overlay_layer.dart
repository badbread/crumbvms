// View-mode HA badge layer for a wall tile / maximized pane (issue #170 P0 +
// badge-style follow-up). A thin wrapper over
// `overlay_editor/overlay_editor_layer.dart` in VIEW mode: given a camera's
// placed HA links, a live-state lookup, a staleness flag, and the pane's
// decoded-video pixel size, it renders each placed link as a badge pinned to
// its normalized position on the DISPLAYED video frame (contain-fit, so it
// survives per-tile letterboxing differences — `overlay_geometry.dart`'s
// `fieldRect`), honoring the per-badge color/icon overrides (migration 0059).
//
// Around each badge it also renders, ANCHORED TO THE BADGE's placed position
// (never pinned to a tile corner, where it used to collide with the camera
// name label and the maximized back button):
// * pinned captions — the live state text and/or relative last-changed age,
//   per the link's `overlay_show_state`/`overlay_show_age` toggles;
// * a hover reveal — mousing over a badge shows state + age even when not
//   pinned (desktop has a mouse; `OverlayEditorLayer.onHoverItem`). This is the
//   primary way to see an entity's state now that a click actuates (issue #428)
//   and applies to every badge, actuator and read-only alike;
// * click routing (issue #428, refining #187): for a badge this account can
//   control (host passed the `api`/`session`/`cameraId` plumbing AND this
//   account holds the `actuators` capability AND the link is `actuator`-role),
//   a click on a one-tap "simple" domain (light/switch/fan/siren/button/scene/
//   script — see `haPrimaryAction`) fires the primary action DIRECTLY with a
//   brief on-badge spinner, no card. Only `cover`/`lock` (`haNeedsCard`, multi-
//   action + confirm) still open the `HaStateCard` with its control buttons.
//   Every read-only / non-controllable badge opens the read-only card on click
//   exactly as before. The card is placed beside the badge, flipped/clamped
//   away from the pane edges.
// * right-click (#442 Slice 1): a simple domain's left-click direct-fires and
//   never reaches the card, so a dimmable light/fan (no dedicated card domain
//   of its own) had no gesture to reach a value slider. A right-click on any
//   controllable badge opens the detail card regardless of domain, alongside
//   left-click, which keeps firing its primary action unchanged. The card
//   itself decides whether to draw a slider (its live state's `control`
//   descriptor, gated the same way as the button row).
//
// Purely a display widget: everything comes via the constructor, no
// controller/global lookups (it builds its own private, ephemeral
// `OverlayEditorController` purely to satisfy `OverlayEditorLayer`'s generic
// plumbing — it never enters edit mode). The actual placement EDITOR is
// wired by the host (`wall_screen.dart`) using the shared editor directly;
// this file's `haBadgeItemBuilder` is exported so the host's edit-mode UI
// renders the exact same badge visual language.
//
// Usage (wall tile / maximized pane, both already fetch+cache their camera's
// HA links once per mount — see the desktop P0 plan §4.4):
//
//   Positioned.fill(
//     child: HaOverlayLayer(
//       links: _haLinks,                        // List<HaLink>, tile-cached
//       stateFor: widget.liveStatus.haStateFor,
//       stale: widget.liveStatus.haStale,
//       videoW: _videoW, videoH: _videoH,        // null until first frame
//       hideBadges: _scale > 1.01,               // digital zoom, POC rule §4.2
//     ),
//   )

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../api/crumb_api.dart';
import '../../api/ha_api.dart';
import '../../api/ha_models.dart';
import '../../api/models.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import '../overlay_editor/overlay_editor_layer.dart';
import '../overlay_editor/overlay_geometry.dart';
import 'ha_actions.dart';
import 'ha_icons.dart';
import 'ha_overlay_controller.dart' show HaOverlayBadgeItem;
import 'ha_state_card.dart';

/// Build an `OverlayItemBuilder` bound to a specific state lookup — used
/// identically by [HaOverlayLayer] (view mode, internally) and by the host's
/// maximized-pane "Edit HA overlay…" UI
/// (`OverlayEditorLayer(..., buildItem: haBadgeItemBuilder(stateFor: ...,
/// stale: ...))`), so both modes render the exact same badge visual
/// language — including the per-badge color/icon overrides, read from the
/// item (which carries the session-edited values while editing and the
/// link-stored values in view mode).
OverlayItemBuilder haBadgeItemBuilder({
  required HaEntityState? Function(String entityId) stateFor,
  required bool stale,
  Set<String> pendingLinkIds = const {},
  bool? previewState,
}) {
  return (item, {required bool editing, required bool selected}) {
    final badge = item as HaOverlayBadgeItem;
    final link = badge.link;
    final live = stateFor(link.entityId);
    final state = haPreviewedState(previewState, live?.state);
    final effStale = haPreviewedStale(previewState, stale);
    final visual = haVisualFor(
      domain: link.domain,
      deviceClass: link.deviceClass,
      state: state,
      stale: effStale,
      iconOverride: badge.iconKey,
      colorOverride: parseOverlayColorHex(badge.colorHex),
    );
    return HaBadgeChip(
      visual: visual,
      selected: selected,
      isPill: badge.isPill,
      pillLabel: badge.pillLabel,
      bgColor: parseOverlayColorHex(badge.bgColorHex),
      bgColorOn: parseOverlayColorHex(badge.bgColorOnHex),
      textAlign: badge.textAlign,
      on: haEdgeOnFor(domain: link.domain, state: state, stale: effStale),
      outline: badge.outline,
      // Jelly motion (entrance pop + state-change squish) runs only in view
      // mode; while editing the badge is a static drag target.
      animate: !editing,
      // A change in this key (state string / staleness) drives the squish.
      stateKey: '${state ?? ''}|$effStale',
      // Brief in-flight spinner for a direct-click actuation (issue #428) while
      // the 3s /ha/states poll converges. Never set while editing.
      pending: !editing && pendingLinkIds.contains(link.id),
    );
  };
}

/// Apply the HA editor's state preview (`HaOverlayController.previewState`) to
/// a badge's live state string. `null` (Live, and the ONLY value any viewing
/// surface ever passes) returns the real reading untouched; `true`/`false`
/// substitute the canonical `on`/`off` HA state words so every downstream
/// consumer — `edgeOn`, `haEdgeOnFor`, the accent color, the per-state
/// background, the caption text — resolves exactly as it would for a real
/// device in that state, with no second code path to drift.
///
/// Pure so the substitution rule is unit-testable without pumping a widget.
String? haPreviewedState(bool? previewState, String? live) =>
    previewState == null ? live : (previewState ? 'on' : 'off');

/// Staleness under the same preview. A forced On/Off preview must also clear
/// staleness: `haEdgeOnFor` gates every state-varying visual to null while the
/// feed is stale, so leaving it set would grey out the badge and hide the very
/// colors the operator is picking. Live (`null`) passes real staleness through
/// unchanged.
bool haPreviewedStale(bool? previewState, bool stale) =>
    previewState == null && stale;

/// The default opaque badge background (migration 0062) — a near-black chip,
/// dimmed only by the item's `overlay_opacity` (applied by the overlay layer's
/// `Opacity` wrapper), NOT a hardcoded translucent scrim. This is the #170
/// readability fix: at the default opacity the chip reads solid.
const Color _kBadgeDefaultBg = Color(0xFF17171B);

/// Resolve the badge's solid background per the per-state override contract
/// (wave A, `overlay_bg_color_on`): entity ON ⇒ `bgColorOn ?? bgColor ??
/// default`; OFF, indeterminate/unknown, or stale ⇒ `bgColor ?? default`. A
/// scene or an unknown/stale reading NEVER picks the on-color — [on] must
/// come from `ha_icons.dart`'s [haEdgeOnFor] (the same honesty gate that
/// drives the accent dim), never a raw `edgeOn()` call, so a badge's
/// background and its icon accent can never disagree about whether the
/// entity is "really" on. Pulled out of [HaBadgeChip] as a pure function so
/// the resolution order itself is unit-testable without pumping a widget.
Color resolveBadgeBg({required bool? on, Color? bgColor, Color? bgColorOn}) {
  if (on == true && bgColorOn != null) return bgColorOn;
  return bgColor ?? _kBadgeDefaultBg;
}

/// The pill LAYOUT contract (migration 0078, issue #497) — the same closed
/// vocabulary the server validates (`services/api/src/ha.rs`'s
/// `HA_PILL_WIDTH_MODES` / `HA_TEXT_ALIGNS`), the console authors, and the
/// Android/iOS renderers switch on. Changing a spelling here without changing
/// it in all five places is the divergence these lists exist to prevent.
const List<String> kHaPillWidthModes = ['auto', 'narrow', 'medium', 'wide'];
const List<String> kHaTextAligns = ['start', 'center', 'end'];

/// A fixed pill width as a multiple of the pill's HEIGHT, or null for `auto`
/// (and for any unknown value from a newer server — degrade to today's
/// hug-the-content width rather than guess).
///
/// Height is the multiplier's unit deliberately: it is the one length every
/// renderer already derives identically from `overlay_size` and the pane
/// scale, so `medium` means the same pill on a phone, a wall tile and a
/// maximized pane. A fixed width is EXACT, not a minimum — a label too long
/// for it ellipsizes, which is what makes several badges set to the same mode
/// actually line up.
double? haPillWidthFactor(String? mode) {
  switch (mode) {
    case 'narrow':
      return 4.0;
    case 'medium':
      return 6.0;
    case 'wide':
      return 8.0;
    default:
      return null; // 'auto', null, or anything unrecognized
  }
}

/// Where the pill's icon + label group sits inside the pill. `null`/`'start'`
/// (and anything unrecognized) is the leading edge — today's layout.
MainAxisAlignment haPillAlignment(String? align) {
  switch (align) {
    case 'center':
      return MainAxisAlignment.center;
    case 'end':
      return MainAxisAlignment.end;
    default:
      return MainAxisAlignment.start;
  }
}

/// The pill chip's INTERNAL metrics at one rendered height — the single source
/// of the factors AND their clamps, shared by the renderer ([HaBadgeChip._pill],
/// which lays the chip out) and by the measurement
/// (`HaOverlayBadgeItem.pillWidthAtHeight`, which sizes the box the chip is
/// handed). They MUST come from here in both places: the whole class of bug
/// this fixes is the two sides disagreeing.
///
/// Why the clamps matter for the width: each part is a fraction of the height
/// *until* it hits a floor or a ceiling, so the content's width is NOT linear
/// in the height. Sizing the box from the un-clamped fractions made a small
/// wall-tile pill narrower than the content it had to draw — at a rendered
/// height under ~21px the 8px font floor (and the 10/5/3px icon/padding/gap
/// floors) are active — so `TextOverflow.ellipsis` chopped "Floodlight" into
/// "Floodli…". The same mismatch runs the other way past ~57px, where the
/// ceilings cap the content and the box kept growing, leaving dead space after
/// the label.
class HaPillMetrics {
  const HaPillMetrics({
    required this.height,
    required this.iconSize,
    required this.fontSize,
    required this.padH,
    required this.gap,
  });

  /// Every part of a pill derives from the height it is RENDERED at — not from
  /// the item's base size, which is the same number only at pane-scale 1.0.
  factory HaPillMetrics.forHeight(double height) => HaPillMetrics(
        height: height,
        iconSize: (height * 0.56).clamp(10.0, 40.0).toDouble(),
        fontSize: (height * 0.40).clamp(8.0, 26.0).toDouble(),
        padH: (height * 0.28).clamp(5.0, 16.0).toDouble(),
        gap: (height * 0.14).clamp(3.0, 8.0).toDouble(),
      );

  final double height;
  final double iconSize;
  final double fontSize;

  /// Horizontal padding, EACH side.
  final double padH;

  /// Icon-to-label gap.
  final double gap;

  /// Width of everything inside the pill for a label whose advance is
  /// [labelWidthPerFontPx] logical px per 1px of font size (measured once per
  /// label by `HaOverlayBadgeItem.labelWidthPerFontPx`).
  ///
  /// The label is capped at 9 pill-heights so one runaway caption can't span
  /// the frame; the chip ellipsizes past that, which is the graceful
  /// degradation the cap is there for.
  double contentWidth(double labelWidthPerFontPx) {
    final text =
        (labelWidthPerFontPx * fontSize).clamp(0.0, height * 9).toDouble();
    return padH * 2 + iconSize + gap + text;
  }
}

/// Snappy spring (matches the operator-chosen preview: k380 / damping 21).
const SpringDescription _kJellySpring = SpringDescription(
  mass: 1.0,
  stiffness: 380.0,
  damping: 21.0,
);

/// The badge chip: a `dot` (compact icon) or `pill` (icon + label) with a
/// solid, opaque background (color pickable), an optional white outline + drop
/// shadow so it pops on a busy scene, and snappy "jelly" motion in view mode —
/// a spring pop-in on appear and a squish-and-rebound whenever the entity's
/// state changes. Sizes itself to fill whatever rect the overlay layer gives it
/// (`overlay_editor_layer.dart`'s `SizedBox`/`Positioned` wrap) — for a pill
/// that rect is pre-widened by `HaOverlayBadgeItem.renderedSize()`, which
/// measures the content with the SAME [HaPillMetrics] this chip lays itself
/// out from, at the same rendered height.
class HaBadgeChip extends StatefulWidget {
  const HaBadgeChip({
    super.key,
    required this.visual,
    this.selected = false,
    this.isPill = false,
    this.pillLabel,
    this.bgColor,
    this.bgColorOn,
    this.textAlign,
    this.on,
    this.outline = false,
    this.animate = false,
    this.stateKey,
    this.pending = false,
  });

  final HaVisual visual;
  final bool selected;

  /// Render as a labelled pill (vs the compact icon dot).
  final bool isPill;

  /// Text inside the pill (ignored for a dot).
  final String? pillLabel;

  /// Solid background color for an OFF/indeterminate/stale/scene reading (or
  /// the only color, when [bgColorOn] is unset); null = the default dark chip
  /// ([_kBadgeDefaultBg]).
  final Color? bgColor;

  /// Solid background color for an ON reading (wave A per-state override);
  /// null = no override, so the badge keeps [bgColor] regardless of state.
  /// See [resolveBadgeBg] for the exact resolution order.
  final Color? bgColorOn;

  /// Where the pill's icon + label group sits inside the pill (migration
  /// 0078): `'start'` (or null, today's layout), `'center'`, `'end'`. Only
  /// observable once the pill is wider than its content, i.e. with a fixed
  /// `overlay_pill_width`. Ignored by a dot. See [haPillAlignment].
  final String? textAlign;

  /// The honesty-gated on/off reading driving [bgColorOn] (must come from
  /// `ha_icons.dart`'s `haEdgeOnFor`, the same gate behind [visual]'s accent
  /// dim) — null for a scene, a stale feed, or no known state yet.
  final bool? on;

  /// Draw a white outline + drop shadow.
  final bool outline;

  /// Run the jelly animation (view mode only — off while editing).
  final bool animate;

  /// Opaque token; a change (state/staleness) triggers the squish.
  final Object? stateKey;

  /// Overlay a brief spinner while a direct-click actuation is in flight /
  /// settling (issue #428). Purely cosmetic; the badge's real state still
  /// arrives via the state poll.
  final bool pending;

  @override
  State<HaBadgeChip> createState() => _HaBadgeChipState();
}

class _HaBadgeChipState extends State<HaBadgeChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scale;

  @override
  void initState() {
    super.initState();
    _scale = AnimationController.unbounded(vsync: this, value: 1.0);
    if (widget.animate) {
      // Entrance pop: spring up from nothing with a slight overshoot.
      _scale.value = 0.0;
      _scale.animateWith(SpringSimulation(_kJellySpring, 0.0, 1.0, 0.0));
    }
  }

  @override
  void didUpdateWidget(covariant HaBadgeChip old) {
    super.didUpdateWidget(old);
    // State changed while live → squish: kick the spring with a negative
    // velocity from the current scale so it dips then rebounds to 1.
    if (widget.animate && widget.stateKey != old.stateKey) {
      _scale.animateWith(
        SpringSimulation(_kJellySpring, _scale.value, 1.0, -7.0),
      );
    }
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chip = LayoutBuilder(
      builder: (context, constraints) => widget.isPill
          ? _pill(constraints.biggest.height)
          : _dot(constraints.biggest.shortestSide),
    );
    final Widget content = !widget.animate
        ? chip
        : AnimatedBuilder(
            animation: _scale,
            builder: (context, child) => Transform.scale(
              scale: _scale.value <= 0 ? 0.0 : _scale.value,
              child: child,
            ),
            child: chip,
          );
    if (!widget.pending) return content;
    return _withPendingOverlay(content);
  }

  /// A centered spinner over the badge while a direct-click action is in flight
  /// (issue #428). Sized to the badge so it stays proportional on a small tile.
  Widget _withPendingOverlay(Widget child) => Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final d = (constraints.biggest.shortestSide * 0.52)
                    .clamp(10.0, 22.0)
                    .toDouble();
                return Center(
                  child: SizedBox(
                    width: d,
                    height: d,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );

  BoxDecoration _decoration(BoxShape shape, BorderRadius? radius) {
    final bg = resolveBadgeBg(
      on: widget.on,
      bgColor: widget.bgColor,
      bgColorOn: widget.bgColorOn,
    );
    return BoxDecoration(
      color: bg,
      shape: shape,
      borderRadius: radius,
      border: widget.selected
          ? Border.all(color: Colors.white, width: 2.4)
          : (widget.outline
              ? Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1.6)
              : null),
      boxShadow: widget.outline
          ? const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 5,
                offset: Offset(0, 2),
              ),
            ]
          : null,
    );
  }

  Widget _dot(double side) => DecoratedBox(
        decoration: _decoration(BoxShape.circle, null),
        child: Center(
          child: Icon(
            widget.visual.icon,
            color: widget.visual.color,
            size: (side * 0.58).clamp(10.0, 40.0).toDouble(),
          ),
        ),
      );

  Widget _pill(double height) {
    // Metrics come from the SHARED source so the box the layer measured
    // (`HaOverlayBadgeItem.pillWidthAtHeight`, via `OverlayGeometry.rectFor`)
    // and the content drawn here can't drift apart — see [HaPillMetrics].
    final m = HaPillMetrics.forHeight(height);
    final iconSize = m.iconSize;
    final fontSize = m.fontSize;
    final padH = m.padH;
    final gap = m.gap;
    final bg = resolveBadgeBg(
      on: widget.on,
      bgColor: widget.bgColor,
      bgColorOn: widget.bgColorOn,
    );
    // Label uses a neutral that always reads on the chosen background; the
    // icon carries the state color.
    final labelColor =
        bg.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return DecoratedBox(
      decoration: _decoration(
        BoxShape.rectangle,
        BorderRadius.circular(height / 2),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: padH),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          // Auto-width pills have no slack, so this only bites once the
          // operator has pinned a fixed width (migration 0078).
          mainAxisAlignment: haPillAlignment(widget.textAlign),
          children: [
            Icon(widget.visual.icon, color: widget.visual.color, size: iconSize),
            SizedBox(width: gap),
            Flexible(
              child: Text(
                widget.pillLabel ?? '',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: labelColor,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pinned/hover captions (live state text + relative age) for a set of
/// placed badges, laid over the same video-frame geometry as the badges
/// themselves. Extracted so BOTH view mode (`HaOverlayLayer`) and the maximized
/// pane's EDIT mode can show them — in edit mode driven by the editor's live
/// items, so toggling "Pin state"/"Pin time" previews immediately instead of
/// only after save. Non-interactive (the whole layer is wrapped in
/// `IgnorePointer` by the caller in edit mode; in view mode each chip is its
/// own `IgnorePointer`). Caption size scales with the badge's rendered size, so
/// it stays legible-but-proportional on a small wall tile (issue: captions were
/// a fixed size in a fixed 180px anchor box that drifted off small tiles).
class HaBadgeCaptions extends StatelessWidget {
  const HaBadgeCaptions({
    super.key,
    required this.items,
    required this.stateFor,
    required this.stale,
    required this.videoW,
    required this.videoH,
    this.hoverLinkId,
    this.previewState,
  });

  final List<HaOverlayBadgeItem> items;
  final HaEntityState? Function(String entityId) stateFor;
  final bool stale;
  final int? videoW;
  final int? videoH;

  /// Link id currently hovered (view mode) — reveals its state+age even when
  /// not pinned. Null in edit mode.
  final String? hoverLinkId;

  /// The edit session's state preview (`HaOverlayController.previewState`) —
  /// always null in view mode. Applied through the same [haPreviewedState] /
  /// [haPreviewedStale] pair as the badge itself so a pinned caption can never
  /// disagree with the glyph it is captioning.
  final bool? previewState;

  @override
  Widget build(BuildContext context) {
    if (videoW == null || videoH == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final paneW = constraints.maxWidth;
        final paneH = constraints.maxHeight;
        if (paneW <= 0 || paneH <= 0) return const SizedBox.shrink();
        final children = <Widget>[];
        for (final item in items) {
          final hovered = item.id == hoverLinkId;
          if (!item.showState && !item.showAge && !hovered) continue;
          final w = _captionFor(item, paneW, paneH, hovered);
          if (w != null) children.add(w);
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(clipBehavior: Clip.none, children: children);
      },
    );
  }

  Widget? _captionFor(
    HaOverlayBadgeItem item,
    double paneW,
    double paneH,
    bool hovered,
  ) {
    final (x, y, w, h) = OverlayGeometry.rectFor(
      item,
      paneW,
      paneH,
      videoW: videoW,
      videoH: videoH,
    );
    final link = item.link;
    final state = stateFor(link.entityId);
    final shownState = haPreviewedState(previewState, state?.state);
    final effStale = haPreviewedStale(previewState, stale);
    final visual = haVisualFor(
      domain: link.domain,
      deviceClass: link.deviceClass,
      state: shownState,
      stale: effStale,
      iconOverride: item.iconKey,
      colorOverride: parseOverlayColorHex(item.colorHex),
    );

    final showState = item.showState || hovered;
    final showAge = (item.showAge || hovered) && state?.lastChanged != null;
    // A Dot renders icon-only (unlike a Pill, which shows its label inline), so
    // when the operator has given a Dot an explicit label, surface it as a
    // caption line — the compact-Dot analogue of the Pill's inline label
    // (#255). Gated on a non-empty operator label so unlabeled Dots stay
    // icon-only, and suppressed while hovering (the hover line already shows the
    // name). Rides the link's existing `label` — no new persisted field.
    final showLabel = !item.isPill &&
        !hovered &&
        (item.labelText?.trim().isNotEmpty ?? false);
    if (!showState && !showAge && !hovered && !showLabel) return null;

    // Scale text with the badge so captions stay proportional on small tiles.
    final fState = (h * 0.42).clamp(8.0, 13.0).toDouble();
    final fAge = (h * 0.34).clamp(7.0, 11.0).toDouble();
    final gap = (h * 0.14).clamp(2.0, 6.0).toDouble();

    final lines = <Widget>[
      if (hovered)
        Text(
          item.displayLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: fState,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (showLabel)
        Text(
          item.pillLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: fState,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (showState)
        Text(
          haStateDisplay(visual: visual, state: shownState, unit: state?.unit),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: visual.color,
            fontSize: fState,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (showAge)
        Text(
          haRelativeAgo(state!.lastChanged!),
          maxLines: 1,
          style: TextStyle(color: Colors.white70, fontSize: fAge),
        ),
    ];
    if (lines.isEmpty) return null;

    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: (h * 0.16).clamp(4.0, 8.0).toDouble(),
        vertical: (h * 0.08).clamp(2.0, 4.0).toDouble(),
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: lines,
      ),
    );

    // Center the chip on the badge horizontally (FractionalTranslation, so no
    // fixed anchor box to drift), placed just below — flipped above near the
    // bottom edge. Overflow at the tile edge is clipped by the tile, far less
    // wrong than the old center-in-a-wide-box drift.
    final cx = x + w / 2;
    final estH = fState * (lines.length) * 1.4 + 8;
    final below = y + h + gap + estH <= paneH;
    return Positioned(
      left: cx,
      top: below ? y + h + gap : null,
      bottom: below ? null : (paneH - y + gap),
      child: FractionalTranslation(
        translation: const Offset(-0.5, 0),
        child: chip,
      ),
    );
  }
}

class HaOverlayLayer extends StatefulWidget {
  const HaOverlayLayer({
    super.key,
    required this.links,
    required this.stateFor,
    this.stale = false,
    this.videoW,
    this.videoH,
    this.hideBadges = false,
    this.api,
    this.session,
    this.cameraId,
    this.canActuate = false,
  });

  /// The camera's linked entities (incl. placement) — only the PLACED ones
  /// render a badge.
  final List<HaLink> links;

  /// Live-state lookup, e.g. `LiveStatusController.haStateFor`. Returns null
  /// when no state is known yet for that entity.
  final HaEntityState? Function(String entityId) stateFor;

  /// True when the HA states feed is stale (poll failures) — every badge
  /// renders the grey/dim "unknown" treatment regardless of its last-known
  /// state (never shows a possibly-false closed/off — mirrors the backend's
  /// `edge_on` invariant).
  final bool stale;

  /// Decoded video pixel size — needed to map a video-frame-fraction
  /// placement onto the letterboxed video rect. Badges render nothing until
  /// both are known (a sub-second window right after a stream opens).
  final int? videoW;
  final int? videoH;

  /// Digital-zoom gate (POC rule, desktop P0 plan §4.2): badges sit outside
  /// the pane's zoom `Transform`, so a zoomed pane would misplace them —
  /// hide entirely while zoomed rather than draw them wrong. Pass
  /// `_scale > 1.01`.
  final bool hideBadges;

  /// Actuation plumbing (issue #187). All three must be non-null for the tap
  /// card to offer controls; a host that hasn't wired them keeps today's
  /// read-only card.
  final CrumbApi? api;
  final Session? session;
  final String? cameraId;

  /// Server-side truth (`GET /auth/me` → `capabilities.actuators`, see
  /// `MeResponse.canActuate`) for whether this account may actuate. False —
  /// including against an older server that doesn't send the key — renders
  /// the card exactly as it is today, with no hint that controls exist.
  final bool canActuate;

  @override
  State<HaOverlayLayer> createState() => _HaOverlayLayerState();
}

class _HaOverlayLayerState extends State<HaOverlayLayer> {
  /// Ephemeral controller purely to satisfy `OverlayEditorLayer`'s generic
  /// plumbing in VIEW mode — never enters edit mode, never leaves this
  /// widget's private state.
  final OverlayEditorController _viewController = OverlayEditorController();

  /// Link id of the currently-open state card, if any.
  String? _openLinkId;

  /// Link id currently under the mouse (hover reveal of state + age).
  String? _hoverLinkId;

  /// Link ids with a direct-click action in flight / settling (issue #428) —
  /// each shows a brief spinner on its badge while the 3s `/ha/states` poll
  /// converges the real state. Kept per-link so several badges can be mid-flight
  /// at once.
  final Set<String> _pendingLinkIds = {};
  final Map<String, Timer> _settleTimers = {};

  /// How long the badge keeps its spinner after the POST lands, matching the
  /// card's settle window so the operator sees the request took before the next
  /// state poll (3s) speaks for itself.
  static const Duration _kBadgeSettle = Duration(milliseconds: 3200);

  static const double _cardWidth = 260;

  /// Rough height estimates for flip/clamp decisions (the real widgets
  /// self-size; these only pick which side of the badge to render on).
  static const double _cardEstHeight = 150;

  /// Extra estimated height once the card carries a control row (issue #187).
  static const double _cardControlsEstHeight = 52;

  /// Extra estimated height once the card carries a value slider row (#442
  /// Slice 1) — caption/value line + the `Slider` itself.
  static const double _cardValueEstHeight = 54;

  @override
  void dispose() {
    for (final t in _settleTimers.values) {
      t.cancel();
    }
    _viewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hideBadges || widget.videoW == null || widget.videoH == null) {
      return const SizedBox.shrink();
    }
    final placed = [for (final l in widget.links) if (l.hasPlacement) l];
    if (placed.isEmpty) return const SizedBox.shrink();

    final items = [for (final l in placed) HaOverlayBadgeItem(l)];
    final open = _findLink(placed, _openLinkId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final paneW = constraints.maxWidth;
        final paneH = constraints.maxHeight;
        if (paneW <= 0 || paneH <= 0) return const SizedBox.shrink();

        (double, double, double, double) rectOf(HaOverlayBadgeItem item) =>
            OverlayGeometry.rectFor(
              item,
              paneW,
              paneH,
              videoW: widget.videoW,
              videoH: widget.videoH,
            );

        return Stack(
          children: [
            // See overlay_editor_layer.dart's usage contract — it must be
            // given TIGHT constraints via Positioned.fill, or its inner Stack
            // (which clips) collapses to zero size under this Stack's default
            // loose constraints for non-positioned children.
            Positioned.fill(
              child: OverlayEditorLayer(
                controller: _viewController,
                editing: false,
                items: items,
                videoW: widget.videoW,
                videoH: widget.videoH,
                buildItem: haBadgeItemBuilder(
                  stateFor: widget.stateFor,
                  stale: widget.stale,
                  pendingLinkIds: _pendingLinkIds,
                ),
                onTapItem: (item) =>
                    _handleTap((item as HaOverlayBadgeItem).link),
                onSecondaryTapItem: (item) =>
                    _handleSecondaryTap((item as HaOverlayBadgeItem).link),
                onHoverItem: (item, hovering) {
                  final next = hovering
                      ? item.id
                      : (_hoverLinkId == item.id ? null : _hoverLinkId);
                  if (next != _hoverLinkId) {
                    setState(() => _hoverLinkId = next);
                  }
                },
              ),
            ),

            // Pinned / hover-revealed captions (shared with the edit-mode
            // live preview via HaBadgeCaptions).
            Positioned.fill(
              child: IgnorePointer(
                child: HaBadgeCaptions(
                  items: items,
                  stateFor: widget.stateFor,
                  stale: widget.stale,
                  videoW: widget.videoW,
                  videoH: widget.videoH,
                  hoverLinkId: _hoverLinkId,
                ),
              ),
            ),

            if (open != null) ...[
              // Tap-away scrim: any tap outside the card dismisses it. Sits
              // ABOVE the badge layer in paint/hit-test order, BELOW the card
              // itself (which swallows its own taps — see `HaStateCard`).
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _openLinkId = null),
                  child: const SizedBox.expand(),
                ),
              ),
              _positionedCard(open, items, rectOf, paneW, paneH),
            ],
          ],
        );
      },
    );
  }

  HaLink? _findLink(List<HaLink> placed, String? id) {
    if (id == null) return null;
    for (final l in placed) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Whether this caller can actuate [link]: the account holds the `actuators`
  /// capability, the link is an `actuator` role (a motion/door sensor is never
  /// controllable, even for an admin), and the host wired the POST plumbing.
  bool _canControl(HaLink link) {
    if (!widget.canActuate || link.role != 'actuator') return false;
    return widget.api != null &&
        widget.session != null &&
        widget.cameraId != null;
  }

  /// Route a badge tap (issue #428). For a controllable badge whose domain is a
  /// one-tap "simple" domain (light/switch/fan/siren/button/scene/script) the
  /// click fires the primary action DIRECTLY, no card. `cover`/`lock`
  /// ([haNeedsCard]) and every read-only / non-controllable badge fall through
  /// to toggling the detail card (which, for cover/lock, still carries the
  /// multi-action buttons + confirm dialog).
  void _handleTap(HaLink link) {
    if (_canControl(link)) {
      final primary = haPrimaryAction(link.domain);
      // Direct-fire only when the link neither requires a confirm nor restricts
      // its primary action away (migration 0075). A require_confirm link, or one
      // whose primary is not in its allowed_actions, falls through to the card,
      // which confirms and/or shows only the permitted actions.
      if (primary != null &&
          !link.requireConfirm &&
          link.actionAllowed(primary.action)) {
        unawaited(_fireDirect(link, primary));
        return;
      }
    }
    setState(() => _openLinkId = _openLinkId == link.id ? null : link.id);
  }

  /// Right-click routing (#442 Slice 1): open the detail card for ANY
  /// controllable badge, regardless of domain — the one gesture that reaches
  /// a value slider on a simple domain (light/fan) whose left-click already
  /// direct-fires and so never falls through to the card. A no-op on a
  /// non-controllable badge (nothing to show beyond the read-only card
  /// left-click already offers).
  void _handleSecondaryTap(HaLink link) {
    if (!_canControl(link)) return;
    setState(() => _openLinkId = link.id);
  }

  /// POST a direct-click action and show a brief in-flight spinner on the badge
  /// itself (issue #428). Reuses [_runAction]'s optimistic-never-flip-locally +
  /// toast-on-failure behavior; the spinner rides the settle window, then the
  /// 3s `/ha/states` poll converges the badge.
  Future<void> _fireDirect(HaLink link, HaControlAction action) async {
    if (_pendingLinkIds.contains(link.id)) return;
    setState(() => _pendingLinkIds.add(link.id));
    final ok = await _runAction(link, action.action);
    if (!mounted) return;
    if (!ok) {
      // _runAction already toasted; drop the spinner so the operator can retry.
      setState(() => _pendingLinkIds.remove(link.id));
      return;
    }
    // Accepted: hold the spinner through the convergence window.
    _settleTimers[link.id]?.cancel();
    _settleTimers[link.id] = Timer(_kBadgeSettle, () {
      if (!mounted) return;
      setState(() => _pendingLinkIds.remove(link.id));
    });
  }

  /// The control buttons to offer for [link] (issue #187), or empty for the
  /// read-only card. Gated by [_canControl]; the domain table then decides the
  /// button set, mirroring the server's allow-list. In practice only the card
  /// domains (`cover`/`lock`) reach here controllable, since simple domains
  /// actuate on a direct click (issue #428) and never open the card.
  List<HaControlAction> _actionsFor(HaLink link) {
    if (!_canControl(link)) return const [];
    // allowed_actions null ⇒ the full default set for the domain (today's
    // behavior). Non-null ⇒ present ONLY the permitted actions, intersected with
    // the domain's full action set (migration 0075, issue #440).
    final allowed = link.allowedActions;
    if (allowed == null) return haActionsForDomain(link.domain);
    return haAllActionsForDomain(link.domain)
        .where((a) => allowed.contains(a.action))
        .toList();
  }

  /// The value slider's capability descriptor for [link] (#442 Slice 1), or
  /// null to draw no slider at all. Gated exactly like [_actionsFor]: this
  /// account must be able to control the link AND (`allowed_actions` null, or
  /// it names the descriptor's own value word — migration 0075's existing
  /// per-link restriction, reused as-is for the value word). The descriptor
  /// itself comes from the live state feed, so it is null whenever the entity
  /// currently has nothing settable (e.g. a non-dimmable light).
  HaControlDescriptor? _controlFor(HaLink link) {
    if (!_canControl(link)) return null;
    final control = widget.stateFor(link.entityId)?.control;
    if (control == null || !link.actionAllowed(control.action)) return null;
    return control;
  }

  /// POST the action and surface any failure as a toast. Never throws; returns
  /// whether the server accepted it, which is all the card needs to decide
  /// between "settling" and "hand the buttons back". Deliberately does NOT
  /// flip the badge locally: the 3s `/ha/states` poll converges the state.
  ///
  /// [value] carries a value slider's committed target (#442 Slice 1,
  /// `HaControlDescriptor.action`) — null for every discrete button action.
  Future<bool> _runAction(HaLink link, String action, {double? value}) async {
    final api = widget.api;
    final session = widget.session;
    final cameraId = widget.cameraId;
    if (api == null || session == null || cameraId == null) return false;
    try {
      await api.haAction(
        session,
        cameraId,
        linkId: link.id,
        action: action,
        value: value,
      );
      return true;
    } on CrumbApiException catch (e) {
      _toast(
        e.statusCode == 403
            ? 'Not permitted: this account cannot control devices.'
            : 'Action failed. ${e.message}',
      );
    } catch (_) {
      _toast('Action failed. The server could not be reached.');
    }
    return false;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  /// The tap card, placed BESIDE the tapped badge (right by preference,
  /// flipped left near the right edge; vertically clamped into the pane) —
  /// fixes the old corner-pinned card colliding with the camera-name label /
  /// maximized back button.
  Widget _positionedCard(
    HaLink open,
    List<HaOverlayBadgeItem> items,
    (double, double, double, double) Function(HaOverlayBadgeItem) rectOf,
    double paneW,
    double paneH,
  ) {
    HaOverlayBadgeItem? item;
    for (final i in items) {
      if (i.id == open.id) {
        item = i;
        break;
      }
    }
    final (x, y, w, _) = item != null ? rectOf(item) : (12.0, 12.0, 0.0, 0.0);
    var left = x + w + 8;
    if (left + _cardWidth > paneW - 4) {
      left = (x - 8 - _cardWidth).clamp(4.0, double.infinity).toDouble();
    }
    final actions = _actionsFor(open);
    final control = _controlFor(open);
    final estHeight = _cardEstHeight +
        (actions.isEmpty ? 0.0 : _cardControlsEstHeight) +
        (control == null ? 0.0 : _cardValueEstHeight);
    final top = y
        .clamp(4.0, (paneH - estHeight).clamp(4.0, double.infinity))
        .toDouble();
    return Positioned(
      left: left,
      top: top,
      child: HaStateCard(
        entityId: open.entityId,
        friendlyName: open.displayLabel,
        domain: open.domain,
        deviceClass: open.deviceClass,
        state: widget.stateFor(open.entityId),
        stale: widget.stale,
        iconOverride: open.overlayIcon,
        colorOverride: parseOverlayColorHex(open.overlayColor),
        requireConfirm: open.requireConfirm,
        onDismiss: () => setState(() => _openLinkId = null),
        actions: actions,
        onAction: actions.isEmpty
            ? null
            : (action) => _runAction(open, action),
        control: control,
        onValueAction: control == null
            ? null
            : (action, value) => _runAction(open, action, value: value),
      ),
    );
  }
}
