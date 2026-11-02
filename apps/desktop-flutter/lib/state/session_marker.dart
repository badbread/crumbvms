// Detects that the previous run of the client ended unexpectedly (#713).
//
// A GPU driver fault inside the video decoder kills the process and cannot be
// caught in-process, so instead a small "session running" marker is written at
// startup and cleared on a clean window close. If the marker is still set at
// the next launch, the last run did not exit cleanly. Starting a session reads
// and re-arms the marker in one step, so the notice is raised once per
// unexpected exit and never repeats on later launches.
//
// Like the other client-only pref stores, a missing `shared_preferences`
// platform channel degrades to "no unexpected exit detected".

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const String _kSessionRunning = 'crumb.sessionRunning';

class SessionMarker with WindowListener {
  SessionMarker._();
  static final SessionMarker instance = SessionMarker._();

  /// True when this launch found the marker left over from a previous run.
  /// Set by [begin]; the UI resets it when the notice is dismissed or acted on.
  final ValueNotifier<bool> previousExitUnexpected = ValueNotifier<bool>(false);

  SharedPreferences? _prefs;

  /// Call once at startup. Reads the leftover marker, then sets it for this run.
  Future<void> begin() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      previousExitUnexpected.value = await beginSession(_prefs!);
    } catch (_) {
      /* best-effort: no prefs means no detection */
    }
  }

  /// Clear the marker when the user closes the window. Holds the close just
  /// long enough to let the write land, then destroys the window.
  Future<void> attachCloseHandler() async {
    try {
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
    } catch (_) {
      /* best-effort: without it the marker is simply never cleared */
    }
  }

  @override
  void onWindowClose() {
    () async {
      await end();
      await windowManager.destroy();
    }();
  }

  /// Call on a clean shutdown. Best-effort and bounded so it can never hold
  /// the window open.
  Future<void> end() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await endSession(prefs).timeout(const Duration(seconds: 1));
    } catch (_) {
      /* best-effort */
    }
  }
}

/// Pure marker logic. Returns true if the previous session did not end
/// cleanly, and marks this session as running.
@visibleForTesting
Future<bool> beginSession(SharedPreferences prefs) async {
  final unexpected = prefs.getBool(_kSessionRunning) ?? false;
  await prefs.setBool(_kSessionRunning, true);
  return unexpected;
}

/// Clears the marker: this session ended cleanly.
@visibleForTesting
Future<void> endSession(SharedPreferences prefs) async {
  await prefs.setBool(_kSessionRunning, false);
}

/// Whether to show the "closed unexpectedly" notice: only when hardware
/// decoding is still on (otherwise there is nothing for the button to turn off).
bool shouldShowUnexpectedExitNotice({
  required bool previousExitUnexpected,
  required bool hardwareDecoding,
}) => previousExitUnexpected && hardwareDecoding;
