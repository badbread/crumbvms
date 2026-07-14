// `GET /auth/me` — the caller's own profile, used at boot to confirm the
// server is reachable and the saved token still works BEFORE the camera wall
// is built. See services/api/src/auth.rs (`me`, `MeResponse`) and the old
// client's `fetchAndApplyMe` in apps/desktop/src/app.js, which this mirrors:
// boot always resolves `/auth/me` before `/cameras` so capability gating is
// in place before tiles render.
//
// Added as an extension (not a method on [CrumbApi] itself) so this feature
// stays a self-contained file — see crumb_api.dart's header comment.

import 'dart:convert';

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// `GET /auth/me` response. Deliberately keeps `capabilities` as a raw JSON
/// map rather than a fully-typed model — this feature (boot-time
/// reachability + retry) only needs `isAdmin`/`username` for its own display;
/// full capability-gating types belong to whatever feature consumes them.
class MeResponse {
  MeResponse({
    required this.id,
    required this.username,
    required this.role,
    required this.isAdmin,
    required this.capabilities,
    required this.cameraIds,
    this.roleId,
    this.platesEnabled = false,
  });

  final String id; // UUID
  final String username;
  final String role; // "admin" | "viewer"
  final bool isAdmin;
  final Map<String, dynamic> capabilities;
  final List<String> cameraIds;
  final String? roleId; // UUID, null for legacy binary-role users

  /// Server-side truth for whether the caller may use the license-plate (LPR)
  /// surface: true only when LPR is enabled server-side AND this account holds
  /// the `view_plates` capability. The single flag the Plates tab gates on —
  /// clients must NOT re-derive it from [capabilities]. Absent → false.
  final bool platesEnabled;

  factory MeResponse.fromJson(Map<String, dynamic> j) => MeResponse(
    id: j['id'] as String,
    username: j['username'] as String,
    role: (j['role'] as String?) ?? 'viewer',
    isAdmin: (j['is_admin'] as bool?) ?? false,
    capabilities: (j['capabilities'] as Map<String, dynamic>?) ?? const {},
    cameraIds:
        (j['camera_ids'] as List<dynamic>?)?.cast<String>() ?? const [],
    roleId: j['role_id'] as String?,
    platesEnabled: (j['plates_enabled'] as bool?) ?? false,
  );
}

extension BootApi on CrumbApi {
  /// `GET /auth/me` (mounted at the server root under `/auth`, Bearer JWT).
  ///
  /// Uses a fresh, short-lived [TimeoutClient] per call rather than reaching
  /// into [CrumbApi]'s internal client (private to crumb_api.dart, which this
  /// feature must not edit) — this is called once per boot attempt, not on a
  /// hot path.
  ///
  /// Throws [CrumbApiException] with `statusCode`:
  /// - `401` — the bearer token is dead (expired/revoked/deleted user);
  ///   callers should NOT keep retrying this in a boot-retry loop, it needs
  ///   re-authentication instead.
  /// - anything else (including no response at all, surfaced by the caller
  ///   catching non-`CrumbApiException` errors) — treat as "server
  ///   unreachable" and retry.
  Future<MeResponse> fetchMe(Session s) async {
    final client = TimeoutClient();
    try {
      final resp = await client.get(
        Uri.parse('${s.base}/auth/me'),
        headers: {'authorization': 'Bearer ${s.token}'},
      );
      if (resp.statusCode != 200) {
        throw CrumbApiException(
          resp.statusCode == 401
              ? 'Session expired.'
              : 'Failed to load profile (HTTP ${resp.statusCode}).',
          statusCode: resp.statusCode,
        );
      }
      return MeResponse.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    } finally {
      client.close();
    }
  }
}
