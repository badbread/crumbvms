// Data shapes for the Home Assistant integration (issue #52 connection +
// entity linking, issue #170 on-video overlay). Snake_case JSON -> camelCase
// Dart, mirroring the server DTOs exactly (services/api/src/ha.rs):
// `HaConfigDto` / `HaEntity` / `HaLinkDto` / `HaEntityState` /
// `HaStatesResponse`.

/// A camera's linked HA entity (`GET /cameras/:id/ha/links`), including its
/// on-video overlay placement, if any. One link -> at most one badge.
class HaLink {
  HaLink({
    required this.id,
    required this.entityId,
    required this.role,
    this.deviceClass,
    this.label,
    required this.sortOrder,
    this.overlayX,
    this.overlayY,
    this.overlaySize,
    this.overlayColor,
    this.overlayIcon,
    this.overlayShowState = false,
    this.overlayShowAge = false,
  });

  final String id; // UUID
  final String entityId;

  /// `"motion" | "sensor" | "actuator"` (see migration 0048).
  final String role;

  /// HA `device_class` (`door`, `motion`, ...), binary_sensor links only.
  final String? deviceClass;

  /// Operator-set display label; falls back to [entityId] when unset (see
  /// [displayLabel]).
  final String? label;
  final int sortOrder;

  /// Normalized fraction (0..1) of the DISPLAYED video frame — top-left
  /// anchor of the rendered badge. Set together with [overlayY]; null when
  /// this link is not placed on the video.
  final double? overlayX;
  final double? overlayY;

  /// Badge scale multiplier (1.0 = default) when placed, else null.
  final double? overlaySize;

  /// Per-badge display overrides (migration 0059). [overlayColor] is a
  /// '#RRGGBB' hex string overriding the state-derived badge color;
  /// [overlayIcon] a curated icon slug overriding the class-derived glyph
  /// (`ha_overlay/ha_icons.dart`'s `kHaBadgeIconChoices`). Null = default.
  final String? overlayColor;
  final String? overlayIcon;

  /// Pin the live state text ("Open"/"On") / relative last-changed age next
  /// to the badge on the wall (default off — hover/tap reveal only).
  final bool overlayShowState;
  final bool overlayShowAge;

  bool get hasPlacement => overlayX != null && overlayY != null;

  /// The entity_id's domain prefix (`binary_sensor`, `light`, `switch`,
  /// `scene`, ...); empty string if [entityId] has no dot.
  String get domain {
    final i = entityId.indexOf('.');
    return i < 0 ? '' : entityId.substring(0, i);
  }

  /// Display label: the operator's rename if set, else the raw entity_id
  /// (mirrors the admin console's link-row rendering convention).
  String get displayLabel =>
      (label != null && label!.trim().isNotEmpty) ? label! : entityId;

  factory HaLink.fromJson(Map<String, dynamic> j) => HaLink(
    id: j['id'] as String,
    entityId: j['entity_id'] as String,
    role: (j['role'] as String?) ?? 'sensor',
    deviceClass: j['device_class'] as String?,
    label: j['label'] as String?,
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
    overlayX: (j['overlay_x'] as num?)?.toDouble(),
    overlayY: (j['overlay_y'] as num?)?.toDouble(),
    overlaySize: (j['overlay_size'] as num?)?.toDouble(),
    overlayColor: j['overlay_color'] as String?,
    overlayIcon: j['overlay_icon'] as String?,
    overlayShowState: (j['overlay_show_state'] as bool?) ?? false,
    overlayShowAge: (j['overlay_show_age'] as bool?) ?? false,
  );
}

/// The Home Assistant connection config (`GET /config/ha`). The token itself
/// is NEVER returned — write-only server-side (`HaConfigDto`,
/// services/api/src/ha.rs) — [hasToken] is the only signal a client gets
/// about whether one is stored.
class HaConfig {
  HaConfig({required this.enabled, required this.baseUrl, required this.hasToken});

  final bool enabled;
  final String baseUrl;

  /// True when a non-empty token is already stored server-side.
  final bool hasToken;

  factory HaConfig.fromJson(Map<String, dynamic> j) => HaConfig(
    enabled: (j['enabled'] as bool?) ?? false,
    baseUrl: (j['base_url'] as String?) ?? '',
    hasToken: (j['has_token'] as bool?) ?? false,
  );
}

/// One HA entity from the picker's data source (`GET /ha/entities`) — NOT
/// yet linked to any camera. Mirrors the server's `HaEntity` DTO
/// (services/api/src/ha.rs), which itself proxies HA's `/api/states` so the
/// HA token never reaches the client.
class HaEntity {
  HaEntity({required this.entityId, required this.friendlyName, this.deviceClass});

