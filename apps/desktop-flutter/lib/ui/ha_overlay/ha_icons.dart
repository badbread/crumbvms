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
// `movie_filter`, `lightbulb`, `power`, `power_off` — plus the
// [kHaBadgeIconChoices] set below (`doorbell`, `notifications_active`,
// `water_drop`, `local_fire_department`, `thermostat`, `lock`, `videocam`,
// `pets`, `window`) — were written without a local Flutter SDK to verify
// against `Icons.<name>`, so please double check these compile on
// `flutter analyze`. `directions_run` and `sensors` ARE already used
// elsewhere (confirmed safe).

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

/// Curated per-badge icon OVERRIDES an operator can pick in the badge editor
/// (migration 0059 `overlay_icon`) — slug -> (glyph, picker label). Slugs are
/// what the server stores; unknown slugs (from a newer client, say) fall back
/// to the class-derived default rather than breaking rendering.
const Map<String, (IconData, String)> kHaBadgeIconChoices = {
  'door': (Icons.sensor_door, 'Door'),
  'window': (Icons.sensor_window, 'Window'),
  'garage': (Icons.garage, 'Garage'),
  'gate': (Icons.fence, 'Gate'),
  'motion': (Icons.directions_run, 'Motion'),
  'person': (Icons.person, 'Person'),
  'lightbulb': (Icons.lightbulb, 'Light'),
  'power': (Icons.power, 'Power'),
  'plug': (Icons.electrical_services, 'Plug'),
  'lock': (Icons.lock, 'Lock'),
  'doorbell': (Icons.doorbell, 'Doorbell'),
  'bell': (Icons.notifications_active, 'Bell'),
  'water': (Icons.water_drop, 'Water/leak'),
  'fire': (Icons.local_fire_department, 'Fire/smoke'),
  'thermostat': (Icons.thermostat, 'Temperature'),
  'fan': (Icons.air, 'Fan'),
  'camera': (Icons.videocam, 'Camera'),
  'pet': (Icons.pets, 'Pet'),
  'scene': (Icons.movie_filter, 'Scene'),
  'sensor': (Icons.sensors, 'Generic sensor'),
  // ── expanded set ──────────────────────────────────────────────────────────
  'floodlight': (Icons.highlight, 'Floodlight'),
  'outdoor_light': (Icons.wb_incandescent, 'Outdoor light'),
  'siren': (Icons.campaign, 'Siren'),
  'security': (Icons.shield, 'Security'),
  'armed': (Icons.gpp_good, 'Armed'),
  'blinds': (Icons.blinds, 'Blinds'),
  'curtains': (Icons.curtains, 'Curtains'),
  'shade': (Icons.roller_shades, 'Shade'),
  'ac': (Icons.ac_unit, 'A/C'),
  'heatpump': (Icons.heat_pump, 'Heat pump'),
  'hvac': (Icons.hvac, 'HVAC'),
  'humidity': (Icons.opacity, 'Humidity'),
  'smoke': (Icons.cloud, 'Smoke'),
  'co': (Icons.co2, 'CO / air'),
  'leak': (Icons.water_damage, 'Leak'),
  'valve': (Icons.plumbing, 'Valve'),
  'battery': (Icons.battery_full, 'Battery'),
  'energy': (Icons.bolt, 'Energy'),
  'meter': (Icons.electric_meter, 'Meter'),
  'switch': (Icons.toggle_on, 'Switch'),
  'vibration': (Icons.vibration, 'Vibration'),
  'occupancy': (Icons.sensor_occupied, 'Occupancy'),
  'sun': (Icons.wb_sunny, 'Sun / day'),
  'vehicle': (Icons.directions_car, 'Vehicle'),
  'package': (Icons.inventory_2, 'Package'),
  'mail': (Icons.mail, 'Mail'),
  'speaker': (Icons.speaker, 'Speaker'),
  'tv': (Icons.tv, 'TV / media'),
  'vacuum': (Icons.cleaning_services, 'Vacuum'),
  'lawn': (Icons.grass, 'Lawn / sprinkler'),
  'solar': (Icons.solar_power, 'Solar'),
  'ev': (Icons.ev_station, 'EV charger'),
  'fridge': (Icons.kitchen, 'Fridge'),
  'laundry': (Icons.local_laundry_service, 'Laundry'),
  'wifi': (Icons.wifi, 'Wi-Fi'),
  'router': (Icons.router, 'Router'),
  'clock': (Icons.schedule, 'Clock / timer'),
  'key': (Icons.key, 'Key'),
  'warning': (Icons.warning, 'Warning'),
  'pool': (Icons.pool, 'Pool'),
  'hottub': (Icons.hot_tub, 'Hot tub'),
};

/// Parse a stored '#RRGGBB' badge color override into a [Color] (full
/// opacity), or null for absent/malformed values.
Color? parseOverlayColorHex(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final v = int.tryParse(hex.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Relative "N ago" for a badge caption / state card, from HA `last_changed`.
String haRelativeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 5) return 'just now';
  if (d.inMinutes < 1) return '${d.inSeconds} s ago';
  if (d.inHours < 1) return '${d.inMinutes} m ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
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
/// - `iconOverride`/`colorOverride` are the operator's per-badge picks
///   (migration 0059). The icon override always applies (icon identity is
///   static). The color override applies ONLY to a KNOWN reading — active
///   at full strength, inactive dimmed — and NEVER to unknown/unavailable/
///   stale, where the grey honesty treatment always wins (a recolored badge
///   must not read "alive" on a dead HA connection).
HaVisual haVisualFor({
  required String domain,
  String? deviceClass,
  required String? state,
  required bool stale,
  String? iconOverride,
  Color? colorOverride,
}) {
  final v = _haVisualDefault(
    domain: domain,
    deviceClass: deviceClass,
    state: state,
    stale: stale,
  );
  final overrideIcon = iconOverride == null
      ? null
      : kHaBadgeIconChoices[iconOverride]?.$1;
  final on = (state == null || stale || domain == 'scene')
      ? null
      : edgeOn(state);
  final Color color;
  if (colorOverride != null && on != null) {
    color = on ? colorOverride : colorOverride.withValues(alpha: 0.45);
  } else {
    color = v.color;
  }
  if (overrideIcon == null && identical(color, v.color)) return v;
  return HaVisual(
    overrideIcon ?? v.icon,
    color,
    label: v.label,
    pulsing: v.pulsing,
  );
}

HaVisual _haVisualDefault({
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
