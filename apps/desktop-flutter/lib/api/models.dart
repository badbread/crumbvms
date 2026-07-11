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
  });

  final String id; // UUID
  final String name;
  final bool enabled;
  final bool hasSub;
  final bool ptz;
  final String servedBy; // "crumb" | "frigate"

  factory Camera.fromJson(Map<String, dynamic> j) => Camera(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '(unnamed)',
    enabled: (j['enabled'] as bool?) ?? true,
    hasSub: (j['has_sub'] as bool?) ?? false,
    ptz: (j['ptz'] as bool?) ?? false,
    servedBy: (j['served_by'] as String?) ?? 'crumb',
  );
}

/// Live stream URLs for one camera (`GET /cameras/{id}/streams`). The RTSP URLs
/// are go2rtc restreams and may embed `user:pass@` credentials — treat as
/// sensitive, never log them.
class StreamUrls {
  StreamUrls({this.rtspMain, this.rtspSub});

  final String? rtspMain;
  final String? rtspSub;

  factory StreamUrls.fromJson(Map<String, dynamic> j) => StreamUrls(
    rtspMain: j['rtsp_main_url'] as String?,
    rtspSub: j['rtsp_sub_url'] as String?,
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
}
