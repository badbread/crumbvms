// Detail ("more info") card shown when an operator taps a placed HA badge
// (issue #170 POC). Friendly name, current state, a relative "N ago" from
// `last_changed`, the raw entity_id in mono-dim, and a stale note when
// applicable.
//
// Issue #187 (HA control Phase 2) adds an optional CONTROL row at the bottom:
// the buttons for the entity's domain (`ha_actions.dart`, which mirrors the
// server's allow-list). The host decides whether to pass any — it renders
// controls only when the account holds the `actuators` capability AND the link
// is an `actuator` role, so an unprivileged operator sees the card exactly as
// it looked before, with no hint that controls exist.
//
// Control semantics:
// * lock/cover actions ask for an explicit confirm first (a stray click on a
//   wall tile must not unlock a door);
// * a fired action shows an in-flight spinner, then a short "sent" settle
//   during which the buttons stay disabled — the card NEVER flips the state
//   locally, the host's 3s `/ha/states` poll is what converges the badge;
// * failures are surfaced by the HOST (a toast), not inline: `onAction` is
//   contracted never to throw, and resolves false on failure so the buttons
//   come straight back.
//
// This widget is just the card's CONTENT (plus swallowing taps on itself so
// a host's tap-away scrim underneath doesn't dismiss when the card itself is
// tapped) — the caller (`ha_overlay_layer.dart`) owns showing/hiding it and
// wiring tap-away/Esc dismissal, matching `PtzPanelEditorBar`'s
// plain-content-widget pattern (no Dialog/route machinery).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/ha_models.dart';
import 'ha_actions.dart';
import 'ha_icons.dart';

/// How long the buttons stay disabled after a successful action, so the
/// operator sees the request landed while the next `/ha/states` poll (3s)
/// brings the real state back.
const Duration _kSettleWindow = Duration(milliseconds: 3200);

class HaStateCard extends StatefulWidget {
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
    this.actions = const [],
    this.onAction,
    this.requireConfirm = false,
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

  /// Control buttons to offer (issue #187). Empty (the default) keeps the
  /// card exactly read-only. The host is responsible for the capability +
  /// role gate; this widget renders whatever it is handed.
  final List<HaControlAction> actions;

  /// Fires one action, by its wire string, and resolves to whether the server
  /// accepted it. Contracted NOT to throw: the host performs the POST and
  /// surfaces any failure itself (toast), resolving `false` so this card can
  /// drop its pending state immediately instead of sitting through the
  /// convergence window. Null (or an empty [actions]) means no controls.
  final Future<bool> Function(String action)? onAction;

  /// Per-link control config (migration 0075, issue #440). When true, EVERY
  /// action confirms first, not just the hardcoded cover/lock cases — so an
  /// operator can require a deliberate tap on any device. Default false keeps
  /// the pre-0075 behavior (only [HaControlAction.confirm] actions prompt).
  final bool requireConfirm;

  @override
  State<HaStateCard> createState() => _HaStateCardState();
}

class _HaStateCardState extends State<HaStateCard> {
  /// The action currently in flight or settling, or null when idle.
  String? _pending;

  /// True once the POST returned and we are just waiting for the state poll
  /// to catch up (spinner becomes a check).
  bool _sent = false;

  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  Future<void> _fire(HaControlAction action) async {
    final run = widget.onAction;
    if (run == null || _pending != null) return;
    if (action.confirm || widget.requireConfirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(haConfirmPrompt(action, widget.friendlyName)),
          content: Text(
            'This controls a real device through Home Assistant.',
            style: TextStyle(color: Theme.of(ctx).hintColor, fontSize: 12.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(action.label),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      _pending = action.action;
      _sent = false;
    });
    final ok = await run(action.action);
    if (!mounted) return;
    if (!ok) {
      // The host already surfaced the failure; hand the buttons straight back
      // so the operator can retry.
      setState(() {
        _pending = null;
        _sent = false;
      });
      return;
    }
    // Accepted: hold the "sent" state for the convergence window, then let the
    // polled state speak for itself.
    setState(() => _sent = true);
    _settle?.cancel();
    _settle = Timer(_kSettleWindow, () {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _sent = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final visual = haVisualFor(
      domain: widget.domain,
      deviceClass: widget.deviceClass,
      state: widget.state?.state,
      stale: widget.stale,
      iconOverride: widget.iconOverride,
      colorOverride: widget.colorOverride,
    );
    final onDismiss = widget.onDismiss;
    final state = widget.state;
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
                      widget.friendlyName,
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
                haStateDisplay(
                  visual: visual,
                  state: state?.state,
                  unit: state?.unit,
                ),
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
                widget.entityId,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                ),
              ),
              if (widget.stale) ...[
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
              if (widget.actions.isNotEmpty && widget.onAction != null) ...[
                const SizedBox(height: 8),
                const Divider(height: 1, color: Colors.white12),
                const SizedBox(height: 8),
                _controlRow(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The control buttons (issue #187). Wrapped so a three-button cover row
  /// still fits the card's 260px cap on a narrow layout.
  Widget _controlRow() {
    final busy = _pending != null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final a in widget.actions)
          _ControlButton(
            action: a,
            // Pending on THIS button shows the progress/sent glyph; every
            // other button just goes disabled until the settle window ends.
            pending: _pending == a.action,
            sent: _pending == a.action && _sent,
            onPressed: busy ? null : () => unawaited(_fire(a)),
          ),
      ],
    );
  }
}

/// One control button: icon + caption, swapping the icon for a spinner while
/// the request is in flight and a check for the settle window after it lands.
class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.action,
    required this.pending,
    required this.sent,
    required this.onPressed,
  });

  final HaControlAction action;
  final bool pending;
  final bool sent;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final Widget leading;
    if (pending && !sent) {
      leading = const SizedBox(
        width: 13,
        height: 13,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (pending) {
      leading = const Icon(Icons.check, size: 15);
    } else {
      leading = Icon(action.icon, size: 15);
    }
    return TextButton.icon(
      onPressed: onPressed,
      icon: leading,
      label: Text(action.label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.white10,
        disabledForegroundColor: Colors.white38,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}
