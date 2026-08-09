// The HA control-action table for the on-video badge detail card (issue #187,
// HA control Phase 2 — the epic's P3 "actuators endpoint + RBAC + buttons").
//
// This mirrors the server's allow-list for `POST /cameras/{id}/ha/action`
// EXACTLY: the set of actions a client may ask for is derived from the linked
// entity's DOMAIN (the entity_id prefix before the first dot), and the server
// rejects anything outside its own copy of this table with a 400. Keeping the
// client's button set derived from the same table means an operator never sees
// a button that the server would refuse.
//
//   light, switch, fan, siren  -> turn_on / turn_off / toggle
//   cover                      -> open_cover / close_cover / stop_cover
//   lock                       -> lock / unlock
//   button, input_button       -> press
//   scene, script              -> turn_on
//   automation                 -> trigger
//
// Anything else (binary_sensor, sensor, an unknown domain from a newer HA)
// yields NO actions, so the card stays read-only exactly as it is today.
//
// [HaControlAction.confirm] marks the physical-security domains (locks and
// covers): those fire only after an explicit confirm step, because a stray
// click on a wall tile must not unlock a door or open a garage. Lights,
// switches, buttons and scenes fire immediately.

import 'package:flutter/material.dart';

/// One button on the badge detail card's control row.
class HaControlAction {
  const HaControlAction({
    required this.action,
    required this.label,
    required this.icon,
    this.confirm = false,
  });

  /// The wire value sent as the request's `action` field. Must be one of the
  /// server's allowed strings for the entity's domain.
  final String action;

  /// Button caption, also used to build the confirm prompt
  /// ("Unlock Front Door?") — see [haConfirmPrompt].
  final String label;

  final IconData icon;

  /// Require an explicit confirm before firing (locks + covers).
  final bool confirm;
}

/// light / switch / fan / siren, single-click (issue #428). A plain click on a
/// controllable badge for these domains flips it in one gesture — the badge's
/// live state tells the operator which way it went, so a lone `toggle` is the
/// natural desktop action and skips the card entirely. `toggle` is in the
/// server's allow-list for all four domains (see this file's header table).
const HaControlAction _kToggleAction = HaControlAction(
  action: 'toggle',
  label: 'Toggle',
  icon: Icons.power_settings_new,
);

/// light / switch / fan / siren. Two explicit intents rather than a single
/// `toggle`: on a security console "make it on" beats "flip whatever it is",
/// and the card already shows the live state right above these buttons. Still
/// used for the (unreachable-for-simple-domains but generic) card path.
const List<HaControlAction> _kOnOffActions = [
  HaControlAction(
    action: 'turn_on',
    label: 'On',
    icon: Icons.power_settings_new,
  ),
  HaControlAction(action: 'turn_off', label: 'Off', icon: Icons.power_off),
];

/// cover — Open / Stop / Close, in the order HA itself renders them.
const List<HaControlAction> _kCoverActions = [
  HaControlAction(
    action: 'open_cover',
    label: 'Open',
    icon: Icons.keyboard_arrow_up,
    confirm: true,
  ),
  HaControlAction(
    action: 'stop_cover',
    label: 'Stop',
    icon: Icons.stop,
    confirm: true,
  ),
  HaControlAction(
    action: 'close_cover',
    label: 'Close',
    icon: Icons.keyboard_arrow_down,
    confirm: true,
  ),
];

const List<HaControlAction> _kLockActions = [
  HaControlAction(
    action: 'lock',
    label: 'Lock',
    icon: Icons.lock_outline,
    confirm: true,
  ),
  HaControlAction(
    action: 'unlock',
    label: 'Unlock',
    icon: Icons.lock_open,
    confirm: true,
  ),
];

const List<HaControlAction> _kPressActions = [
  HaControlAction(action: 'press', label: 'Press', icon: Icons.touch_app),
];

