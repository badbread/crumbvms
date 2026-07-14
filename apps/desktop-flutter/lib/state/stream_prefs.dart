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

/// Live-stream quality tier for a pane. `main` = full-res, `sub` = the
/// low-bandwidth sub stream, `dataSaver` = the on-demand low-bitrate
/// `<name>_mobile` go2rtc transcode ([StreamUrls.rtspMobile]).
enum StreamQuality { main, sub, dataSaver }

/// Wire form persisted to SharedPreferences / the overrides blob. `dataSaver`
/// serializes as `'mobile'` (it plays the `_mobile` stream). Kept as a plain
/// switch (not a const map) to sidestep Dart const-map pitfalls.
String _qualityToWire(StreamQuality q) {
  switch (q) {
    case StreamQuality.main:
      return 'main';
    case StreamQuality.sub:
      return 'sub';
    case StreamQuality.dataSaver:
      return 'mobile';
  }
}

/// Parse a persisted quality tier; unknown/legacy values return null so the
/// caller can fall back (to main, the safe full-quality default).
StreamQuality? _qualityFromWire(String? s) {
  switch (s) {
    case 'main':
      return StreamQuality.main;
    case 'sub':
      return StreamQuality.sub;
    case 'mobile':
      return StreamQuality.dataSaver;
    default:
      return null;
  }
}

const String _kStreamPrefKey = 'crumb_stream_pref';
// Legacy bool key ("wall uses sub") — read once on load and migrated into the
// string quality key below, then never written again.
const String _kWallDefaultSubKey = 'crumb_live_wall_sub';
const String _kWallDefaultQualityKey = 'crumb_live_wall_quality';
const String _kPtzDisabledKey = 'crumb_ptz_disabled';

/// Holds per-camera stream-quality overrides and the wall-wide default
/// (mirrors `options.liveWallSub`). Also tracks, per session, which cameras'
/// MAIN stream failed to produce a frame on maximize (app.js's
/// `mainUnavailable` set) so a maximized tile falls back to SUB instead of
/// going black.
class StreamPrefsStore {
  StreamPrefsStore._(
    this._prefs,
    this._wallDefault,
    this._overrides,
    this._ptzDisabled,
  );

  final SharedPreferences? _prefs;
  StreamQuality _wallDefault;
  final Map<String, StreamQuality> _overrides;

