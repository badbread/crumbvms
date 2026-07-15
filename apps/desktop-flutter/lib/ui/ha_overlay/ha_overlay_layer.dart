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
//   pinned (desktop has a mouse; `OverlayEditorLayer.onHoverItem`);
// * the read-only `HaStateCard` on tap, placed beside the badge and flipped/
//   clamped away from the pane edges.
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

import 'package:flutter/material.dart';

import '../../api/ha_models.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import '../overlay_editor/overlay_editor_layer.dart';
import '../overlay_editor/overlay_geometry.dart';
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
}) {
  return (item, {required bool editing, required bool selected}) {
    final badge = item as HaOverlayBadgeItem;
    final link = badge.link;
    final state = stateFor(link.entityId);
    final visual = haVisualFor(
      domain: link.domain,
      deviceClass: link.deviceClass,
      state: state?.state,
      stale: stale,
      iconOverride: badge.iconKey,
      colorOverride: parseOverlayColorHex(badge.colorHex),
    );
    return HaBadgeChip(visual: visual, selected: selected);
  };
}

/// The badge chip itself: a circular dark-scrim container with the resolved
/// icon, matching the tile-badge visual language (black-0.55 rounded scrim,
/// `live_status/live_status_badges.dart`). Sizes itself to fill whatever
/// rect the overlay layer gives it (see `overlay_editor_layer.dart`'s
/// `SizedBox` wrap) and scales the icon/border proportionally.
class HaBadgeChip extends StatelessWidget {
  const HaBadgeChip({super.key, required this.visual, this.selected = false});

  final HaVisual visual;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : visual.color.withValues(alpha: 0.85),
              width: selected ? 2.4 : (side * 0.06).clamp(1.0, 2.5).toDouble(),
            ),
          ),
          child: Center(
            child: Icon(
              visual.icon,
              color: visual.color,
              size: (side * 0.58).clamp(10.0, 40.0).toDouble(),
            ),
          ),
        );
      },
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

  static const double _cardWidth = 260;

  /// Rough height estimates for flip/clamp decisions (the real widgets
  /// self-size; these only pick which side of the badge to render on).
  static const double _cardEstHeight = 150;
  static const double _captionEstHeight = 40;

  @override
  void dispose() {
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
                ),
                onTapItem: (item) => setState(
                  () => _openLinkId = _openLinkId == item.id ? null : item.id,
                ),
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

            // Pinned / hover-revealed captions, anchored to each badge.
            for (final item in items)
              if (item.showState ||
                  item.showAge ||
                  item.id == _hoverLinkId)
                ..._captionFor(item, rectOf(item), paneW, paneH),

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

  /// The caption chip(s) for one badge: live state text (pinned via
  /// `overlay_show_state` or hover) and/or relative age (`overlay_show_age`
  /// or hover), rendered just below the badge — flipped above it near the
  /// bottom edge, clamped horizontally. Non-interactive (IgnorePointer) so
  /// the video pane's own gestures keep working through them.
  List<Widget> _captionFor(
    HaOverlayBadgeItem item,
    (double, double, double, double) rect,
    double paneW,
    double paneH,
  ) {
    final (x, y, w, h) = rect;
    final link = item.link;
    final hovered = item.id == _hoverLinkId;
    final state = widget.stateFor(link.entityId);
    final visual = haVisualFor(
      domain: link.domain,
      deviceClass: link.deviceClass,
      state: state?.state,
      stale: widget.stale,
      iconOverride: item.iconKey,
      colorOverride: parseOverlayColorHex(item.colorHex),
    );

    final showState = item.showState || hovered;
    final showAge = (item.showAge || hovered) && state?.lastChanged != null;
    if (!showState && !showAge) return const [];

    final lines = <Widget>[
      if (hovered)
        Text(
          item.displayLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (showState)
        Text(
          visual.label ?? (state?.state ?? 'Unknown'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: visual.color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      if (showAge)
        Text(
          haRelativeAgo(state!.lastChanged!),
          maxLines: 1,
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
    ];

    final chip = IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: lines,
        ),
      ),
    );

    // A fixed-width anchor box centered on the badge (clamped into the
    // pane); the chip centers itself inside and hugs its content.
    const anchorW = 180.0;
    final left = (x + w / 2 - anchorW / 2)
        .clamp(2.0, (paneW - anchorW - 2).clamp(2.0, double.infinity))
        .toDouble();
    final below = y + h + 4 + _captionEstHeight <= paneH;
    return [
      if (below)
        Positioned(
          left: left,
          top: y + h + 4,
          width: anchorW,
          child: Center(child: chip),
        )
      else
        Positioned(
          left: left,
          bottom: paneH - y + 4,
          width: anchorW,
          child: Center(child: chip),
        ),
    ];
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
    final top = y
        .clamp(4.0, (paneH - _cardEstHeight).clamp(4.0, double.infinity))
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
        onDismiss: () => setState(() => _openLinkId = null),
      ),
    );
  }
}
