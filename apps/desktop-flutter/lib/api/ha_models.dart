// Data shapes for the Home Assistant on-video overlay feature (issue #170).
// Snake_case JSON -> camelCase Dart, mirroring the server DTOs exactly:
// `HaLinkDto` / `HaEntityState` / `HaStatesResponse` (services/api/src/ha.rs).

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
  );
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
