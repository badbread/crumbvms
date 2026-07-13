// Data shape for `GET /updates/latest` — see services/api/src/dto.rs
// (`UpdateCheckResponse`) and services/api/src/updates.rs. snake_case JSON ->
// camelCase Dart, mirroring the style of lib/api/recording_alerts_models.dart.
//
// `enabled: false` means every other field is null (that, not a 404, is how
// the server tells "operator turned the check off" apart from "server too
// old to have this endpoint at all" — see UpdatesApi.getLatestUpdate).

class UpdateCheckResponse {
  UpdateCheckResponse({
    required this.enabled,
    this.latestVersion,
    this.notesUrl,
    this.publishedAt,
    this.serverVersion,
    this.serverUpdateAvailable,
    this.checkedAt,
  });

  final bool enabled;

  /// Newest stable release tag from GitHub, without the leading `v`.
  final String? latestVersion;

  /// GitHub release page URL (release notes).
  final String? notesUrl;
  final DateTime? publishedAt;

  /// This server's own build version (server-side comparison target, distinct
  /// from the client's own version resolved locally).
  final String? serverVersion;

  /// `latestVersion > serverVersion`, per the server's SemVer compare. `null`
  /// when either side failed to parse — "no signal", never a false
  /// "up to date". Not used directly by the client banner (which compares
  /// [latestVersion] against the CLIENT's own version instead), but exposed
  /// for the About panel's server-version line.
  final bool? serverUpdateAvailable;

  /// When the returned release data was last actually refreshed from GitHub
  /// (stale-while-error: an old timestamp during a GitHub outage is the
  /// intentional signal, not an error).
  final DateTime? checkedAt;

  factory UpdateCheckResponse.fromJson(Map<String, dynamic> j) =>
      UpdateCheckResponse(
        enabled: j['enabled'] as bool? ?? false,
        latestVersion: j['latest_version'] as String?,
        notesUrl: j['notes_url'] as String?,
        publishedAt: DateTime.tryParse((j['published_at'] as String?) ?? ''),
        serverVersion: j['server_version'] as String?,
        serverUpdateAvailable: j['server_update_available'] as bool?,
        checkedAt: DateTime.tryParse((j['checked_at'] as String?) ?? ''),
      );
}
