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

/// light / switch / fan / siren. Two explicit intents rather than a single
/// `toggle`: on a security console "make it on" beats "flip whatever it is",
/// and the card already shows the live state right above these buttons.
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
    default:
      return const [];
  }
}

/// The confirm-step prompt for a physical-security action, e.g.
/// "Unlock Front Door?" / "Close Garage Door?".
String haConfirmPrompt(HaControlAction action, String friendlyName) =>
    '${action.label} $friendlyName?';