/// scene — HA's service is `turn_on`; "Activate" is what it reads as.
const List<HaControlAction> _kSceneActions = [
  HaControlAction(
    action: 'turn_on',
    label: 'Activate',
    icon: Icons.auto_awesome,
  ),
];

/// script — also `turn_on` on the wire.
const List<HaControlAction> _kScriptActions = [
  HaControlAction(action: 'turn_on', label: 'Run', icon: Icons.play_arrow),
];

/// automation — HA's service is `automation.trigger`, which fires the
/// automation's actions immediately (skipping its trigger conditions). "Trigger"
/// is what it reads as on the badge.
const List<HaControlAction> _kAutomationActions = [
  HaControlAction(action: 'trigger', label: 'Trigger', icon: Icons.bolt),
];

/// The actions the server will accept for an entity in [domain]; empty for
/// every domain that has no control path (the card then renders read-only).
List<HaControlAction> haActionsForDomain(String domain) {
  switch (domain) {
    case 'light':
    case 'switch':
    case 'fan':
    case 'siren':
      return _kOnOffActions;
    case 'cover':
      return _kCoverActions;
    case 'lock':
      return _kLockActions;
    case 'button':
    case 'input_button':
      return _kPressActions;
    case 'scene':
      return _kSceneActions;
    case 'script':
      return _kScriptActions;
    case 'automation':
      return _kAutomationActions;
    default:
      return const [];
  }
}

/// The FULL action set for a [domain] — a superset of [haActionsForDomain] used
/// ONLY when a link restricts its actions (`allowed_actions` non-null, migration
/// 0075). The simple on/off domains gain the `toggle` button their default card
/// omits, so an operator can restrict a light to exactly `toggle` and still have
/// it render. Every other domain equals its default set. The caller intersects
/// this with the link's `allowedActions`.
List<HaControlAction> haAllActionsForDomain(String domain) {
  switch (domain) {
    case 'light':
    case 'switch':
    case 'fan':
    case 'siren':
      return [..._kOnOffActions, _kToggleAction];
    default:
      return haActionsForDomain(domain);
  }
}

/// The client interaction split for issue #428 — kept HERE (next to the
/// server-mirroring action table) so every client and the state model agree on
/// which domains a single click actuates directly vs which open the detail card.
///
/// The single action a plain click fires for a "simple", one-tap domain, or
/// null when the domain either needs the multi-action card ([haNeedsCard]) or
/// has no control path at all. Direct-click desktop actuation routes on this:
/// a non-null result POSTs immediately (no card); null falls through to the
/// card (or, for a read-only badge, the read-only card).
///
///   light / switch / fan / siren -> toggle
///   button / input_button        -> press
///   scene / script               -> turn_on (activate / run)
///   automation                   -> trigger
///
/// Unknown/read-only domains (binary_sensor, sensor, a newer HA domain) return
/// null: no guessed actuation, the badge stays read-only.
HaControlAction? haPrimaryAction(String domain) {
  switch (domain) {
    case 'light':
    case 'switch':
    case 'fan':
    case 'siren':
      return _kToggleAction;
    case 'button':
    case 'input_button':
      return _kPressActions.first;
    case 'scene':
      return _kSceneActions.first;
    case 'script':
      return _kScriptActions.first;
    case 'automation':
      return _kAutomationActions.first;
    default:
      return null;
  }
}

/// Domains whose control needs the detail CARD rather than a single click:
/// `cover` (open / stop / close — three distinct actions) and `lock` (which
/// also keeps its confirm dialog). A future value-setting control (a dimmer /
/// position slider) would join this bucket once the backend action allow-list
/// grows past on/off/toggle; today those two are the only card domains.
bool haNeedsCard(String domain) => domain == 'cover' || domain == 'lock';

/// The confirm-step prompt for a physical-security action, e.g.
/// "Unlock Front Door?" / "Close Garage Door?".
String haConfirmPrompt(HaControlAction action, String friendlyName) =>
    '${action.label} $friendlyName?';
