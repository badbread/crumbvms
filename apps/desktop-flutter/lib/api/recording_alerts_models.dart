// Data shapes for the recording-health-alert feature: the ADMIN-ONLY parts of
// `GET /status` (storages + recorder heartbeat) and `GET /stats/policies`.
// Deliberately separate from lib/api/status_models.dart's `SystemStatus`,
// which only models the per-camera fields that feature needs and explicitly
// ignores storages/recorder_heartbeat. Mirrors services/api/src/dto.rs
// (`StorageStatusEntry`, `SystemStatusResponse`) and services/api/src/stats.rs
// (`PolicyStatDto`) — snake_case JSON -> camelCase Dart.

/// Per-storage entry from `GET /status`'s `storages` array. Empty for
/// non-admin sessions (server withholds it), never null.
class RecordingStorageStatus {
  RecordingStorageStatus({
    required this.id,
    required this.name,
    required this.path,
    this.totalBytes,
    this.fsTotalBytes,
    this.freeBytes,
    required this.usedBytes,
    required this.icon,
  });

  final String id; // UUID
  final String name;
  final String path;

  /// Configured size cap for this storage (`null` = uncapped).
  final int? totalBytes;

  /// Total size of the underlying filesystem (statvfs) — the real physical
  /// capacity, independent of any cap. This (not [totalBytes]) is what the
  /// disk-full warning is computed from.
  final int? fsTotalBytes;

  /// Real free space on the underlying filesystem (statvfs).
  final int? freeBytes;
  final int usedBytes;

  /// Resolved media glyph: `"ssd"` | `"hdd"` | `"disk"`.
  final String icon;

  factory RecordingStorageStatus.fromJson(Map<String, dynamic> j) =>
      RecordingStorageStatus(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Disk',
        path: (j['path'] as String?) ?? '',
        totalBytes: (j['total_bytes'] as num?)?.toInt(),
        fsTotalBytes: (j['fs_total_bytes'] as num?)?.toInt(),
        freeBytes: (j['free_bytes'] as num?)?.toInt(),
        usedBytes: (j['used_bytes'] as num?)?.toInt() ?? 0,
        icon: (j['icon'] as String?) ?? 'disk',
      );
}

/// The admin-only slice of `GET /status` this feature needs: storages + the
/// recorder liveness heartbeat. Non-admin sessions get an empty `storages`
/// list and a `null` heartbeat (server withholds both) — the poller treats
/// that as "nothing to warn about" rather than an error.
class RecordingStatusSnapshot {
  RecordingStatusSnapshot({
    required this.storages,
    this.recorderHeartbeat,
    this.recorderActiveCameras,
  });

  final List<RecordingStorageStatus> storages;

  /// Timestamp of the recorder's last liveness heartbeat (`recorder_heartbeat`
  /// table, upserted ~every 10s). `null` if the recorder has never reported
  /// one (fresh install) or the session isn't admin.
  final DateTime? recorderHeartbeat;
  final int? recorderActiveCameras;

  factory RecordingStatusSnapshot.fromJson(Map<String, dynamic> j) =>
      RecordingStatusSnapshot(
        storages: ((j['storages'] as List<dynamic>?) ?? const [])
            .map(
              (e) =>
                  RecordingStorageStatus.fromJson(e as Map<String, dynamic>),
            )
            .toList(growable: false),
        recorderHeartbeat: DateTime.tryParse(
          (j['recorder_heartbeat'] as String?) ?? '',
        ),
        recorderActiveCameras: (j['recorder_active_cameras'] as num?)
            ?.toInt(),
      );
}

/// One row of `GET /stats/policies` — per-recording-policy storage usage +
/// forecast. Only the fields `computeRecordingWarnings` needs are modeled;
/// see `PolicyStatDto` in services/api/src/stats.rs for the full shape.
class PolicyStat {
  PolicyStat({
    required this.policyId,
    required this.label,
    required this.liveUsedBytes,
    this.liveMaxBytes,
    required this.liveRetentionHoursCap,
    this.sizeBoundRetentionHours,
    required this.bindingLimit,
  });

  final String policyId; // UUID
  final String label;
  final int liveUsedBytes;

  /// Live size budget shared across the policy's cameras; `null` = no cap.
  final int? liveMaxBytes;

  /// The policy's CONFIGURED time-retention (hours).
  final int liveRetentionHoursCap;

  /// At the current ingest rate, the hours of footage the size cap actually
  /// holds before eviction kicks in (`null` when no cap or rate ~0).
  final double? sizeBoundRetentionHours;

  /// Which limit binds first: `"size"` | `"time"` | `"none"`.
  final String bindingLimit;

  factory PolicyStat.fromJson(Map<String, dynamic> j) => PolicyStat(
    policyId: j['policy_id'] as String,
    label: (j['label'] as String?) ?? 'Policy',
    liveUsedBytes: (j['live_used_bytes'] as num?)?.toInt() ?? 0,
    liveMaxBytes: (j['live_max_bytes'] as num?)?.toInt(),
    liveRetentionHoursCap: (j['live_retention_hours_cap'] as num?)?.toInt() ?? 0,
    sizeBoundRetentionHours: (j['size_bound_retention_hours'] as num?)
        ?.toDouble(),
    bindingLimit: (j['binding_limit'] as String?) ?? 'none',
  );
}

/// `GET /stats/policies` response.
class PolicyStatsResponse {
  PolicyStatsResponse({required this.policies});

  final List<PolicyStat> policies;

  factory PolicyStatsResponse.fromJson(Map<String, dynamic> j) =>
      PolicyStatsResponse(
        policies: ((j['policies'] as List<dynamic>?) ?? const [])
            .map((e) => PolicyStat.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// Severity of a single recording-health warning. `crit` = the top banner
/// switches to its red/critical styling; `warn` = amber.
enum RecordingWarningLevel { warn, crit }

/// One computed warning line, as produced by `computeRecordingWarnings`.
class RecordingWarning {
  RecordingWarning({required this.level, required this.text});

  final RecordingWarningLevel level;
  final String text;
}
