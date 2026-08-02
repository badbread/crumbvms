// Detail ("more info") card shown when an operator taps a placed HA badge
// (issue #170 POC). Friendly name (title), current state, a relative "N ago"
// from `last_changed`, labeled Entity / Type rows (entity_id + device-type),
// and a stale note when applicable. The header icon reuses the badge's own
// `haVisualFor` color — never a muted/greyscale variant — so a lit light reads
// warm-yellow here exactly as it does on the video badge (kept in step with the
// Android/iOS detail cards: same coloring + entity/device-type presentation).
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
// #442 Slice 1 adds an optional VALUE row below the button row: a `Slider`
// driven entirely by the state feed's `HaControlDescriptor` (min/max/step/
// unit — never hardcoded), for value-setting entities (a dimmable light, a
// positionable cover, a speed-controllable fan). It commits on release with
// exactly one `onValueAction` call per drag gesture, never while dragging;
// the same never-flip-locally / settle-window contract as the buttons above
// applies, and `cover.set_position` (like the discrete cover actions) or a
// `require_confirm` link confirms with the target value in the prompt before
// sending.
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
    this.control,
    this.onValueAction,
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

  /// The value-slider's capability descriptor (#442 Slice 1) — null (the
  /// default) draws no slider at all. The host decides whether to pass one
  /// (capability + role gate, same as [actions]/[onAction]) and drives its
  /// bounds/step/unit from the descriptor, never hardcoded.
  final HaControlDescriptor? control;

  /// Fires the slider's committed value, by [control]'s wire action string,
  /// and resolves to whether the server accepted it — same contract as
  /// [onAction] (never throws, resolves false on failure). Called exactly
  /// once per drag gesture, on release, never while dragging. Null (or a null
  /// [control]) means no slider.
  final Future<bool> Function(String action, double value)? onValueAction;

  /// Per-link control config (migration 0075, issue #440). When true, EVERY
  /// action confirms first, not just the hardcoded cover/lock cases — so an
  /// operator can require a deliberate tap on any device. Default false keeps
  /// the pre-0075 behavior (only [HaControlAction.confirm] actions prompt).
  final bool requireConfirm;

  @override
  State<HaStateCard> createState() => _HaStateCardState();
}

class _HaStateCardState extends State<HaStateCard> {
  /// The action currently in flight or settling, or null when idle. Shared
  /// between the button row and the value slider — only one of either kind
  /// can be in flight at a time (both gate on this being null).
  String? _pending;

  /// True once the POST returned and we are just waiting for the state poll
  /// to catch up (spinner becomes a check).
  bool _sent = false;

  /// The slider's live drag position, or the value it was released/sent at
  /// while `_pending` holds it through the settle window. Null means "follow
  /// the polled `control.value`" — the normal idle state. Never used to
  /// optimistically report a NEW value as accepted; it only reflects what the
  /// operator is doing with the thumb right now (or just released).
  double? _dragValue;

  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  /// Human-readable device-type for the "Type" row: the HA `device_class`
  /// when the link has one (`door` -> "Door"), else the entity_id's domain
  /// (`light` -> "Light"). Null when neither is known, so the row is omitted
  /// rather than showing an empty value.
  String? _deviceTypeLabel() {
    final dc = widget.deviceClass?.trim();
    if (dc != null && dc.isNotEmpty) return _humanize(dc);
    final dom = widget.domain.trim();
    if (dom.isNotEmpty) return _humanize(dom);
    return null;
  }

  static String _humanize(String s) => s
      .split(RegExp(r'[._]'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');

  /// A labeled key/value row (fixed-width label + value), matching the card's
  /// compact type scale. `mono` renders the value in the monospace face used
  /// for raw ids like the entity_id.
  Widget _infoRow(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 10.5),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10.5,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
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

  /// Commit the value slider's released position (#442 Slice 1). One POST per
  /// drag gesture, called only from `onChangeEnd` — never while dragging.
  /// Mirrors [_fire]'s confirm / pending / settle / never-flip-locally
  /// contract exactly, just with a numeric payload instead of a bare action.
  Future<void> _fireValue(HaControlDescriptor control, double value) async {
    final run = widget.onValueAction;
    if (run == null || _pending != null) return;
    if (widget.requireConfirm || haValueActionNeedsConfirm(widget.domain)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            'Set ${widget.friendlyName} to ${haFormatControlValue(control, value)}?',
          ),
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
              child: const Text('Set'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) {
        // Snap the thumb back to the last polled value — the operator backed
        // out of the confirm, nothing was sent.
        setState(() => _dragValue = null);
        return;
      }
    }
    setState(() {
      _dragValue = value;
      _pending = control.action;
      _sent = false;
    });
    final ok = await run(control.action, value);
    if (!mounted) return;
    if (!ok) {
      // The host already surfaced the failure; hand the slider straight back
      // so the operator can retry.
      setState(() {
        _pending = null;
        _sent = false;
        _dragValue = null;
      });
      return;
    }
    // Accepted: hold the released position for the convergence window, then
    // let the polled `control.value` speak for itself.
    setState(() => _sent = true);
    _settle?.cancel();
    _settle = Timer(_kSettleWindow, () {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _sent = false;
        _dragValue = null;
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
    final deviceType = _deviceTypeLabel();
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
              _infoRow('Entity', widget.entityId, mono: true),
              if (deviceType != null) _infoRow('Type', deviceType),
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
              if (_hasActions || _hasControl) ...[
                const SizedBox(height: 8),
                const Divider(height: 1, color: Colors.white12),
                const SizedBox(height: 8),
                if (_hasActions) _controlRow(),
                if (_hasActions && _hasControl) const SizedBox(height: 10),
                if (_hasControl) _valueRow(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool get _hasActions =>
      widget.actions.isNotEmpty && widget.onAction != null;

  bool get _hasControl =>
      widget.control != null && widget.onValueAction != null;

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

  /// The value slider row (#442 Slice 1): a caption ("Brightness"), the
  /// live/dragged value, and a `Slider` driven entirely by [control]'s
  /// min/max/step — never hardcoded — so a future non-percent kind (Slice
  /// 2's temperature) drops in unchanged. Disabled (greyed, non-interactive)
  /// while ANY action (button or slider) is pending, same busy gate as
  /// [_controlRow].
  Widget _valueRow() {
    final control = widget.control!;
    final busy = _pending != null;
    final display = (_dragValue ?? control.value)
        .clamp(control.min, control.max)
        .toDouble();
    final divisions = control.max > control.min && control.step > 0
        ? ((control.max - control.min) / control.step)
            .round()
            .clamp(1, 1000)
            .toInt()
        : null;
    final pendingThis = _pending == control.action;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                haValueActionLabel(control.action),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (pendingThis && !_sent)
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (pendingThis)
              const Icon(Icons.check, size: 13, color: Colors.white70)
            else
              Text(
                haFormatControlValue(control, display),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: display,
            min: control.min,
            max: control.max,
            divisions: divisions,
            onChanged: busy
                ? null
                : (v) => setState(() => _dragValue = v),
            // Commit exactly once, on release — never a POST per drag tick.
            onChangeEnd: busy
                ? null
                : (v) => unawaited(_fireValue(control, v)),
          ),
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
