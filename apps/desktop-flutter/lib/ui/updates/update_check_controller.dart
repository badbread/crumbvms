// Update-available poller + dismiss state. Ported from apps/desktop/src/app.js
// (`updateState`, `updCheck`, `updMaybeCheck`, `startUpdateCheckPoll`,
// `stopUpdateCheckPoll`, `updEnterAbout`, `updResolveOwnVersion`,
// `getDismissedUpdateVersion`/`setDismissedUpdateVersion`). The signal comes
// from THIS server's GET /updates/latest (server-mediated — the client never
// talks to GitHub itself, docs/UPDATE-SYSTEM-PLAN.md D2); the "is this newer
// than what I'm running" compare is local, against the CLIENT's own build
// version (package_info_plus), not the server's.
//
// A 404 (old server without the endpoint) or a 200 with enabled:false both
// collapse to "no update state" — nothing shows.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api/crumb_api.dart';
import '../../api/models.dart';
import '../../api/updates_api.dart';
import '../../api/updates_models.dart';

/// localStorage key equivalent (`LS_UPDATE_DISMISSED_KEY` in app.js) —
/// remembers the last dismissed version so the banner stays quiet until a
/// newer release appears (per-version, not permanent).
const _kDismissedVersionKey = 'crumb_update_dismissed_version';

/// Periodic re-check interval while the app stays open (app.js
/// `UPDATE_CHECK_INTERVAL_MS`).
const _pollInterval = Duration(hours: 24);

/// Debounces a burst of checks fired close together (a launch check + an
/// About-panel open, or rapid re-renders) into one actual request. Does NOT
/// gate a forced "Check now" (app.js `UPDATE_CHECK_MIN_GAP_MS`).
const _minGapBetweenChecks = Duration(seconds: 15);

/// Parse a bare "MAJOR.MINOR.PATCH" string into (maj, min, patch). Anything
/// else (a dev build like "0.0.1-dev", empty, non-numeric) is unparsable —
/// callers must treat that as "don't know", never guess a comparison.
(int, int, int)? parseVersion(String? v) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch((v ?? '').trim());
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// True only when `latest` is a parsable version strictly greater than `own`.
/// Either side failing to parse means never claim newer (own == a dev build,
/// or a malformed latest_version) rather than guessing.
bool isNewerVersion(String? latest, String? own) {
  final a = parseVersion(latest);
  final b = parseVersion(own);
  if (a == null || b == null) return false;
  if (a.$1 != b.$1) return a.$1 > b.$1;
  if (a.$2 != b.$2) return a.$2 > b.$2;
  return a.$3 > b.$3;
}

/// Polls `GET /updates/latest`, resolves this build's own version, and tracks
/// per-version banner dismissal. Attach to a long-lived widget (e.g. the app
/// shell) and call [start] once a session is established; call [stop] on
/// sign-out and [dispose] on teardown.
class UpdateCheckController extends ChangeNotifier {
  UpdateCheckController({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  Timer? _timer;
  UpdateCheckResponse? _data;
  String? _ownVersion; // null = unknown/dev build, resolved once via package_info_plus
  bool _checking = false;
  DateTime? _lastCheckAt;
  String _dismissedVersion = '';
  bool _dismissedLoaded = false;

  /// Last successful enabled:true response, or null (disabled/404/never
  /// checked).
  UpdateCheckResponse? get data => _data;

  /// This build's own version string, or null if unresolved/unparsable.
  String? get ownVersion => _ownVersion;

  /// True while a request is in flight (About panel shows "Checking…").
  bool get checking => _checking;

  bool get enabled => _data != null;

  /// Whether [data]'s latest_version is a parsable version strictly newer
  /// than [ownVersion].
  bool get updateAvailable =>
      _data != null && isNewerVersion(_data!.latestVersion, _ownVersion);

  /// Whether the always-present Updates field should show a dismissible
  /// proactive banner: an update is available AND this version hasn't been
  /// dismissed yet.
  bool get showBanner =>
      updateAvailable && _data!.latestVersion != _dismissedVersion;

  /// Begin the update poll on app launch / sign-in: resolve own version, run
  /// one check now (every launch — NOT gated behind the 24h interval), then
  /// re-check periodically while the app stays open.
  void start() {
    _timer?.cancel();
    unawaited(_loadDismissed());
    if (_ownVersion == null) unawaited(_resolveOwnVersion());
    _lastCheckAt = null; // ensure the launch check always fires
    unawaited(maybeCheck());
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(check(false)));
  }

  /// Stop the poll and clear the notice (sign-out).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _checking = false;
    if (_data != null) {
      _data = null;
      notifyListeners();
    }
  }

  /// Opening the About panel triggers a fresh check (coalesced by
  /// [maybeCheck]) so the always-present field is never stale — this is how a
  /// client that first checked while the server had the feature OFF can
  /// discover it was later turned on.
  void enterAbout() {
    unawaited(maybeCheck());
  }

  /// Fire a normal (non-forced) check unless one ran very recently.
  Future<void> maybeCheck() async {
    if (_checking) return;
    final last = _lastCheckAt;
    if (last != null && DateTime.now().difference(last) < _minGapBetweenChecks) {
      return;
    }
    await check(false);
  }

  /// "Check now": force a fresh server-side check, bypassing the debounce.
  Future<void> checkNow() => check(true);

  Future<void> check(bool refresh) async {
    _checking = true;
    _lastCheckAt = DateTime.now();
    notifyListeners();
    try {
      final res = await api.getLatestUpdate(session, refresh: refresh);
      // enabled:false or a 404 (null) both clear the state — nothing shows.
      _data = (res != null && res.enabled) ? res : null;
    } catch (_) {
      // Transient failure — keep the last known state, matching app.js's
      // empty catch in updCheck.
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// Dismiss the current banner — remembers this version so it stays quiet
  /// until a newer release appears. The always-present About field still
  /// shows the available update.
  Future<void> dismiss() async {
    final latest = _data?.latestVersion;
    if (latest == null) return;
    _dismissedVersion = latest;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDismissedVersionKey, latest);
    } catch (_) {
      // Quota/unavailable — in-memory state still suppresses the banner for
      // the rest of this session.
    }
  }

  Future<void> _resolveOwnVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _ownVersion = info.version.trim().isEmpty ? null : info.version.trim();
    } catch (_) {
      _ownVersion = null;
    }
    notifyListeners();
  }

  Future<void> _loadDismissed() async {
    if (_dismissedLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _dismissedVersion = prefs.getString(_kDismissedVersionKey) ?? '';
    } catch (_) {
      _dismissedVersion = '';
    }
    _dismissedLoaded = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