  /// Camera ids the operator has hidden PTZ controls for (per-camera, client
  /// side). Some PTZ-capable cameras don't move well / shouldn't be driven.
  final Set<String> _ptzDisabled;

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
    // Wall default: prefer the new string quality key; else migrate the legacy
    // bool key ("wall uses sub": true→sub) so existing installs keep their
    // choice; else the historical default (sub, bandwidth-friendly).
    StreamQuality wallDefault;
    final rawQ = prefs?.getString(_kWallDefaultQualityKey);
    if (rawQ != null) {
      wallDefault = _qualityFromWire(rawQ) ?? StreamQuality.sub;
    } else {
      final legacySub = prefs?.getBool(_kWallDefaultSubKey);
      wallDefault = (legacySub ?? true)
          ? StreamQuality.sub
          : StreamQuality.main;
    }
    final overrides = <String, StreamQuality>{};
    final raw = prefs?.getString(_kStreamPrefKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in j.entries) {
          final q = _qualityFromWire(entry.value as String?);
          if (q != null) overrides[entry.key] = q;
        }
      } catch (_) {
        /* corrupt/legacy value — start clean */
      }
    }
    final ptzDisabled = <String>{};
    final rawPtz = prefs?.getStringList(_kPtzDisabledKey);
    if (rawPtz != null) ptzDisabled.addAll(rawPtz);
    return StreamPrefsStore._(prefs, wallDefault, overrides, ptzDisabled);
  }

  /// The DEFAULT stream tier for a camera with no explicit override.
  StreamQuality get wallDefault => _wallDefault;

  /// The wall-wide default tier (Main / Sub / Data saver). Persisted as a
  /// string under [_kWallDefaultQualityKey]; the legacy bool key is left in
  /// place but never written again.
  StreamQuality get wallDefaultQuality => _wallDefault;

  set wallDefaultQuality(StreamQuality q) {
    _wallDefault = q;
    unawaited(_prefs?.setString(_kWallDefaultQualityKey, _qualityToWire(q)));
  }

  /// The EFFECTIVE wall stream for a camera: explicit override, else the
  /// wall default. (app.js `getStreamPref`.)
  StreamQuality effectiveFor(String cameraId) =>
      _overrides[cameraId] ?? wallDefault;

  /// Whether this camera has an explicit per-camera stream override (vs. just
  /// following the wall default).
  bool hasOverride(String cameraId) => _overrides.containsKey(cameraId);

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

  /// Clear ALL per-camera stream overrides — every camera falls back to the
  /// wall default. Backs the "reset" action next to the substream setting.
  void clearAllOverrides() {
    _overrides.clear();
    unawaited(_persistOverrides());
  }

  bool get hasAnyOverride => _overrides.isNotEmpty;

  // ── Per-camera PTZ-controls-disabled ──────────────────────────────────────
  bool ptzDisabledFor(String cameraId) => _ptzDisabled.contains(cameraId);

  void setPtzDisabled(String cameraId, bool disabled) {
    if (disabled) {
      _ptzDisabled.add(cameraId);
    } else {
      _ptzDisabled.remove(cameraId);
    }
    unawaited(_prefs?.setStringList(_kPtzDisabledKey, _ptzDisabled.toList()));
  }

  Future<void> _persistOverrides() async {
    if (_prefs == null) return;
    final j = {
      for (final e in _overrides.entries) e.key: _qualityToWire(e.value),
    };
    await _prefs.setString(_kStreamPrefKey, jsonEncode(j));
  }

  /// The quality tier a pane will ACTUALLY play, given which URLs the server
  /// returned — the effective choice, downgraded when its preferred stream is
  /// missing (Data saver → sub → main; sub → main). `isMaximized` forces MAIN
  /// (full quality) unless this camera's main is known-dead this session, in
  /// which case it downgrades to sub. [liveStreamUrl] is defined in terms of
  /// this, so the tile badge never disagrees with the pixels on screen.
  StreamQuality resolvedQuality(
    String cameraId,
    StreamUrls streams, {
    required bool isMaximized,
    bool maximizeUsesMain = true,
  }) {
    if (isMaximized && maximizeUsesMain) {
      if (mainUnavailable.contains(cameraId) && streams.rtspSub != null) {
        return StreamQuality.sub;
      }
      return streams.rtspMain != null
          ? StreamQuality.main
          : (streams.rtspSub != null ? StreamQuality.sub : StreamQuality.main);
    }
    switch (effectiveFor(cameraId)) {
      case StreamQuality.dataSaver:
        if (streams.rtspMobile != null) return StreamQuality.dataSaver;
        if (streams.rtspSub != null) return StreamQuality.sub;
        return StreamQuality.main;
      case StreamQuality.sub:
        return streams.rtspSub != null ? StreamQuality.sub : StreamQuality.main;
      case StreamQuality.main:
        return streams.rtspMain != null
            ? StreamQuality.main
            : (streams.rtspSub != null
                  ? StreamQuality.sub
                  : StreamQuality.main);
    }
  }

  /// The URL for a given resolved tier, with a final safety fallback so a pane
  /// never gets a null URL when any stream exists.
  String? _urlForQuality(StreamQuality q, StreamUrls streams) {
    switch (q) {
      case StreamQuality.dataSaver:
        return streams.rtspMobile ?? streams.rtspSub ?? streams.rtspMain;
      case StreamQuality.sub:
        return streams.rtspSub ?? streams.rtspMain ?? streams.rtspMobile;
      case StreamQuality.main:
        return streams.rtspMain ?? streams.rtspSub ?? streams.rtspMobile;
    }
  }

  /// The URL to actually play for a camera pane. `isMaximized` forces MAIN
  /// (full quality) unless this camera's main is known-dead this session, in
  /// which case it falls back to sub rather than showing black. Data saver
  /// falls back to sub → main when [StreamUrls.rtspMobile] is null (a
  /// Frigate-served camera, or mobile streams disabled server-side).
  /// (app.js `liveStreamUrl`, extended for the Data-saver tier.)
  String? liveStreamUrl(
    String cameraId,
    StreamUrls streams, {
    required bool isMaximized,
    bool maximizeUsesMain = true,
  }) {
    final q = resolvedQuality(
      cameraId,
      streams,
      isMaximized: isMaximized,
      maximizeUsesMain: maximizeUsesMain,
    );
    return _urlForQuality(q, streams);
  }

  /// Record that maximizing this camera's main stream produced no frame, so
  /// subsequent maximizes fall back to sub. Call `clearMainUnavailable` after
  /// a stream refetch (e.g. server-side config change) to retry main.
  void markMainUnavailable(String cameraId) => mainUnavailable.add(cameraId);

  void clearMainUnavailable(String cameraId) =>
      mainUnavailable.remove(cameraId);
}
