// View-mode HA badge layer for a wall tile / maximized pane (issue #170 P0).
// A thin wrapper over `overlay_editor/overlay_editor_layer.dart` in VIEW
// mode: given a camera's placed HA links, a live-state lookup, a staleness
// flag, and the pane's decoded-video pixel size, it renders each placed link
// as a badge pinned to its normalized position on the DISPLAYED video frame
// (contain-fit, so it survives per-tile letterboxing differences —
// `overlay_geometry.dart`'s `fieldRect`), and shows a read-only
// `HaStateCard` on tap.
//
// Purely a display widget: everything comes via the constructor, no
// controller/global lookups (it builds its own private, ephemeral
// `OverlayEditorController` purely to satisfy `OverlayEditorLayer`'s
// generic plumbing — it never enters edit mode), so a tile/pane can drop it
// in without depending on any edit-session state. The actual placement
// EDITOR (drag-to-place, "Edit HA overlay…") is wired directly by the host
// using `overlay_editor/overlay_editor_layer.dart` +
// `overlay_editor/overlay_editor_bar.dart` + `HaOverlayController.editor` —
// this file's `haBadgeItemBuilder` is exported so the host's edit-mode UI
// renders the exact same badge visual language.
//
// Usage (wall tile / maximized pane, both already fetch+cache their camera's
// HA links once per mount — see the desktop P0 plan §4.4):
//
//   Positioned.fill(
//     child: HaOverlayLayer(
//       links: _haLinks,                        // List<HaLink>, tile-cached
//       stateFor: widget.liveStatus.haStateFor,  // add to LiveStatusController
//       stale: widget.liveStatus.haStale,        // add to LiveStatusController
//       videoW: _videoW, videoH: _videoH,        // null until first frame
//       hideBadges: _scale > 1.01,               // digital zoom, POC rule §4.2
//     ),
//   )

import 'package:flutter/material.dart';

import '../../api/ha_models.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import '../overlay_editor/overlay_editor_layer.dart';
import 'ha_icons.dart';
import 'ha_overlay_controller.dart' show HaOverlayBadgeItem;
import 'ha_state_card.dart';

/// Build an `OverlayItemBuilder` bound to a specific state lookup — used
/// identically by [HaOverlayLayer] (view mode, internally) and by the host's
/// maximized-pane "Edit HA overlay…" UI
/// (`OverlayEditorLayer(..., buildItem: haBadgeItemBuilder(stateFor: ...,
/// stale: ...))`), so both modes render the exact same badge visual
/// language.
OverlayItemBuilder haBadgeItemBuilder({
  required HaEntityState? Function(String entityId) stateFor,
  required bool stale,
}) {
  return (item, {required bool editing, required bool selected}) {
    final link = (item as HaOverlayBadgeItem).link;
    final state = stateFor(link.entityId);
    final visual = haVisualFor(
      domain: link.domain,
      deviceClass: link.deviceClass,
      state: state?.state,
      stale: stale,
    );
    return HaBadgeChip(visual: visual, selected: selected);
  };
}

/// The badge chip itself: a circular dark-scrim container with the resolved
/// icon, matching the tile-badge visual language (black-0.55 rounded scrim,
/// `live_status/live_status_badges.dart`). Sizes itself to fill whatever
/// rect the overlay layer gives it (see `overlay_editor_layer.dart`'s
/// `SizedBox` wrap) and scales the icon/border proportionally, mirroring
/// `PtzPanelOverlay`'s `_glyphOrLabel` clamp pattern.
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

  /// Live-state lookup, e.g. `LiveStatusController.haStateFor` (a method the
  /// wall_screen wiring adds to that controller — see the desktop P0 plan
  /// §4.4). Returns null when no state is known yet for that entity.
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
    final open = _findOpen(placed);

    return Stack(
      children: [
        // See overlay_editor_layer.dart's usage contract — it must be given
        // TIGHT constraints via Positioned.fill, or its inner Stack (which
        // clips) collapses to zero size under this Stack's default loose
        // constraints for non-positioned children.
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
          ),
        ),
        if (open != null) ...[
          // Tap-away scrim: any tap outside the card dismisses it. Sits
          // ABOVE the badge layer in paint/hit-test order (Stack hit-tests
          // the topmost child first and stops at the first opaque hit), so
          // while a card is open, a tap anywhere — including over a
          // DIFFERENT badge — is swallowed here and just dismisses the
          // card, rather than reaching the badge underneath (tap the badge
          // again to open its card). Sits BELOW the card itself, which
          // swallows its own taps (see `HaStateCard`). While no card is
          // open this scrim doesn't exist at all, so badge/tile gestures
          // are unaffected.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _openLinkId = null),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 12,
            top: 12,
            child: HaStateCard(
              entityId: open.entityId,
              friendlyName: open.displayLabel,
              domain: open.domain,
              deviceClass: open.deviceClass,
              state: widget.stateFor(open.entityId),
              stale: widget.stale,
              onDismiss: () => setState(() => _openLinkId = null),
            ),
          ),
        ],
      ],
    );
  }

  HaLink? _findOpen(List<HaLink> placed) {
    final id = _openLinkId;
    if (id == null) return null;
    for (final l in placed) {
      if (l.id == id) return l;
    }
    return null;
  }
}
