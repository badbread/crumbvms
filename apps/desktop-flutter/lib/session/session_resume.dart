// Launch-time resume of a DPAPI-stored session.
//
// An unattended wall PC is typically back from a power cut long before the
// server stack (NAS, hypervisor, containers, DB migrations) is. The stored
// token is still valid then, so the client must keep trying it, with capped
// backoff and indefinitely, and fall back to the login form ONLY when the
// server actually rejects the token (HTTP 401), never because the network or
// server was merely unreachable (#146).

import 'dart:async';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

/// Quick attempts made behind the launch spinner before the UI switches to its
/// "waiting for server" state (the loop itself keeps going).
const int kResumeQuickAttempts = 5;

/// Longest wait between attempts once the server has been unreachable a while.
const Duration kResumeMaxDelay = Duration(seconds: 60);

/// Linear 1.5 s steps (1.5, 3, 4.5 ...) capped at [kResumeMaxDelay].
Duration defaultResumeDelay(int attempt) {
  final ms = 1500 * (attempt + 1);
  final cap = kResumeMaxDelay.inMilliseconds;
  return Duration(milliseconds: ms > cap ? cap : ms);
}

enum ResumeOutcome {
  /// The token validated; [SessionResume.cameras] is set.
  resumed,

  /// The server rejected the token (401/403): the stored session is dead.
  rejected,

  /// [isActive] went false (unmounted, or the operator chose to sign in as
  /// someone else); the stored session is left untouched.
  abandoned,
}

class SessionResume {
  const SessionResume(this.outcome, [this.cameras]);
  final ResumeOutcome outcome;
  final List<Camera>? cameras;
}

/// Validate [session] by fetching the camera list, retrying until it either
/// succeeds or is rejected. [onWaiting] fires once, with the attempt count,
/// after [quickAttempts] consecutive unreachable results.
Future<SessionResume> resumeStoredSession({
  required Session session,
  required Future<List<Camera>> Function(Session) fetchCameras,
  required bool Function() isActive,
  void Function(int attempts)? onWaiting,
  int quickAttempts = kResumeQuickAttempts,
  Duration Function(int attempt) delay = defaultResumeDelay,
}) async {
  var announced = false;
  for (var attempt = 0; ; attempt++) {
    if (!isActive()) return const SessionResume(ResumeOutcome.abandoned);
    try {
      final cameras = await fetchCameras(session);
      if (!isActive()) return const SessionResume(ResumeOutcome.abandoned);
      return SessionResume(ResumeOutcome.resumed, cameras);
    } on CrumbApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        return const SessionResume(ResumeOutcome.rejected);
      }
      // 5xx and anything else: the server is up but not ready. Transient.
    } catch (_) {
      // Network error, DNS failure, timeout, bad payload: transient.
    }
    if (!isActive()) return const SessionResume(ResumeOutcome.abandoned);
    if (!announced && attempt + 1 >= quickAttempts) {
      announced = true;
      onWaiting?.call(attempt + 1);
    }
    await Future<void>.delayed(delay(attempt));
  }
}
