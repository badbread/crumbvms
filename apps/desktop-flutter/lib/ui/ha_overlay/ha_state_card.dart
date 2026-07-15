// Read-only detail card shown when an operator taps a placed HA badge (issue
// #170 POC — no controls, see the desktop P0 plan §4.6/§1 locked decision
// #3). Friendly name, current state, a relative "N ago" from `last_changed`,
// the raw entity_id in mono-dim, and a stale note when applicable.
//
// This widget is just the card's CONTENT (plus swallowing taps on itself so
// a host's tap-away scrim underneath doesn't dismiss when the card itself is
// tapped) — the caller (`ha_overlay_layer.dart`) owns showing/hiding it and
// wiring tap-away/Esc dismissal, matching `PtzPanelEditorBar`'s
// plain-content-widget pattern (no Dialog/route machinery).

import 'package:flutter/material.dart';

import '../../api/ha_models.dart';
import 'ha_icons.dart';

class HaStateCard extends StatelessWidget {
  const HaStateCard({
    super.key,
    required this.entityId,
    required this.friendlyName,
    required this.domain,
    this.deviceClass,
    this.state,
    this.stale = false,
    this.iconOverride,
    this.colorOverride,
    this.onDismiss,
  });

  final String entityId;
  final String friendlyName;
  final String domain;
  final String? deviceClass;
  final HaEntityState? state;
  final bool stale;

  /// Per-badge display overrides (migration 0059) so the card's header icon/
  /// color match the badge it opened from — see `haVisualFor`'s doc.
  final String? iconOverride;
  final Color? colorOverride;

  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final visual = haVisualFor(
      domain: domain,
      deviceClass: deviceClass,
      state: state?.state,
      stale: stale,
      iconOverride: iconOverride,
      colorOverride: colorOverride,
    );
    return GestureDetector(
      // Swallow taps on the card so a tap-away scrim behind it (drawn by the
      // host) doesn't treat "tapping the card" as "tapping away".
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF15181D).withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(visual.icon, color: visual.color, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      friendlyName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (onDismiss != null)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onDismiss,
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, color: Colors.white54, size: 16),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                visual.label ?? (state?.state ?? 'Unknown'),
                style: TextStyle(
                  color: visual.color,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (state?.lastChanged != null) ...[
                const SizedBox(height: 2),
                Text(
                  haRelativeAgo(state!.lastChanged!),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                entityId,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                ),
              ),
              if (stale) ...[
                const SizedBox(height: 6),
                const Text(
                  '⚠ Stale — Home Assistant connection may be down',
                  style: TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 10.5,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

}
