// Data shapes for the live-status-poll feature: `GET /status` (recording /
// motion health, config fingerprint, bookmarks toggle) and `GET /events`
// (active object-detection glyphs). Mirrors services/api/src/dto.rs
// (`SystemStatusResponse`, `CameraStatusEntry`, `DetectionEventDto`,
// `EventsResponse`) — snake_case JSON → camelCase Dart, matching the style of
// lib/api/models.dart.

/// Per-camera entry in `GET /status`'s `cameras` array.
class CameraStatus {
  CameraStatus({
    required this.id,
    required this.name,
    required this.enabled,
    required this.recording,
    required this.recentMotion,
    this.lastSegmentEnd,
  });

  final String id; // UUID
  final String name;
  final bool enabled;

  /// Segment index has a segment ending within the health-staleness window —
  /// i.e. the camera appears to be recording right now.
  final bool recording;

  /// Most recent segment has motion AND is fresh enough to count as "motion
  /// right now". Drives the live-wall motion indicator.
  final bool recentMotion;

  final DateTime? lastSegmentEnd;

  factory CameraStatus.fromJson(Map<String, dynamic> j) => CameraStatus(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '(unnamed)',
    enabled: (j['enabled'] as bool?) ?? true,
    recording: (j['recording'] as bool?) ?? false,
    recentMotion: (j['recent_motion'] as bool?) ?? false,
    lastSegmentEnd: DateTime.tryParse((j['last_segment_end'] as String?) ?? ''),
  );
}

/// `GET /status` response. Storage/recorder-heartbeat fields exist server-side
/// but aren't needed by this feature, so they're not modeled here — extra JSON
/// keys are simply ignored by `fromJson`.
class SystemStatus {
  SystemStatus({
    required this.cameras,
    required this.configVersion,
    required this.bookmarksEnabled,
  });

  final List<CameraStatus> cameras;

  /// Opaque fingerprint of camera + recording-policy config. Changes when an
  /// admin edits a camera/policy server-side; clients should re-fetch cameras
  /// + streams when it changes (see `LiveStatusController`).
  final String configVersion;

  /// Platform-wide bookmarks-UI toggle. `true` by default (older servers /
  /// missing field).
  final bool bookmarksEnabled;

  factory SystemStatus.fromJson(Map<String, dynamic> j) => SystemStatus(
    cameras: ((j['cameras'] as List<dynamic>?) ?? const [])
        .map((e) => CameraStatus.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    configVersion: (j['config_version'] as String?) ?? '',
    bookmarksEnabled: (j['bookmarks_enabled'] as bool?) ?? true,
  );
}

/// A single detection event (`GET /events`). This is the locked server
/// contract — see `DetectionEventDto` in services/api/src/dto.rs.
class DetectionEvent {
  DetectionEvent({
    required this.id,
    required this.cameraId,
    required this.ts,
    this.endTs,
    required this.label,
    required this.iconKey,
    this.subLabel,
    required this.score,
    required this.topScore,
    required this.zones,
    this.snapshotUrl,
    this.sourceId,
  });

  final String id; // UUID
  final String cameraId; // UUID
  final DateTime ts;
  final DateTime? endTs; // null while the detection is still in progress
  final String label;

  /// Client icon selector derived server-side from `label` (e.g. "person",
  /// "car", "truck", "license_plate", "motion"). Unknown labels get their own
  /// slug; clients should fall back to a generic marker.
  final String iconKey;
  final String? subLabel;
  final double score;
  final double topScore;
  final List<String> zones;
  final String? snapshotUrl;
  final String? sourceId;

  factory DetectionEvent.fromJson(Map<String, dynamic> j) => DetectionEvent(
    id: j['id'] as String,
    cameraId: j['camera_id'] as String,
    ts: DateTime.parse(j['ts'] as String),
    endTs: DateTime.tryParse((j['end_ts'] as String?) ?? ''),
    label: (j['label'] as String?) ?? '',
    iconKey: (j['icon_key'] as String?) ?? 'generic',
    subLabel: j['sub_label'] as String?,
    score: ((j['score'] as num?) ?? 0).toDouble(),
    topScore: ((j['top_score'] as num?) ?? 0).toDouble(),
    zones: ((j['zones'] as List<dynamic>?) ?? const [])
        .map((e) => e as String)
        .toList(growable: false),
    snapshotUrl: j['snapshot_url'] as String?,
    sourceId: j['source_id'] as String?,
  );
}

/// `GET /events` response.
class EventsResponse {
  EventsResponse({required this.events, required this.total, required this.hasMore});

  final List<DetectionEvent> events;
  final int total;
  final bool hasMore;

  factory EventsResponse.fromJson(Map<String, dynamic> j) => EventsResponse(
    events: ((j['events'] as List<dynamic>?) ?? const [])
        .map((e) => DetectionEvent.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    total: (j['total'] as num?)?.toInt() ?? 0,
    hasMore: (j['has_more'] as bool?) ?? false,
  );
}