  final String entityId;
  final String friendlyName;

  /// HA `device_class` (`door`, `motion`, ...) — `binary_sensor` entities
  /// only; null for lights/switches/scenes.
  final String? deviceClass;

  /// The entity_id's domain prefix (`binary_sensor`, `light`, `switch`,
  /// `scene`, ...); empty string if [entityId] has no dot.
  String get domain {
    final i = entityId.indexOf('.');
    return i < 0 ? '' : entityId.substring(0, i);
  }

  factory HaEntity.fromJson(Map<String, dynamic> j) => HaEntity(
    entityId: j['entity_id'] as String,
    friendlyName: (j['friendly_name'] as String?) ?? (j['entity_id'] as String),
    deviceClass: j['device_class'] as String?,
  );
}

/// One entry of the `PUT /cameras/:id/ha/links` request body — mirrors the
/// admin console's link-editing working set (`HA_LINKS`,
/// services/api/src/admin.html's `saveHaLinks()`): the FULL desired link set
/// is sent on every save, not a diff.
class HaLinkInput {
  HaLinkInput({
    required this.entityId,
    required this.role,
    this.deviceClass,
    this.label,
    required this.sortOrder,
  });

  final String entityId;

  /// `"motion"` (binary_sensor picker) or `"actuator"` (light/switch/scene
  /// picker) — the desktop linking dialog only ever produces these two, same
  /// as the admin console's `haOpenPicker('motion' | 'actuator')`. `"sensor"`
  /// is reserved server-side for a later status-only-overlay role and is
  /// never written by this UI.
  final String role;
  final String? deviceClass;
  final String? label;
  final int sortOrder;

  /// Round-trip an already-saved [HaLink] back into an editable input (e.g.
  /// loading the working set from `GET /cameras/:id/ha/links`, or carrying
  /// an unchanged link forward into the next save).
  factory HaLinkInput.fromLink(HaLink l) => HaLinkInput(
    entityId: l.entityId,
    role: l.role,
    deviceClass: l.deviceClass,
    label: l.label,
    sortOrder: l.sortOrder,
  );

  Map<String, dynamic> toJson() => {
    'entity_id': entityId,
    'role': role,
    'device_class': deviceClass,
    'label': label,
    'sort_order': sortOrder,
  };
}

/// One entity's current reading from `GET /ha/states`.
class HaEntityState {
  HaEntityState({required this.state, this.lastChanged});

  /// Raw HA state string (e.g. `"on"`, `"open"`, `"unavailable"`). Never
  /// reinterpret this as a boolean directly — use `ha_overlay/ha_icons.dart`'s
  /// `edgeOn`, which mirrors the server's `edge_on` invariant (unavailable/
  /// unknown are INDETERMINATE, never "off").
  final String state;

  /// HA `last_changed` (RFC3339), passed through verbatim for "N ago" display.
  final DateTime? lastChanged;

  factory HaEntityState.fromJson(Map<String, dynamic> j) => HaEntityState(
    state: (j['state'] as String?) ?? '',
    lastChanged: DateTime.tryParse((j['last_changed'] as String?) ?? ''),
  );
}

/// `GET /ha/states` response: caller-visible entity states + cache age, so
/// the client can show a "stale" treatment without guessing.
class HaStatesSnapshot {
  HaStatesSnapshot({
    required this.fetchedAtMsAgo,
    required this.stale,
    required this.byEntity,
  });

  /// Age of the served snapshot in milliseconds.
  final int fetchedAtMsAgo;

  /// True when HA is currently unreachable and this is a last-known
  /// snapshot; badges must grey out rather than trust it as authoritative.
  final bool stale;

  final Map<String, HaEntityState> byEntity;

  /// Empty/never-polled snapshot — not stale (no data to distrust yet, but
  /// callers should treat "no entry" the same as "unknown" either way).
  static final empty = HaStatesSnapshot(
    fetchedAtMsAgo: 0,
    stale: false,
    byEntity: const {},
  );

  factory HaStatesSnapshot.fromJson(Map<String, dynamic> j) {
    final list = (j['states'] as List<dynamic>?) ?? const [];
    final map = <String, HaEntityState>{};
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      final id = m['entity_id'] as String?;
      if (id == null) continue;
      map[id] = HaEntityState.fromJson(m);
    }
    return HaStatesSnapshot(
      fetchedAtMsAgo: (j['fetched_at_ms_ago'] as num?)?.toInt() ?? 0,
      stale: (j['stale'] as bool?) ?? false,
      byEntity: map,
    );
  }
}
