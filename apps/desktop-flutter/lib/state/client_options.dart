// Persisted client-side preferences bag: the old Tauri client's Options
// dialog (apps/desktop/src/app.js — LS_OPTIONS_KEY `crumb_options`, a single
// JSON blob written by `saveOptions()`/read by `loadOptions()`, reflected
// into the dialog by `srvReflectClientOptions()`/`optOpen()` around
// app.js:11025 / app.js:1671).
//
// This port keeps the same *semantics* (defaults, value sets) but persists
// each field as its own `shared_preferences` key rather than one JSON blob —
// matching the pattern already established by
// `lib/ui/fullscreen/launch_fullscreen_prefs.dart` and
// `lib/state/stream_prefs.dart`, which each grew their own keys ahead of this
// consolidation. Two fields already have a home and are intentionally NOT
// duplicated here — read/write them through their existing owners:
///
///  * `liveWallSub`     -> `StreamPrefsStore.wallUsesSub` (lib/state/stream_prefs.dart)
///  * `launchFullscreen` -> `LaunchFullscreenPrefs` (lib/ui/fullscreen/launch_fullscreen_prefs.dart)
//
// Everything else the old Options dialog exposed lives here: showInfoBar,
// showAllCamerasView, hotkeysEnabled, maximizeMain, ptzClickMode, ptzStyle,
// ptzWheelCorner. (zoomClipsToMotion / clipsDensity are a different feature's
// options and are out of scope for this port.)
//
// Like every other client-only pref store in this app, a missing/broken
// `shared_preferences` platform channel degrades gracefully to in-memory-only
// for the running session rather than throwing.

import 'dart:async' show unawaited;

import 'package:shared_preferences/shared_preferences.dart';

/// What a click on a live/maximized PTZ-capable tile does.
/// Mirrors `options.ptzClickMode` ('center' | 'pan' | 'off').
enum PtzClickMode {
  /// Click-to-center: click a point in frame, camera centers on it.
  center,

  /// Click-and-hold pans/tilts continuously toward the cursor.
  pan,

  /// PTZ click handling is disabled entirely (arrows/wheel overlay still
  /// shown if the camera has PTZ, but clicking the video does nothing).
  off;

  static PtzClickMode fromWire(String? v) => switch (v) {
    'pan' => PtzClickMode.pan,
    'off' => PtzClickMode.off,
    _ => PtzClickMode.center,
  };

  String get wire => switch (this) {
    PtzClickMode.center => 'center',
    PtzClickMode.pan => 'pan',
    PtzClickMode.off => 'off',
  };
}

/// The on-video PTZ control affordance. Mirrors `options.ptzStyle`
/// ('edges' | 'wheel').
enum PtzStyle {
  /// Directional hit-zones along the video edges (default).
  edges,

  /// A compact corner-pinned wheel + zoom/presets pill.
  wheel;

  static PtzStyle fromWire(String? v) =>
      v == 'wheel' ? PtzStyle.wheel : PtzStyle.edges;

  String get wire => this == PtzStyle.wheel ? 'wheel' : 'edges';
}

/// Which corner the PTZ wheel overlay is pinned to when [PtzStyle.wheel] is
/// active. Mirrors `options.ptzWheelCorner`.
enum PtzWheelCorner {
  bottomLeft,
  bottomRight,
  topLeft,
  topRight;

  static PtzWheelCorner fromWire(String? v) => switch (v) {
    'bottom-right' => PtzWheelCorner.bottomRight,
    'top-left' => PtzWheelCorner.topLeft,
    'top-right' => PtzWheelCorner.topRight,
    _ => PtzWheelCorner.bottomLeft,
  };

  String get wire => switch (this) {
    PtzWheelCorner.bottomLeft => 'bottom-left',
    PtzWheelCorner.bottomRight => 'bottom-right',
    PtzWheelCorner.topLeft => 'top-left',
    PtzWheelCorner.topRight => 'top-right',
  };

  bool get isLeft => this == PtzWheelCorner.bottomLeft || this == PtzWheelCorner.topLeft;
  bool get isTop => this == PtzWheelCorner.topLeft || this == PtzWheelCorner.topRight;
}

const String _kShowInfoBar = 'crumb.showInfoBar';
const String _kShowAllCamerasView = 'crumb.showAllCamerasView';
const String _kHotkeysEnabled = 'crumb.hotkeysEnabled';
const String _kMaximizeMain = 'crumb.maximizeMain';
const String _kPtzClickMode = 'crumb.ptzClickMode';
const String _kPtzStyle = 'crumb.ptzStyle';
const String _kPtzWheelCorner = 'crumb.ptzWheelCorner';

