// Data shapes for the native Server dashboard (connection info, per-camera
// stats, storage/disk health, per-policy usage + forecast, retention policy
// editor). Mirrors services/api/src/dto.rs + stats.rs response shapes.
// Snake_case JSON → camelCase Dart, following lib/api/models.dart's style.

/// `GET /status` response (`SystemStatusResponse`, dto.rs).
class ServerStatus {
  ServerStatus({
    required this.storages,
    required this.cameras,
    this.recorderHeartbeat,
    this.recorderPid,
    this.recorderActiveCameras,
    required this.configVersion,
    required this.bookmarksEnabled,
  });

  final List<StorageStatus> storages;
  final List<CameraStatus> cameras;
  final DateTime? recorderHeartbeat;
  final int? recorderPid;
  final int? recorderActiveCameras;
  final String configVersion;
  final bool bookmarksEnabled;

  factory ServerStatus.fromJson(Map<String, dynamic> j) => ServerStatus(
    storages: ((j['storages'] as List<dynamic>?) ?? const [])
        .map((e) => StorageStatus.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    cameras: ((j['cameras'] as List<dynamic>?) ?? const [])
        .map((e) => CameraStatus.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    recorderHeartbeat: DateTime.tryParse(
      (j['recorder_heartbeat'] as String?) ?? '',
    ),
    recorderPid: j['recorder_pid'] as int?,
    recorderActiveCameras: j['recorder_active_cameras'] as int?,
    configVersion: (j['config_version'] as String?) ?? '',
    bookmarksEnabled: (j['bookmarks_enabled'] as bool?) ?? true,
  );
}

/// `StorageStatusEntry` — one recording volume, admin-only (empty for viewers).
class StorageStatus {
  StorageStatus({
    required this.id,
    required this.name,
    required this.path,
    this.totalBytes,
    this.fsTotalBytes,
    this.freeBytes,
    required this.usedBytes,
    required this.icon, // "ssd" | "hdd" | "disk", server-resolved
  });

  final String id;
  final String name;
  final String path;
  final int? totalBytes; // configured cap, null = uncapped
  final int? fsTotalBytes; // statvfs total
  final int? freeBytes;
  final int usedBytes; // DB-tracked segment bytes
  final String icon;

  factory StorageStatus.fromJson(Map<String, dynamic> j) => StorageStatus(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    path: (j['path'] as String?) ?? '',
    totalBytes: (j['total_bytes'] as num?)?.toInt(),
    fsTotalBytes: (j['fs_total_bytes'] as num?)?.toInt(),
    freeBytes: (j['free_bytes'] as num?)?.toInt(),
    usedBytes: (j['used_bytes'] as num?)?.toInt() ?? 0,
    icon: (j['icon'] as String?) ?? 'disk',
  );

  /// Capacity denominator for a usage bar: the configured cap if set, else the
  /// live filesystem size.
  int? get capacityBytes => totalBytes ?? fsTotalBytes;
}

/// `CameraStatusEntry` — per-camera recording health from `/status`.
class CameraStatus {
  CameraStatus({
    required this.id,
    required this.name,
    required this.enabled,
    required this.recording,
    required this.recentMotion,
    this.lastSegmentEnd,
  });

  final String id;
  final String name;
  final bool enabled;
  final bool recording;
  final bool recentMotion;
  final DateTime? lastSegmentEnd;

  factory CameraStatus.fromJson(Map<String, dynamic> j) => CameraStatus(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    enabled: (j['enabled'] as bool?) ?? true,
    recording: (j['recording'] as bool?) ?? false,
    recentMotion: (j['recent_motion'] as bool?) ?? false,
    lastSegmentEnd: DateTime.tryParse((j['last_segment_end'] as String?) ?? ''),
  );
}

/// `CameraStatDto` — one row of `GET /stats/cameras` (admin only).
class CameraStat {
  CameraStat({
    required this.cameraId,
    required this.name,
    required this.totalBytes,
    required this.segmentCount,
    this.oldestTs,
    this.newestTs,
    required this.gbPerHour,
    required this.retentionHours,
    required this.cpuPct,
    required this.memMb,
    this.gpuPct,
  });

  final String cameraId;
  final String name;
  final int totalBytes;
  final int segmentCount;
  final DateTime? oldestTs;
  final DateTime? newestTs;
  final double gbPerHour;
  final double retentionHours;
  final double cpuPct;
  final double memMb;
  final double? gpuPct;

  factory CameraStat.fromJson(Map<String, dynamic> j) => CameraStat(
    cameraId: j['camera_id'] as String,
    name: (j['name'] as String?) ?? '',
    totalBytes: (j['total_bytes'] as num?)?.toInt() ?? 0,
    segmentCount: (j['segment_count'] as num?)?.toInt() ?? 0,
    oldestTs: DateTime.tryParse((j['oldest_ts'] as String?) ?? ''),
    newestTs: DateTime.tryParse((j['newest_ts'] as String?) ?? ''),
    gbPerHour: (j['gb_per_hour'] as num?)?.toDouble() ?? 0.0,
    retentionHours: (j['retention_hours'] as num?)?.toDouble() ?? 0.0,
    cpuPct: (j['cpu_pct'] as num?)?.toDouble() ?? 0.0,
    memMb: (j['mem_mb'] as num?)?.toDouble() ?? 0.0,
    gpuPct: (j['gpu_pct'] as num?)?.toDouble(),
  );
}

/// `PolicyStatDto` — one row of `GET /stats/policies` (per effective policy
/// usage + eviction forecast).
class PolicyStat {
  PolicyStat({
    required this.policyId,
    this.name,
    required this.label,
    required this.isDefault,
    required this.mode,
    required this.cameraCount,
    required this.cameraNames,
    required this.liveUsedBytes,
    this.liveMaxBytes,
    required this.archiveUsedBytes,
    this.archiveMaxBytes,
    required this.gbPerHour,
    required this.liveRetentionHoursNow,
    required this.liveRetentionHoursCap,
    this.liveTimeToFullHours,
    this.sizeBoundRetentionHours,
    required this.bindingLimit, // "size" | "time" | "none"
  });

  final String policyId;
  final String? name;
  final String label;
  final bool isDefault;
  final String mode; // "continuous" | "motion"
  final int cameraCount;
  final List<String> cameraNames;
  final int liveUsedBytes;
  final int? liveMaxBytes;
  final int archiveUsedBytes;
  final int? archiveMaxBytes;
  final double gbPerHour;
  final double liveRetentionHoursNow;
  final int liveRetentionHoursCap;
  final double? liveTimeToFullHours;
  final double? sizeBoundRetentionHours;
  final String bindingLimit;

  factory PolicyStat.fromJson(Map<String, dynamic> j) => PolicyStat(
    policyId: j['policy_id'] as String,
    name: j['name'] as String?,
    label: (j['label'] as String?) ?? 'Default',
    isDefault: (j['is_default'] as bool?) ?? false,
    mode: (j['mode'] as String?) ?? 'continuous',
    cameraCount: (j['camera_count'] as num?)?.toInt() ?? 0,
    cameraNames: ((j['camera_names'] as List<dynamic>?) ?? const [])
        .map((e) => e as String)
        .toList(growable: false),
    liveUsedBytes: (j['live_used_bytes'] as num?)?.toInt() ?? 0,
    liveMaxBytes: (j['live_max_bytes'] as num?)?.toInt(),
    archiveUsedBytes: (j['archive_used_bytes'] as num?)?.toInt() ?? 0,
    archiveMaxBytes: (j['archive_max_bytes'] as num?)?.toInt(),
    gbPerHour: (j['gb_per_hour'] as num?)?.toDouble() ?? 0.0,
    liveRetentionHoursNow:
        (j['live_retention_hours_now'] as num?)?.toDouble() ?? 0.0,
    liveRetentionHoursCap: (j['live_retention_hours_cap'] as num?)?.toInt() ?? 0,
    liveTimeToFullHours: (j['live_time_to_full_hours'] as num?)?.toDouble(),
    sizeBoundRetentionHours:
        (j['size_bound_retention_hours'] as num?)?.toDouble(),
    bindingLimit: (j['binding_limit'] as String?) ?? 'none',
  );
}

/// `PolicyVerifyDto` — one row of `GET /stats/policies/verify` (on-demand
/// DB-tracked vs actual-on-disk byte reconciliation).
class PolicyVerify {
  PolicyVerify({
    required this.policyId,
    required this.label,
    required this.dbBytes,
    required this.diskBytes,
    required this.deltaBytes,
    required this.deltaPct,
  });

  final String policyId;
  final String label;
  final int dbBytes;
  final int diskBytes;
  final int deltaBytes;
  final double deltaPct;

  factory PolicyVerify.fromJson(Map<String, dynamic> j) => PolicyVerify(
    policyId: j['policy_id'] as String,
    label: (j['label'] as String?) ?? '',
    dbBytes: (j['db_bytes'] as num?)?.toInt() ?? 0,
    diskBytes: (j['disk_bytes'] as num?)?.toInt() ?? 0,
    deltaBytes: (j['delta_bytes'] as num?)?.toInt() ?? 0,
    deltaPct: (j['delta_pct'] as num?)?.toDouble() ?? 0.0,
  );
}

/// `RecordingPolicyDto` — a full recording-policy row (default, named, or an
/// anonymous per-camera fork when `name == null`). Used by both the retention
/// policy editor (`GET/PUT /config/policy/default`,
/// `PUT /config/cameras/{id}/policy`) and embedded in [CameraConfigSummary].
class RecordingPolicy {
  RecordingPolicy({
    required this.id,
    this.name,
    required this.isDefault,
    required this.mode,
    this.liveStorageId,
    required this.liveRetentionHours,
    required this.archiveEnabled,
    this.archiveStorageId,
    this.archiveSchedule,
    this.archiveRetentionHours,
    this.liveMaxBytes,
    this.archiveMaxBytes,
    this.liveMinFreePct,
    this.liveMinFreeBytes,
    this.liveSpillLowWaterBytes,
    this.maxRetentionDays,
    required this.motionPreSeconds,
    required this.motionPostSeconds,
    required this.motionSensitivity,
    this.motionThreshold,
    required this.motionKeyframesOnly,
    required this.recordStream,
    required this.recordAudio,
  });

  final String id;
  final String? name; // null = anonymous per-camera fork ("Custom")
  final bool isDefault;
  final String mode; // "continuous" | "motion"
  final String? liveStorageId;
  final int liveRetentionHours;
  final bool archiveEnabled;
  final String? archiveStorageId;
  final String? archiveSchedule;
  final int? archiveRetentionHours;
  final int? liveMaxBytes;
  final int? archiveMaxBytes;
  final double? liveMinFreePct;
  final int? liveMinFreeBytes;
  final int? liveSpillLowWaterBytes;
  final int? maxRetentionDays;
  final int motionPreSeconds;
  final int motionPostSeconds;
  final String motionSensitivity; // "dynamic" | "manual"
  final double? motionThreshold;
  final bool motionKeyframesOnly;
  final String recordStream; // "main" | "sub"
  final bool recordAudio;

  factory RecordingPolicy.fromJson(Map<String, dynamic> j) => RecordingPolicy(
    id: j['id'] as String,
    name: j['name'] as String?,
    isDefault: (j['is_default'] as bool?) ?? false,
    mode: (j['mode'] as String?) ?? 'continuous',
    liveStorageId: j['live_storage_id'] as String?,
    liveRetentionHours: (j['live_retention_hours'] as num?)?.toInt() ?? 0,
    archiveEnabled: (j['archive_enabled'] as bool?) ?? false,
    archiveStorageId: j['archive_storage_id'] as String?,
    archiveSchedule: j['archive_schedule'] as String?,
    archiveRetentionHours: (j['archive_retention_hours'] as num?)?.toInt(),
    liveMaxBytes: (j['live_max_bytes'] as num?)?.toInt(),
    archiveMaxBytes: (j['archive_max_bytes'] as num?)?.toInt(),
    liveMinFreePct: (j['live_min_free_pct'] as num?)?.toDouble(),
    liveMinFreeBytes: (j['live_min_free_bytes'] as num?)?.toInt(),
    liveSpillLowWaterBytes: (j['live_spill_low_water_bytes'] as num?)?.toInt(),
    maxRetentionDays: (j['max_retention_days'] as num?)?.toInt(),
    motionPreSeconds: (j['motion_pre_seconds'] as num?)?.toInt() ?? 0,
    motionPostSeconds: (j['motion_post_seconds'] as num?)?.toInt() ?? 0,
    motionSensitivity: (j['motion_sensitivity'] as String?) ?? 'dynamic',
    motionThreshold: (j['motion_threshold'] as num?)?.toDouble(),
    motionKeyframesOnly: (j['motion_keyframes_only'] as bool?) ?? false,
    recordStream: (j['record_stream'] as String?) ?? 'main',
    recordAudio: (j['record_audio'] as bool?) ?? false,
  );

  /// Display label for pickers: the name, else `Custom — <owning camera>`-style
  /// callers should already have from PolicyStat.label; for a bare policy this
  /// just falls back to "Default"/"Custom".
  String get displayLabel => name ?? (isDefault ? 'Default' : 'Custom');
}

/// Minimal camera row from `GET /config/cameras` (`CameraDto`, admin only) —
/// just enough for the policy-editor's camera picker: identity + how its
/// recording policy is currently resolved.
class CameraConfigSummary {
  CameraConfigSummary({
    required this.id,
    required this.name,
    required this.enabled,
    this.policyId,
    this.groupId,
    required this.policy,
  });

  final String id;
  final String name;
  final bool enabled;
  /// The camera's OWN direct policy id, or null when it inherits from its
  /// group or the global default.
  final String? policyId;
  final String? groupId;
  /// The RESOLVED effective policy (own → group → default).
  final RecordingPolicy policy;

  factory CameraConfigSummary.fromJson(Map<String, dynamic> j) =>
      CameraConfigSummary(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '(unnamed)',
        enabled: (j['enabled'] as bool?) ?? true,
        policyId: j['policy_id'] as String?,
        groupId: j['group_id'] as String?,
        policy: RecordingPolicy.fromJson(j['policy'] as Map<String, dynamic>),
      );

  /// Whether this camera has its own direct override rather than inheriting.
  bool get hasOwnPolicy => policyId != null;
}

/// A partial update body for `PUT /config/policy/default` or
/// `PUT /config/cameras/{id}/policy` (`UpdatePolicyRequest`, dto.rs).
///
/// Every field is OMITTED unless explicitly set via one of the setters below,
/// matching the server's "absent = unchanged" partial-update semantics. For
/// the handful of clearable fields (server-side `Option<Option<T>>` via
/// `double_option`), passing `null` to the setter serializes an explicit JSON
/// `null`, which the server reads as "clear to default/uncapped" — distinct
/// from never calling the setter at all.
class PolicyPatch {
  final Map<String, dynamic> _fields = {};

  bool get isEmpty => _fields.isEmpty;
  Map<String, dynamic> toJson() => Map.unmodifiable(_fields);

  void mode(String v) => _fields['mode'] = v; // "continuous" | "motion"
  void liveStorageId(String v) => _fields['live_storage_id'] = v;
  void liveRetentionHours(int v) => _fields['live_retention_hours'] = v;
  void archiveEnabled(bool v) => _fields['archive_enabled'] = v;
  void archiveStorageId(String? v) => _fields['archive_storage_id'] = v;
  void archiveSchedule(String? v) => _fields['archive_schedule'] = v;
  void archiveRetentionHours(int? v) => _fields['archive_retention_hours'] = v;
  void liveMaxBytes(int? v) => _fields['live_max_bytes'] = v;
  void archiveMaxBytes(int? v) => _fields['archive_max_bytes'] = v;
  void liveMinFreePct(double? v) => _fields['live_min_free_pct'] = v;
  void liveMinFreeBytes(int? v) => _fields['live_min_free_bytes'] = v;
  void liveSpillLowWaterBytes(int? v) =>
      _fields['live_spill_low_water_bytes'] = v;
  void maxRetentionDays(int? v) => _fields['max_retention_days'] = v;
  void motionPreSeconds(int v) => _fields['motion_pre_seconds'] = v;
  void motionPostSeconds(int v) => _fields['motion_post_seconds'] = v;
  void motionSensitivity(String v) => _fields['motion_sensitivity'] = v;
  void motionThreshold(double? v) => _fields['motion_threshold'] = v;
  void motionKeyframesOnly(bool v) => _fields['motion_keyframes_only'] = v;
  void recordStream(String v) => _fields['record_stream'] = v; // "main"|"sub"
  void recordAudio(bool v) => _fields['record_audio'] = v;
}
