// Icon + state->visual mapping for HA on-video badges (issue #170 §4.6). A
// Dart mirror of the backend's `edge_on` / `label_for_device_class`
// (services/common/src/ha.rs) extended for the light/switch/scene DOMAINS
// (the backend slug only covers binary_sensor device classes — domain-based
// mapping for controls is new here, client-side only). Curated Material
// Icons mapping, dependency-free — same ethos as
// `live_status/detection_icons.dart`.
//
// State->visual NEVER treats an indeterminate reading as "off"/"closed": an
// unknown/unavailable/stale entity renders grey + reduced opacity. This
// mirrors the backend's `edge_on` invariant (services/common/src/ha.rs) —
// `unavailable`/`unknown` map to `None`, never `false` — carried into the UI
// because a badge that looks "closed" on a dead HA connection is the overlay
// equivalent of the footage-loss bug class (AGENTS.md golden rule 2's
// spirit, applied to state honesty rather than footage).
//
// NOTE for the reviewing human: `sensor_door`, `sensor_window`, `garage`,
// `sensors_occupied`, `movie_filter`, `lightbulb`, `power`, `power_off` are
// NOT used anywhere else in this codebase yet (grepped at write time) — this
// file was written without a local Flutter SDK to verify against
// `Icons.<name>`, so please double check these compile on `flutter analyze`.
// `directions_run` and `sensors` ARE already used elsewhere (confirmed safe).

import 'package:flutter/material.dart';

/// A resolved icon + color + optional short label for one badge/card render.
class HaVisual {
  const HaVisual(this.icon, this.color, {this.label, this.pulsing = false});

  final IconData icon;
  final Color color;

  /// Short state label for hosts that want to show text alongside the icon
  /// (e.g. `ha_state_card.dart`'s state line: "Open"/"Closed"/"On"/"Off").
  final String? label;

  /// Advisory hint for hosts that want an "active" attention treatment
  /// (motion/occupancy while active). Not consumed by the POC badge chip;
  /// kept so a later polish pass has the signal without a model change.
  final bool pulsing;
}

const Color _kGrey = Color(0xFF8E8E93);
const Color _kAmber = Color(0xFFFFB143); // matches the license_plate/detection amber family
const Color _kNeutral = Color(0xFFB9C2CC); // closed/off but KNOWN — not grey
const Color _kBlue = Color(0xFF33C3FF); // matches the person-detection blue family
const Color _kGreen = Color(0xFF2BA84A);
const Color _kWarmYellow = Color(0xFFFFCC33);

/// HA `state` string -> on/off/indeterminate, mirroring
/// `services/common/src/ha.rs::edge_on` EXACTLY (including which strings map
/// to which side) so the client's "is this open/on" reading never disagrees
/// with what the recorder's motion source already treats as ground truth.
/// `null` = indeterminate (unavailable/unknown/anything else) — NEVER
/// treated as off.
bool? edgeOn(String state) {
  switch (state.trim().toLowerCase()) {
    case 'on':
    case 'open':
    case 'detected':
    case 'true':
    case 'home':
    case 'motion':
    case 'occupied':
      return true;
    case 'off':
    case 'closed':
    case 'clear':
    case 'false':
    case 'not_home':
    case 'no_motion':
      return false;
    default:
      return null;
  }
}

/// Device-class -> Crumb label slug, mirroring
/// `services/common/src/ha.rs::label_for_device_class` exactly.
String labelForDeviceClass(String? deviceClass) {
  switch (deviceClass?.trim().toLowerCase()) {
    case 'motion':
    case 'moving':
    case 'vibration':
      return 'motion';
    case 'occupancy':
    case 'presence':
      return 'occupancy';
    case 'door':
    case 'opening':
      return 'door';
    case 'window':
      return 'window';
    case 'garage_door':
      return 'garage';
    default:
      return 'sensor';
  }
}

/// Resolve the icon + color (+ optional label) to render for a linked
/// entity's current reading.
///
/// - `domain` is the entity_id's domain prefix (`light`, `switch`, `scene`,
///   `binary_sensor`, ...).
/// - `deviceClass` is the link's HA device_class (binary_sensor links only).
/// - `state` is the raw HA state string, or `null` when no state is known
///   yet.
/// - `stale` forces the indeterminate/grey treatment regardless of `state`
///   (the HA states feed has gone stale — never trust a possibly-stale
///   reading as authoritative).
HaVisual haVisualFor({
  required String domain,
  String? deviceClass,
  required String? state,
  required bool stale,
}) {
  if (domain == 'scene') {
    // Stateless — a neutral chip regardless of state/staleness.
    return const HaVisual(Icons.movie_filter, _kNeutral, label: 'Scene');
  }

  final on = (state == null || stale) ? null : edgeOn(state);
  if (on == null) {
    return HaVisual(
      _iconFor(domain: domain, deviceClass: deviceClass),
      _kGrey.withValues(alpha: 0.6),
      label: state ?? 'Unknown',
    );
  }

  if (domain == 'light') {
    return HaVisual(
      Icons.lightbulb,
      on ? _kWarmYellow : _kGrey,
      label: on ? 'On' : 'Off',
    );
  }
  if (domain == 'switch') {
    return HaVisual(
      on ? Icons.power : Icons.power_off,
      on ? _kGreen : _kGrey,
      label: on ? 'On' : 'Off',
    );
  }

  // binary_sensor (or any other domain) — device_class driven.
  switch (labelForDeviceClass(deviceClass)) {
    case 'door':
      return HaVisual(
        Icons.sensor_door,
        on ? _kAmber : _kNeutral,
        label: on ? 'Open' : 'Closed',
      );
    case 'window':
      return HaVisual(
        Icons.sensor_window,
        on ? _kAmber : _kNeutral,
        label: on ? 'Open' : 'Closed',
      );
    case 'garage':
      return HaVisual(
        Icons.garage,
        on ? _kAmber : _kNeutral,
        label: on ? 'Open' : 'Closed',
      );
    case 'motion':
      return HaVisual(
        Icons.directions_run,
        on ? _kBlue : _kGrey,
        label: on ? 'Motion' : 'Clear',
        pulsing: on,
      );
    case 'occupancy':
      return HaVisual(
        Icons.person,
        on ? _kBlue : _kGrey,
        label: on ? 'Occupied' : 'Clear',
        pulsing: on,
      );
    default:
      return HaVisual(
        Icons.sensors,
        on ? _kBlue : _kGrey,
        label: on ? 'Active' : 'Clear',
      );
  }
}

IconData _iconFor({required String domain, String? deviceClass}) {
  if (domain == 'light') return Icons.lightbulb;
  if (domain == 'switch') return Icons.power;
  if (domain == 'scene') return Icons.movie_filter;
  switch (labelForDeviceClass(deviceClass)) {
    case 'door':
      return Icons.sensor_door;
    case 'window':
      return Icons.sensor_window;
    case 'garage':
      return Icons.garage;
    case 'motion':
      return Icons.directions_run;
    case 'occupancy':
      return Icons.person;
    default:
      return Icons.sensors;
  }
}
