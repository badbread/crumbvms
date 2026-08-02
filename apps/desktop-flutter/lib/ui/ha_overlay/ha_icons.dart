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
// This map covers the ENTIRE canonical closed icon vocabulary defined once
// server-side in `services/api/src/ha.rs` (`CANONICAL_ICON_SLUGS`, issue #438):
// every slug there has a real glyph here, so an operator's pick renders the same
// on desktop, iOS, and Android instead of degrading to a generic dot. The server
// rejects any `overlay_icon` outside that set, so the `?? Icons.sensors` fallback
// in [haVisualFor] is defense-in-depth (e.g. a newer server slug) rather than an
// expected path.
//
// NOTE for the reviewing human: the following `Icons.<name>` glyphs were written
// without a local Flutter SDK to verify, so please confirm they compile on
// `flutter analyze`: `sensor_door`, `sensor_window`, `garage`, `movie_filter`,
// `lightbulb`, `power`, `power_off`, `doorbell`, `notifications_active`,
// `water_drop`, `local_fire_department`, `thermostat`, `lock`, `lock_open`,
// `videocam`, `pets`, `window`, `co2`, `water_damage`, and the #438 additions
// `blinds_closed`, `outlet`, `device_thermostat`, `gas_meter`, `terminal`,
// `smart_button`. `directions_run` and `sensors` ARE already used elsewhere
// (confirmed safe).

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
const Color _kDanger = Color(0xFFE5484D); // smoke/gas alarm active — attention red

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

/// Device-class -> Crumb badge-class slug. A SUPERSET of the backend's
/// `services/common/src/ha.rs::label_for_device_class` (which the recorder uses
/// for timeline/notification labels and only needs motion/occupancy/door/window/
/// garage): the display badge additionally distinguishes lock, smoke, gas/CO,
/// and leak/moisture problem sensors so those read as their own glyph + alert
/// color everywhere instead of a generic sensor dot (issue #438, restoring the
/// richness #437 flattened). The FIRST five cases stay byte-for-byte aligned
/// with the backend so the shared classes never disagree. This ONE function
/// backs both the on-video badge and the entity sheet; the iOS
/// `classForDeviceClass` and Android `labelForDeviceClass` mirror it exactly.
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
    // ── display-only extensions (badge/sheet richness, issue #438) ──
    case 'lock':
      return 'lock';
    case 'smoke':
      return 'smoke';
    case 'gas':
    case 'carbon_monoxide':
      return 'gas';
    case 'moisture':
      return 'leak';
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
  // ── completes the canonical closed vocabulary (issue #438) ──────────────────
  'cover': (Icons.blinds_closed, 'Cover'),
  'outlet': (Icons.outlet, 'Outlet'),
  'temperature': (Icons.device_thermostat, 'Temperature'),
  'gas': (Icons.gas_meter, 'Gas / CO'),
  'script': (Icons.terminal, 'Script'),
  'button': (Icons.smart_button, 'Button'),
};

/// Parse a stored '#RRGGBB' badge color override into a [Color] (full
/// opacity), or null for absent/malformed values.
Color? parseOverlayColorHex(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final v = int.tryParse(hex.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// The text to show for an entity's current reading on a badge caption / state
/// card (issue #449). The visual's semantic label ("Open"/"On"/"Closed") when
/// there is one, else the raw state, with the entity's
/// `unit_of_measurement` appended when the reading is a real value — i.e. a
/// numeric/plain state (`edgeOn == null`) that is not an indeterminate
/// placeholder — and a unit is known: "72" + "°F" -> "72 °F", "48" + "%" ->
/// "48 %". An on/off/open/closed label never gets a unit appended. Falls back
/// to exactly today's text ("Open", "Unknown", the bare value) when `unit` is
/// null.
String haStateDisplay({
  required HaVisual visual,
  required String? state,
  String? unit,
}) {
  final base = visual.label ?? (state ?? 'Unknown');
  final u = unit?.trim();
  if (u == null || u.isEmpty || state == null) return base;
  final s = state.trim();
  if (s.isEmpty) return base;
  // Only a real value takes a unit: skip on/off style states (edgeOn known)
  // and the indeterminate placeholders, which are not measurements.
  if (edgeOn(s) != null) return base;
  switch (s.toLowerCase()) {
    case 'unavailable':
    case 'unknown':
    case 'none':
      return base;
  }
  return '$base $u';
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
    case 'lock':
      // A binary_sensor lock reads on = unsecured/unlocked (attention),
      // off = locked (secure/neutral).
      return HaVisual(
        on ? Icons.lock_open : Icons.lock,
        on ? _kAmber : _kNeutral,
        label: on ? 'Unlocked' : 'Locked',
      );
    case 'smoke':
      return HaVisual(
        Icons.local_fire_department,
        on ? _kDanger : _kNeutral,
        label: on ? 'Smoke' : 'Clear',
        pulsing: on,
      );
    case 'gas':
      return HaVisual(
        Icons.co2,
        on ? _kDanger : _kNeutral,
        label: on ? 'Gas' : 'Clear',
        pulsing: on,
      );
    case 'leak':
      return HaVisual(
        Icons.water_damage,
        on ? _kAmber : _kNeutral,
        label: on ? 'Leak' : 'Dry',
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
    case 'lock':
      return Icons.lock;
    case 'smoke':
      return Icons.local_fire_department;
    case 'gas':
      return Icons.co2;
    case 'leak':
      return Icons.water_damage;
    default:
      return Icons.sensors;
  }
}
