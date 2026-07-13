// Resilient startup: if the initial post-login/post-restore load of
// `/auth/me` + `/cameras` fails, show a visible "server unreachable —
// retrying" screen with a countdown + manual retry, instead of dumping the
// user back to the login screen and losing their (still-valid, just
// currently unreachable) session.
//
// Port of the old Tauri client's boot-retry logic (apps/desktop/src/app.js:
// `showBootRetry`, `bootRetryStop`, `loadCamerasAndStart` around line 3890).
// Same capped-exponential-backoff schedule (2s, 4s, 8s, 16s, 30s, 30s, ...),
// same "manual retry resets the backoff" behavior, same distinction between
// "server unreachable — keep retrying" and "401 — the token itself is dead,
// stop looping and hand back to auth" that the old client made between a
// network failure and `err.isForbidden`.
//
// This screen owns NO session state — it is handed the existing [Session]
// (however it was obtained: fresh login or a restored saved session) and
// never discards it. On success it hands the loaded profile + camera list
// back to the caller via [onReady] so the caller can build the wall. It
// never calls sign-out itself; [onSignOut] is an optional escape hatch for
// hosts that want one available from this screen too.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/boot_api.dart';
import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

enum _BootPhase {
  /// A load attempt (initial or manual retry) is in flight.
  loading,

  /// The last attempt failed with a retryable error (network/5xx/timeout);
  /// counting down to the next automatic attempt.
  retrying,

  /// The last attempt failed with 403 — the account is authenticated but not
  /// permitted to see the camera list. Not auto-retried (retrying can't fix a
  /// permissions problem); the user can still retry manually in case an
  /// admin just granted access, or sign out.
  forbidden,
}

class BootRetryScreen extends StatefulWidget {
  const BootRetryScreen({
    super.key,
    required this.api,
    required this.session,
    required this.onReady,
    this.onUnauthorized,
    this.onSignOut,
  });

  final CrumbApi api;
  final Session session;

  /// Called once `/auth/me` and `/cameras` have both succeeded. The caller
  /// should swap this screen out for the wall.
  final void Function(MeResponse me, List<Camera> cameras) onReady;

  /// Called when the server rejects the token outright (401) — the session
  /// is dead, not just unreachable, so looping here would never succeed.
  /// Typically wired to the same re-auth flow as a mid-session 401 (see
  /// `SessionController.handleUnauthorized`). If left null, a 401 is treated
  /// like any other failure and retried (which will just keep 401ing, but at
  /// least stays visible rather than crashing).
  final VoidCallback? onUnauthorized;

  /// Optional "sign out" escape hatch shown alongside the retry control.
  final VoidCallback? onSignOut;

  @override
  State<BootRetryScreen> createState() => _BootRetryScreenState();
}

class _BootRetryScreenState extends State<BootRetryScreen> {
  // Same schedule as the old client's BOOT_RETRY_BASE_MS / BOOT_RETRY_MAX_MS.
  static const _baseDelay = Duration(seconds: 2);
  static const _maxDelay = Duration(seconds: 30);

  _BootPhase _phase = _BootPhase.loading;
  String? _message;
  int _attempt = 0;
  Duration _nextDelay = Duration.zero;
  int _secondsRemaining = 0;

  Timer? _retryTimer;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  Future<void> _load() async {
    _cancelTimers();
    setState(() {
      _phase = _BootPhase.loading;
      _message = null;
    });
    try {
      // Fetch /auth/me before /cameras — mirrors the old client's
      // fetchAndApplyMe-before-apiFetchCameras ordering, so capability
      // gating is resolved before the caller builds any camera UI.
      final me = await widget.api.fetchMe(widget.session);
      final cameras = await widget.api.listCameras(widget.session);
      if (!mounted) return;
      _cancelTimers();
      _attempt = 0; // this attempt succeeded — reset for any future boot
      widget.onReady(me, cameras);
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401) {
        if (widget.onUnauthorized != null) {
          widget.onUnauthorized!();
          return;
        }
        _scheduleRetry('Session expired.');
      } else if (e.statusCode == 403) {
        setState(() {
          _phase = _BootPhase.forbidden;
          _message = 'Access denied — this account can no longer see the '
              'camera list.';
        });
      } else {
        _scheduleRetry(e.message);
      }
    } catch (e) {
      if (!mounted) return;
      _scheduleRetry('Could not reach the server.');
    }
  }

  void _scheduleRetry(String reason) {
    _attempt++;
    final delayMs = math.min(
      _maxDelay.inMilliseconds,
      _baseDelay.inMilliseconds * math.pow(2, _attempt - 1).toInt(),
    );
    _nextDelay = Duration(milliseconds: delayMs);
    setState(() {
      _phase = _BootPhase.retrying;
      _message = '$reason — retrying…';
      _secondsRemaining = (_nextDelay.inMilliseconds / 1000).ceil();
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _secondsRemaining = _secondsRemaining > 0 ? _secondsRemaining - 1 : 0;
      });
    });
    _retryTimer = Timer(_nextDelay, _load);
  }

  /// "Retry now" — mirrors the old client's boot-retry-btn handler:
  /// `bootRetryStop()` (cancel + reset backoff) then `loadCamerasAndStart()`
  /// immediately, rather than just fast-forwarding the existing countdown.
  void _retryNow() {
    _cancelTimers();
    _attempt = 0;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _phase == _BootPhase.forbidden
                      ? Icons.block
                      : Icons.cloud_off,
                  size: 40,
                  color: _phase == _BootPhase.forbidden
                      ? Colors.red.shade300
                      : Colors.amber,
                ),
                const SizedBox(height: 16),
                if (_phase == _BootPhase.loading) ...[
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Connecting…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                ] else ...[
                  Text(
                    _message ?? 'Server unreachable.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  if (_phase == _BootPhase.retrying) ...[
                    const SizedBox(height: 8),
                    Text(
                      _secondsRemaining > 0
                          ? 'Retrying in ${_secondsRemaining}s…'
                          : 'Retrying…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        onPressed: _retryNow,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text('Retry now'),
                        ),
                      ),
                      if (widget.onSignOut != null) ...[
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: widget.onSignOut,
                          child: const Text('Sign out'),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
