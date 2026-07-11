// Per-camera live-stream quality preference (main vs. sub) + the "which URL
// should this pane actually play" resolution logic.
//
// Ported from app.js:80-117 (`streamPref`, `wallDefaultStream`,
// `getStreamPref`, `setStreamPref`, `liveStreamUrl`, `mainUnavailable`).
//
// Persistence: the old client used localStorage. This port persists through
// `SharedPreferences` (see integration notes — `shared_preferences` needs to
// be added to pubspec.yaml; until then this degrades gracefully to an
// in-memory-only preference for the running session).

import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:crumb_desktop/api/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum StreamQuality { main, sub }

const String _kStreamPrefKey = 'crumb_stream_pref';
const String _kWallDefaultSubKey = 'crumb_live_wall_sub';

/// Holds per-camera stream-quality overrides and the wall-wide default
/// (mirrors `options.liveWallSub`). Also tracks, per session, which cameras'
/// MAIN stream failed to produce a frame on maximize (app.js's
/// `mainUnavailable` set) so a maximized tile falls back to SUB instead of
/// going black.
class StreamPrefsStore {
  StreamPrefsStore._(this._prefs, this._wallDefaultSub, this._overrides);

  final SharedPreferences? _prefs;
  bool _wallDefaultSub;
  final Map<String, StreamQuality> _overrides;

  /// camIds whose MAIN stream failed to produce a frame when maximized this
  /// session. Cleared implicitly on app restart (never persisted) so a fixed
  /// main stream is retried next launch.
  final Set<String> mainUnavailable = <String>{};

  static Future<StreamPrefsStore> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // package not wired up yet — fall back to in-memory only
    }
    final wallSub = prefs?.getBool(_kWallDefaultSubKey) ?? true;
    final overrides = <String, StreamQuality>{};
    final raw = prefs?.getString(_kStreamPrefKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in j.entries) {
          if (entry.value == 'sub') {
            overrides[entry.key] = StreamQuality.sub;
          } else if (entry.value == 'main') {
            overrides[entry.key] = StreamQuality.main;
          }
        }
      } catch (_) {
        /* corrupt/legacy value — start clean */
      }
    }
    return StreamPrefsStore._(prefs, wallSub, overrides);
  }

  /// The DEFAULT wall stream when a camera has no explicit override — sub
  /// when "wall uses sub" is on (bandwidth-friendly default), else main.
  StreamQuality get wallDefault =>
      _wallDefaultSub ? StreamQuality.sub : StreamQuality.main;

  set wallUsesSub(bool v) {
    _wallDefaultSub = v;
    unawaited(_prefs?.setBool(_kWallDefaultSubKey, v));
  }

  bool get wallUsesSub => _wallDefaultSub;

  /// The EFFECTIVE wall stream for a camera: explicit override, else the
  /// wall default. (app.js `getStreamPref`.)
  StreamQuality effectiveFor(String cameraId) =>
      _overrides[cameraId] ?? wallDefault;

  /// Set (or clear, by passing null) an explicit per-camera override.
  /// (app.js `setStreamPref`.)
  void setOverride(String cameraId, StreamQuality? quality) {
    if (quality == null) {
      _overrides.remove(cameraId);
    } else {
      _overrides[cameraId] = quality;
    }
    unawaited(_persistOverrides());
  }

  Future<void> _persistOverrides() async {
    if (_prefs == null) return;
    final j = {
      for (final e in _overrides.entries)
        e.key: e.value == StreamQuality.sub ? 'sub' : 'main',
    };
    await _prefs.setString(_kStreamPrefKey, jsonEncode(j));
  }

  /// The URL to actually play for a camera pane. `isMaximized` forces MAIN
  /// (full quality) unless this camera's main is known-dead this session, in
  /// which case it falls back to sub rather than showing black.
  /// (app.js `liveStreamUrl`.)
  String? liveStreamUrl(
    String cameraId,
    StreamUrls streams, {
    required bool isMaximized,
    bool maximizeUsesMain = true,
  }) {
    if (isMaximized && maximizeUsesMain) {
      if (mainUnavailable.contains(cameraId)) {
        return streams.rtspSub ?? streams.rtspMain;
      }
      return streams.rtspMain ?? streams.rtspSub;
    }
    return effectiveFor(cameraId) == StreamQuality.sub
        ? (streams.rtspSub ?? streams.rtspMain)
        : (streams.rtspMain ?? streams.rtspSub);
  }

  /// Record that maximizing this camera's main stream produced no frame, so
  /// subsequent maximizes fall back to sub. Call `clearMainUnavailable` after
  /// a stream refetch (e.g. server-side config change) to retry main.
  void markMainUnavailable(String cameraId) => mainUnavailable.add(cameraId);

  void clearMainUnavailable(String cameraId) =>
      mainUnavailable.remove(cameraId);
}
