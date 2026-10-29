// Data shapes for the Crumb server API. Snake_case JSON → camelCase Dart.
// See docs/desktop-flutter-P1.md and the API DTOs in services/api/src/dto.rs.

/// A viewer-visible camera (`GET /cameras` → `ViewerCameraDto`). Deliberately
/// has no stream URLs — those come from [CrumbApi.cameraStreams].
class Camera {
  Camera({
    required this.id,
    required this.name,
    required this.enabled,
    required this.hasSub,
    required this.ptz,
    required this.servedBy,
    this.oldestFootageTs,
    this.recordingMode,
  });

  final String id; // UUID
  final String name;
  final bool enabled;
  final bool hasSub;
  final bool ptz;
  final String servedBy; // "crumb" | "frigate"

  /// Start of the camera's oldest remaining recorded segment (UTC). Null when
  /// the camera has no footage, or the server predates the field. Anything
  /// earlier has been deleted by retention.
  final DateTime? oldestFootageTs;

  /// Recording mode of the camera's effective policy: `"continuous"` or
  /// `"motion"`. Null when the server predates the field.
  final String? recordingMode;

  factory Camera.fromJson(Map<String, dynamic> j) => Camera(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '(unnamed)',
    enabled: (j['enabled'] as bool?) ?? true,
    hasSub: (j['has_sub'] as bool?) ?? false,
    ptz: (j['ptz'] as bool?) ?? false,
    servedBy: (j['served_by'] as String?) ?? 'crumb',
    oldestFootageTs: j['oldest_footage_ts'] is String
        ? DateTime.tryParse(j['oldest_footage_ts'] as String)?.toUtc()
        : null,
    recordingMode: j['recording_mode'] as String?,
  );
}

/// Live stream URLs for one camera (`GET /cameras/{id}/streams`). The RTSP URLs
/// are go2rtc restreams and may embed `user:pass@` credentials — treat as
/// sensitive, never log them.
class StreamUrls {
  StreamUrls({this.rtspMain, this.rtspSub, this.rtspMobile});

  final String? rtspMain;
  final String? rtspSub;

  /// The on-demand low-bitrate `<name>_mobile` go2rtc transcode (the
  /// "Data saver" tier). Nullable — absent when the server has mobile streams
  /// disabled or the camera is Frigate-served. Callers must fall back
  /// (sub → main) when this is null so a pane never goes black.
  final String? rtspMobile;

  factory StreamUrls.fromJson(Map<String, dynamic> j) => StreamUrls(
    rtspMain: j['rtsp_main_url'] as String?,
    rtspSub: j['rtsp_sub_url'] as String?,
    rtspMobile: j['rtsp_mobile_url'] as String?,
  );

  /// Wall default: prefer the lighter sub stream, fall back to main. (Maximize
  /// will later prefer main.) Null only if neither is available.
  String? get preferredForWall => rtspSub ?? rtspMain;
}

/// An authenticated session: the server base URL + bearer token.
class Session {
  Session({required this.base, required this.token, this.expiresAt});

  final String base; // e.g. http://host:port (no trailing slash)
  final String token; // bearer JWT
  final DateTime? expiresAt;

  Map<String, dynamic> toJson() => {
    'base': base,
    'token': token,
    'expires_at': expiresAt?.toIso8601String(),
  };

  factory Session.fromJson(Map<String, dynamic> j) => Session(
    base: j['base'] as String,
    token: j['token'] as String,
    expiresAt: DateTime.tryParse((j['expires_at'] as String?) ?? ''),
  );
}