/// Loads/holds/persists the client options this file owns. Construct once
/// (e.g. in `CrumbClientApp` state) via [ClientOptionsStore.load] and pass
/// the instance down; callers mutate through the setters, which persist
/// best-effort and update the in-memory value synchronously so widgets can
/// read the new value immediately after calling a setter.
class ClientOptionsStore {
  ClientOptionsStore._(
    this._prefs, {
    required bool showInfoBar,
    required bool showAllCamerasView,
    required bool hotkeysEnabled,
    required bool maximizeMain,
    required PtzClickMode ptzClickMode,
    required PtzStyle ptzStyle,
    required PtzWheelCorner ptzWheelCorner,
  }) : _showInfoBar = showInfoBar,
       _showAllCamerasView = showAllCamerasView,
       _hotkeysEnabled = hotkeysEnabled,
       _maximizeMain = maximizeMain,
       _ptzClickMode = ptzClickMode,
       _ptzStyle = ptzStyle,
       _ptzWheelCorner = ptzWheelCorner;

  final SharedPreferences? _prefs;

  bool _showInfoBar;
  bool _showAllCamerasView;
  bool _hotkeysEnabled;
  bool _maximizeMain;
  PtzClickMode _ptzClickMode;
  PtzStyle _ptzStyle;
  PtzWheelCorner _ptzWheelCorner;

  static Future<ClientOptionsStore> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // package not wired up yet — in-memory only, per-session
    }
    return ClientOptionsStore._(
      prefs,
      showInfoBar: prefs?.getBool(_kShowInfoBar) ?? true,
      showAllCamerasView: prefs?.getBool(_kShowAllCamerasView) ?? true,
      hotkeysEnabled: prefs?.getBool(_kHotkeysEnabled) ?? true,
      maximizeMain: prefs?.getBool(_kMaximizeMain) ?? true,
      ptzClickMode: PtzClickMode.fromWire(prefs?.getString(_kPtzClickMode)),
      ptzStyle: PtzStyle.fromWire(prefs?.getString(_kPtzStyle)),
      ptzWheelCorner: PtzWheelCorner.fromWire(
        prefs?.getString(_kPtzWheelCorner),
      ),
    );
  }

  // ── show the per-tile title strip (name + REC/motion indicators) ──
  bool get showInfoBar => _showInfoBar;
  set showInfoBar(bool v) {
    _showInfoBar = v;
    unawaited(_prefs?.setBool(_kShowInfoBar, v));
  }

  // ── auto-build the "All Cameras" quick-grid view on login/wall-empty ──
  bool get showAllCamerasView => _showAllCamerasView;
  set showAllCamerasView(bool v) {
    _showAllCamerasView = v;
    unawaited(_prefs?.setBool(_kShowAllCamerasView, v));
  }

  // ── global keyboard-shortcut handling on/off ──
  bool get hotkeysEnabled => _hotkeysEnabled;
  set hotkeysEnabled(bool v) {
    _hotkeysEnabled = v;
    unawaited(_prefs?.setBool(_kHotkeysEnabled, v));
  }

  // ── maximizing a tile plays its MAIN stream instead of the wall's
  //    current quality (app.js `liveStreamUrl` / `options.maximizeMain`) ──
  bool get maximizeMain => _maximizeMain;
  set maximizeMain(bool v) {
    _maximizeMain = v;
    unawaited(_prefs?.setBool(_kMaximizeMain, v));
  }

  PtzClickMode get ptzClickMode => _ptzClickMode;
  set ptzClickMode(PtzClickMode v) {
    _ptzClickMode = v;
    unawaited(_prefs?.setString(_kPtzClickMode, v.wire));
  }

  PtzStyle get ptzStyle => _ptzStyle;
  set ptzStyle(PtzStyle v) {
    _ptzStyle = v;
    unawaited(_prefs?.setString(_kPtzStyle, v.wire));
  }

  PtzWheelCorner get ptzWheelCorner => _ptzWheelCorner;
  set ptzWheelCorner(PtzWheelCorner v) {
    _ptzWheelCorner = v;
    unawaited(_prefs?.setString(_kPtzWheelCorner, v.wire));
  }
}
