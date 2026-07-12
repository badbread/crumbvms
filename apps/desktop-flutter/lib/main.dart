// P0 de-risk spike — prove the three unproven-together pieces on ONE pane:
//   1. media_kit renders ONE live camera (mpv → Flutter external texture),
//   2. flutter_rust_bridge calls the real Windows-native Rust core (host_stats),
//   3. a NATIVE Flutter overlay composites over the video texture with real
//      hit-testing (the exact thing the Tauri Win32-airspace model made janky).
//
// If any of these feels janky on real hardware, STOP and flag it — that is the
// spike's whole job (revisit trigger in the rewrite decision).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:window_manager/window_manager.dart';

import 'package:crumb_desktop/api/clips_api.dart' show ClipDescriptor;
import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/media_token_cache.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/views_api.dart';
import 'package:crumb_desktop/services/audio_follow_controller.dart';
import 'package:crumb_desktop/services/snapshot_service.dart';
import 'package:crumb_desktop/perf_grid.dart';
import 'package:crumb_desktop/session/session_controller.dart';
import 'package:crumb_desktop/src/rust/api/host.dart';
import 'package:crumb_desktop/src/rust/api/secret.dart';
import 'package:crumb_desktop/src/rust/frb_generated.dart';
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/state/stream_prefs.dart';
import 'package:crumb_desktop/ui/admin_console/admin_console_screen.dart';
import 'package:crumb_desktop/ui/bookmarks/bookmarks_screen.dart';
import 'package:crumb_desktop/ui/clips/clips_screen.dart';
import 'package:crumb_desktop/ui/export/export_builder_dialog.dart'
    show ExportClipDraft;
import 'package:crumb_desktop/ui/export/export_screen.dart';
import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/fullscreen/launch_fullscreen_option.dart';
import 'package:crumb_desktop/ui/hints/shift_hints.dart';
import 'package:crumb_desktop/ui/login_screen.dart';
import 'package:crumb_desktop/ui/motion_tuner/motion_tuner_screen.dart';
import 'package:crumb_desktop/ui/motion_timeline/motion_timeline_controller.dart';
import 'package:crumb_desktop/ui/motion_timeline/playback_legend_bar.dart';
import 'package:crumb_desktop/ui/notifications/status_bar.dart';
import 'package:crumb_desktop/ui/notifications/status_bar_controller.dart';
import 'package:crumb_desktop/ui/playback/playback_screen.dart';
import 'package:crumb_desktop/ui/reauth/reauth_overlay.dart';
import 'package:crumb_desktop/ui/recording_alerts/recording_alert_banner.dart';
import 'package:crumb_desktop/ui/recording_alerts/recording_alerts_controller.dart';
import 'package:crumb_desktop/ui/saved_views/layout_editor_screen.dart';
import 'package:crumb_desktop/ui/saved_views/saved_views_screen.dart';
import 'package:crumb_desktop/ui/saved_views/view_prefs.dart';
import 'package:crumb_desktop/ui/saved_views/view_selector_bar.dart';
import 'package:crumb_desktop/ui/settings/settings_window.dart';
import 'package:crumb_desktop/ui/snapshot/snapshot_hotkey.dart';
import 'package:crumb_desktop/ui/updates/update_banner.dart';
import 'package:crumb_desktop/ui/updates/update_check_controller.dart';
import 'package:crumb_desktop/ui/wall_screen.dart';

/// Run modes (default = the real client: login then live wall):
///   `--dart-define=GRID=N`  -> N-up media_kit perf harness (perf_grid.dart)
///   `--dart-define=SPIKE=1` -> the single-pane P0 spike (LivePane)
const int kGrid = int.fromEnvironment('GRID', defaultValue: 0);
const bool kSpike = bool.fromEnvironment('SPIKE', defaultValue: false);

/// The camera/stream to render. Injected at build/run time so no site-specific
/// address lands in the repo:
/// `flutter run --dart-define=STREAM_URL=rtsp://HOST:PORT/CAMERA`.
/// The committed default is a generic libmpv lavfi test pattern so the app is
/// runnable standalone; the real proof points STREAM_URL at a go2rtc restream.
const String kStreamUrl = String.fromEnvironment(
  'STREAM_URL',
  defaultValue: 'av://lavfi:testsrc=size=1280x720:rate=30',
);

/// A denser, desktop-grade dark theme. Material's defaults are tuned for touch
/// (large tap targets, big type, chunky switches) which read as "mobile" on a
/// desktop VMS; this compacts control density and type for a professional look.
ThemeData _desktopTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textTheme: base.textTheme.apply(fontSizeFactor: 0.9),
    listTileTheme: base.listTileTheme.copyWith(
      dense: true,
      minVerticalPadding: 4,
    ),
    // Slimmer switches — the M3 default reads as a phone toggle on desktop.
    switchTheme: SwitchThemeData(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? base.colorScheme.primary : null,
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit native surface + libmpv init.
  MediaKit.ensureInitialized();
  // flutter_rust_bridge — loads the cargokit-built rust_lib_crumb_desktop dylib.
  await RustLib.init();
  // window_manager — required before any fullscreen calls (fullscreen wall +
  // launch-into-fullscreen preference).
  await windowManager.ensureInitialized();
  runApp(
    kGrid > 0
        ? PerfGridApp(count: kGrid, url: kStreamUrl)
        : kSpike
        ? const SpikeApp()
        : const CrumbClientApp(),
  );
}

/// The real desktop client: login → live wall. Restores a DPAPI-persisted
/// session on launch (so the user isn't asked to log in every time) and swaps
/// between the login and wall screens.
class CrumbClientApp extends StatefulWidget {
  const CrumbClientApp({super.key});

  @override
  State<CrumbClientApp> createState() => _CrumbClientAppState();
}

class _CrumbClientAppState extends State<CrumbClientApp> {
  final CrumbApi _api = CrumbApi();
  Session? _session;
  List<Camera> _cameras = const [];
  bool _restoring = true; // trying a saved session on launch

  // ── Session-scoped plumbing (created on login, torn down on logout) ──
  SessionController? _sessionController;
  MediaTokenCache? _mediaTokens;
  RecordingAlertsController? _recordingAlerts;
  UpdateCheckController? _updateCheck;

  // ── App-scoped controllers/stores ──
  final FullscreenController _fullscreen = FullscreenController();
  final StatusBarController _statusBar = StatusBarController();
  ClientOptionsStore? _clientOptions;
  StreamPrefsStore? _streamPrefs;
  HotkeyConfigStore? _hotkeys;

  @override
  void initState() {
    super.initState();
    _fullscreen.attach();
    HardwareKeyboard.instance.addHandler(_hintsKeyHandler);
    _loadStores();
    _restore();
  }

  /// Drive the app-wide "hold Shift to see what buttons do" hint layer. Never
  /// consumes the event (returns false) so Shift still works everywhere; skips
  /// while typing so capitals don't flash the hints.
  bool _hintsKeyHandler(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight) {
      final down = event is KeyDownEvent || event is KeyRepeatEvent;
      final typing =
          FocusManager.instance.primaryFocus?.context?.widget is EditableText;
      HintsController.instance.active.value = down && !typing;
    }
    return false;
  }

  /// Load the shared_preferences-backed client stores (options, stream prefs,
  /// hotkey remaps). Session-independent, loaded once per process; each store
  /// degrades to in-memory-only if the plugin is unavailable.
  Future<void> _loadStores() async {
    final options = await ClientOptionsStore.load();
    final streamPrefs = await StreamPrefsStore.load();
    final hotkeys = await HotkeyConfigStore.load();
    if (mounted) {
      setState(() {
        _clientOptions = options;
        _streamPrefs = streamPrefs;
        _hotkeys = hotkeys;
      });
    }
  }

  /// Try to resume a DPAPI-persisted session so the user isn't asked to log in
  /// every launch. A stored token that no longer works (expired/revoked) is
  /// discarded and we fall back to the login screen.
  Future<void> _restore() async {
    try {
      final saved = await loadSession();
      if (saved != null) {
        final session = Session.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
        );
        final cameras = await _api.listCameras(session); // validates the token
        if (mounted) {
          setState(() {
            _startSession(session, cameras);
            _restoring = false;
          });
        }
        return;
      }
    } catch (_) {
      await clearSession(); // stale/invalid — start clean
    }
    if (mounted) setState(() => _restoring = false);
  }

  /// Stand up all session-scoped plumbing: 401 re-auth controller, scoped
  /// media-token cache, recording-health + update-check pollers, and the
  /// launch-into-fullscreen preference. Call inside setState.
  void _startSession(Session session, List<Camera> cameras) {
    final controller = SessionController(api: _api, initialSession: session);
    controller.addListener(_onSessionChanged);
    _sessionController = controller;
    _mediaTokens = MediaTokenCache(
      api: _api,
      session: session,
      onUnauthorized: controller.handleUnauthorized,
    );
    _recordingAlerts = RecordingAlertsController(api: _api, session: session)
      ..start();
    _updateCheck = UpdateCheckController(api: _api, session: session)..start();
    _session = session;
    _cameras = cameras;
    // Apply "launch into fullscreen wall" only after the initial camera load —
    // same ordering as the old client's applyLaunchPreferences().
    unawaited(applyLaunchFullscreenPreference(_fullscreen));
  }

  /// After a successful re-auth the fresh token must reach the media-token
  /// cache and the DPAPI-persisted session; the shell rebuilds with it.
  void _onSessionChanged() {
    final controller = _sessionController;
    if (controller == null) return;
    _mediaTokens?.updateSession(controller.session);
    if (controller.session.token != _session?.token) {
      _session = controller.session;
      unawaited(_persistSession(controller.session));
    }
    if (mounted) setState(() {});
  }

  Future<void> _persistSession(Session session) async {
    // Persist the session (DPAPI-encrypted, current-user-scoped) for next launch.
    try {
      await saveSession(data: jsonEncode(session.toJson()));
    } catch (_) {
      /* persistence is best-effort; the session still works */
    }
  }

  void _teardownSession() {
    _sessionController?.removeListener(_onSessionChanged);
    _sessionController = null;
    // A stale principal's scoped media tokens must never be reused by whoever
    // signs in next.
    _mediaTokens?.clear();
    _mediaTokens = null;
    _recordingAlerts?.stop();
    _recordingAlerts?.dispose();
    _recordingAlerts = null;
    _updateCheck?.stop();
    _updateCheck?.dispose();
    _updateCheck = null;
  }

  Future<void> _onLoggedIn(Session session, List<Camera> cameras) async {
    await _persistSession(session);
    if (mounted) {
      setState(() => _startSession(session, cameras));
    }
  }

  Future<void> _onLogout() async {
    try {
      await clearSession();
    } catch (_) {
      /* ignore */
    }
    _teardownSession();
    // Never strand the OS window in fullscreen at the login screen.
    unawaited(_fullscreen.setFullscreen(false));
    if (mounted) {
      setState(() {
        _session = null;
        _cameras = const [];
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_hintsKeyHandler);
    _teardownSession();
    _fullscreen.dispose();
    _statusBar.dispose();
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    final controller = _sessionController;
    final mediaTokens = _mediaTokens;
    if (_restoring) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (_session == null || controller == null || mediaTokens == null) {
      home = LoginScreen(api: _api, onLoggedIn: _onLoggedIn);
    } else {
      // The signed-in shell keeps running underneath the re-auth overlay on a
      // 401 (panes keep decoding); S-key snapshots work from any tab.
      home = SnapshotHotkey(
        child: ReauthOverlay(
          controller: controller,
          child: MainShell(
            api: _api,
            sessionController: controller,
            mediaTokens: mediaTokens,
            cameras: _cameras,
            onLogout: _onLogout,
            recordingAlerts: _recordingAlerts!,
            updateCheck: _updateCheck!,
            fullscreen: _fullscreen,
            statusBar: _statusBar,
            clientOptions: _clientOptions,
            streamPrefs: _streamPrefs,
            hotkeys: _hotkeys,
          ),
        ),
      );
    }
    return MaterialApp(
      title: 'Crumb',
      debugShowCheckedModeBanner: false,
      theme: _desktopTheme(),
      // Esc exits OS fullscreen before any inner Esc handling (maximize-exit
      // etc.) — same priority order as the old client.
      home: FullscreenEscHandler(controller: _fullscreen, child: home),
    );
  }
}

/// Post-login navigation shell: a desktop NavigationRail switching between the
/// ported feature surfaces. Only the SELECTED destination is built — the
/// video-heavy screens (live wall, managed wall, playback) must not all hold
/// decoding players at once, so switching tabs tears the previous screen down.
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.api,
    required this.sessionController,
    required this.mediaTokens,
    required this.cameras,
    required this.onLogout,
    required this.recordingAlerts,
    required this.updateCheck,
    required this.fullscreen,
    required this.statusBar,
    this.clientOptions,
    this.streamPrefs,
    this.hotkeys,
  });

  final CrumbApi api;
  final SessionController sessionController;
  final MediaTokenCache mediaTokens;
  final List<Camera> cameras;
  final VoidCallback onLogout;
  final RecordingAlertsController recordingAlerts;
  final UpdateCheckController updateCheck;
  final FullscreenController fullscreen;
  final StatusBarController statusBar;
  final ClientOptionsStore? clientOptions;
  final StreamPrefsStore? streamPrefs;
  final HotkeyConfigStore? hotkeys;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = _liveIndex;

  /// Whether the floating Settings panel is open. It overlays the current tab
  /// (not its own tab) so the live wall keeps running and updates behind it.
  bool _settingsOpen = false;

  /// The applied saved view (null → the default "All Cameras" auto-grid wall),
  /// and the id used to highlight the active chip in the view-selector row.
  AppliedView? _appliedView;
  String? _activeViewId = ViewPrefs.allCamerasId;

  /// Bumped to force the view-selector row to reload views (e.g. after the
  /// Config View editor creates one).
  int _viewsRefreshToken = 0;

  /// The export batch, owned HERE (the persistent shell) so it accumulates
  /// across Playback "Add clip to export list" actions and survives the Export
  /// tab being rebuilt on every tab switch. The Export tab edits it and syncs
  /// changes back via its onListChanged callback.
  final List<ExportClipDraft> _exportClips = [];
  int _exportSeq = 0;

  /// A moment handed off from Clips' "View on timeline" — opens Playback at
  /// that time. Cleared on manual tab nav.
  DateTime? _playbackSeekTo;

  /// Which camera is maximized on the live wall (or null) — carried into
  /// Playback so switching tabs keeps the same full-pane camera.
  String? _liveMaximizedId;

  /// Set from Clips' "View on timeline": open Playback scoped to this single
  /// camera (maximized), not the multi-window view. Cleared on manual tab nav.
  String? _playbackFocusCameraId;

  /// The active Playback screen's motion controller, reported up so the bottom
  /// status bar can render that tab's camera-color legend + timeline hints
  /// (see [PlaybackLegendBar]). Registered on Playback entry, cleared on exit.
  MotionTimelineController? _playbackMotion;

  /// The live wall's perf/debug line (camera count + CPU/GPU/NVDEC/RSS), shown
  /// in the bottom status bar on the Live tab instead of a floating overlay.
  final ValueNotifier<String?> _wallStats = ValueNotifier<String?>(null);

  /// The clip whose "View on timeline" opened the current Playback focus.
  /// Leaving that focus view (double-click / Esc) returns to the Clips tab
  /// with this clip's player reopened — back to the box that opened it, since
  /// the clip's camera may not even be in the current live view. Cleared on
  /// manual tab nav like the other one-shot hand-offs.
  ClipDescriptor? _originClip;

  /// Play-on-focus audio: exactly one pane (maximized else selected) is
  /// audible when audio is on. Owned here, driven by the global audio button
  /// and the wall's tile selection/maximize.
  final AudioFollowController _audio = AudioFollowController();

  @override
  void initState() {
    super.initState();
    // Esc in a clip-originated Playback focus returns to the Clips tab.
    // Registered on HardwareKeyboard (every handler fires for every key
    // event, independent of focus) rather than a Focus.onKeyEvent listener,
    // because primary focus routinely sits outside the Playback subtree and
    // focus-chain Esc handling there never fires — see the same pattern on
    // the clip player (_ClipPlayerState._onKeyEvent, clips_screen.dart).
    HardwareKeyboard.instance.addHandler(_playbackFocusEscHandler);
    _loadDefaultView();
  }

  /// Honor the client-side "launch view" star on startup: if the user pinned a
  /// saved view as their default (ViewPrefs, the old Tauri client's
  /// LS_DEFAULT_VIEW), apply it instead of the built-in "All Cameras" auto-grid
  /// the field initializer starts on. Fails quiet — All Cameras stays the
  /// fallback if the default is unset, points at the sentinel, is stale
  /// (deleted view), or the fetch fails.
  Future<void> _loadDefaultView() async {
    try {
      final prefs = ViewPrefs();
      final defaultId = await prefs.getDefaultViewId();
      if (defaultId == null || defaultId == ViewPrefs.allCamerasId) return;
      final views = await widget.api.listViews(widget.sessionController.session);
      SavedView? match;
      for (final v in views) {
        if (v.id == defaultId) {
          match = v;
          break;
        }
      }
      if (match == null) {
        // Star points at a view that no longer exists — clear it so the app
        // doesn't keep trying to open a ghost on every launch.
        await prefs.clearDefaultIfStale(defaultId);
        return;
      }
      if (!mounted) return;
      _applyView(AppliedView.fromSavedView(match, widget.cameras));
    } catch (_) {
      // Fall back to the default All Cameras wall.
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_playbackFocusEscHandler);
    _audio.dispose();
    _wallStats.dispose();
    super.dispose();
  }

  /// Esc while Playback is showing a clip-originated single-camera focus:
  /// go back to the clip box that opened it. Consumes only the Esc it acts
  /// on; everything else falls through untouched.
  bool _playbackFocusEscHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!mounted) return false;
    if (_index != _playbackIndex || _playbackFocusCameraId == null) {
      return false;
    }
    if (_settingsOpen) return false; // panel on top — don't yank the tab
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return false;
    }
    // A pushed route on top (dialog, goto picker, dropdown) owns its own Esc.
    if (Navigator.of(context).canPop()) return false;
    // Old-client priority: Esc leaves OS fullscreen first; the next Esc
    // returns to Clips. (isFullscreen flips synchronously, so the focus-chain
    // FullscreenEscHandler sees false and won't double-handle this press.)
    if (widget.fullscreen.isFullscreen) {
      widget.fullscreen.setFullscreen(false);
      return true;
    }
    _returnToClips();
    return true;
  }

  /// Leave a clip-originated Playback focus: back to the Clips tab, with the
  /// originating clip's player reopened. Clears the one-shot focus/seek state
  /// so a later manual Playback entry starts clean (keeps [_originClip] so
  /// the remounted Clips screen can reopen the box that launched the review).
  void _returnToClips() {
    setState(() {
      _playbackFocusCameraId = null;
      _playbackSeekTo = null;
      _index = _clipsIndex;
    });
  }

  static const int _liveIndex = 0;
  static const int _playbackIndex = 1;
  static const int _clipsIndex = 2;
  static const int _exportIndex = 3;

  // The body tabs (Settings is a panel toggle, not a body tab — see below).
  // Each carries its own accent color used for the active underline + label.
  // Live amber + Playback cyan match the old client (its --accent / mode-
  // playback swap); Clips/Export/Settings get distinct, function-fitting hues.
  static const _tabs = <(int, IconData, String, Color)>[
    (_liveIndex, Icons.grid_view, 'Live', Color(0xFFE8A33D)), // amber
    (_playbackIndex, Icons.play_circle_outline, 'Playback', Color(0xFF38BDD6)), // cyan
    (_clipsIndex, Icons.movie_outlined, 'Clips', Color(0xFFB57BEF)), // violet
    (_exportIndex, Icons.download_outlined, 'Export', Color(0xFF57C888)), // green
  ];

  static const Color _settingsColor = Color(0xFF9AA4B2); // neutral slate

  /// The active tab's accent color, used app-wide (selection outlines, active
  /// chips, highlights) — mirrors the old client swapping `--accent` per tab.
  Color get _accentColor => _tabs[_index].$4;

  @override
  Widget build(BuildContext context) {
    // Fresh session after an in-place re-auth (the app state rebuilds us via
    // its SessionController listener).
    final session = widget.sessionController.session;
    // Drive an app-wide accent from the active tab: everything that reads
    // colorScheme.primary (selected-tile outline, view chips, buttons) follows
    // the current tab's colour.
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(primary: _accentColor),
      ),
      child: _buildScaffold(session),
    );
  }

  Widget _buildScaffold(Session session) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: widget.fullscreen,
        builder: (context, _) {
          final chromeHidden = widget.fullscreen.isFullscreen;
          return Column(
            children: [
              if (!chromeHidden) ...[
                RecordingAlertBanner(controller: widget.recordingAlerts),
                UpdateBanner(controller: widget.updateCheck),
                _buildTopBar(session),
                // Saved-views quick-switch row — shared by Live and Playback so
                // the header stays the same across the two. Playback only needs
                // to pick which cameras to review, so it hides the Live-only
                // Snapshot + Config View controls.
                if (_index == _liveIndex || _index == _playbackIndex)
                  ViewSelectorBar(
                    key: ValueKey('viewbar-$_viewsRefreshToken'),
                    api: widget.api,
                    session: session,
                    cameras: widget.cameras,
                    activeViewId: _activeViewId,
                    onApply: _applyView,
                    onSnapshot: _index == _liveIndex
                        ? () => SnapshotService.captureActivePane(context)
                        : null,
                    onConfigView: _index == _liveIndex
                        ? () => _openConfigView(session)
                        : null,
                    // Hide the "All Cameras" chip when the option is off.
                    showAllCameras:
                        widget.clientOptions?.showAllCamerasView ?? true,
                  ),
              ],
              Expanded(
                child: Stack(
                  children: [
                    _buildBody(session),
                    // The floating Settings panel overlays the current tab with
                    // no scrim, so the wall behind stays live + interactive.
                    if (_settingsOpen)
                      Positioned.fill(child: _settingsPanel(session)),
                  ],
                ),
              ),
              if (!chromeHidden)
                StatusBar(
                  controller: widget.statusBar,
                  leading: _statusBarLeading(),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The top tab bar: the 5 primary tabs (Live · Playback · Clips · Export ·
  /// Settings) on the left, and the wall toolbar (Layouts · Views · Fullscreen ·
  /// Logout) on the right — mirroring the old client's topbar.
  Widget _buildTopBar(Session session) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            for (final (i, icon, label, color) in _tabs)
              _tabButton(i, icon, label, color),
            // Settings is a floating-panel toggle, not a body tab.
            _settingsToggle(),
            const Spacer(),
            // Connected server address.
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    Uri.tryParse(session.base)?.authority ?? session.base,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // Global audio on/off — the active (maximized else selected) pane
            // is the one audible pane; this toggles it.
            ShiftHint(
              hint: 'Toggle audio (M)',
              above: false,
              child: ListenableBuilder(
                listenable: _audio,
                builder: (context, _) => IconButton(
                  tooltip: _audio.audioOn ? 'Mute audio' : 'Audio off',
                  icon: Icon(
                    _audio.audioOn ? Icons.volume_up : Icons.volume_off,
                    size: 20,
                    color: _audio.audioOn ? scheme.primary : null,
                  ),
                  onPressed: () => _audio.toggleAudio(),
                ),
              ),
            ),
            ShiftHint(
              hint: 'Bookmarks',
              above: false,
              child: IconButton(
                tooltip: 'Bookmarks',
                icon: const Icon(Icons.bookmark_outline, size: 20),
                onPressed: () => _openBookmarks(session),
              ),
            ),
            ShiftHint(
              hint: 'Fullscreen',
              above: false,
              child: IconButton(
                tooltip: 'Fullscreen',
                icon: const Icon(Icons.fullscreen, size: 22),
                onPressed: widget.fullscreen.toggle,
              ),
            ),
            const SizedBox(width: 4),
            ShiftHint(
              hint: 'Sign out',
              above: false,
              child: IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout, size: 18),
                onPressed: _confirmLogout,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(int i, IconData icon, String label, Color color) {
    return _TopTab(
      icon: icon,
      label: label,
      color: color,
      selected: _index == i,
      // Manual tab navigation clears one-shot hand-offs. The export batch is
      // NOT cleared here — it persists until exported or removed, so clips
      // added from Playback accumulate.
      onTap: () => setState(() {
        _playbackSeekTo = null;
        _playbackFocusCameraId = null;
        _originClip = null;
        _index = i;
      }),
    );
  }

  /// The Settings button: toggles the floating Settings panel rather than
  /// switching to a body tab. Highlighted (underline) while the panel is open.
  Widget _settingsToggle() {
    return _TopTab(
      icon: Icons.settings_outlined,
      label: 'Settings',
      color: _settingsColor,
      selected: _settingsOpen,
      onTap: () => setState(() => _settingsOpen = !_settingsOpen),
    );
  }

  /// The floating Settings panel. Native settings render in its right pane;
  /// the WebView2 surfaces (server console, motion tuner) close the panel and
  /// launch full-screen so a web pane never composites over the live wall.
  Widget _settingsPanel(Session session) {
    return SettingsWindow(
      api: widget.api,
      session: session,
      cameras: widget.cameras,
      updateCheck: widget.updateCheck,
      clientOptions: widget.clientOptions,
      streamPrefs: widget.streamPrefs,
      hotkeys: widget.hotkeys,
      onClose: () => setState(() => _settingsOpen = false),
      onOpenServerConsole: () => _pushScreen(
        'Server console',
        AdminConsoleScreen(
          key: const ValueKey('admin-console'),
          session: session,
        ),
      ),
      // Pushed directly (not via _pushScreen) so its own "Motion tuning" app
      // bar — which carries the camera picker — is the ONLY header, instead of
      // stacking under a second "Motion tuner" bar.
      onOpenMotionTuner: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MotionTunerScreen(
            api: widget.api,
            session: session,
            mediaTokenCache: widget.mediaTokens,
            cameras: widget.cameras,
          ),
        ),
      ),
    );
  }

  /// Open the view/layout editor ("Config View") as a floating window (dialog),
  /// like the old client's VIEW SETUP modal. Reloads the view row if a view was
  /// created so it appears immediately.
  Future<void> _openConfigView(Session session) async {
    // Full-screen editor/manager: views list + options on the left, layout
    // builder on the right.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LayoutEditorScreen(
          api: widget.api,
          session: session,
          // Apply-without-save: render the layout on the wall immediately
          // (and jump to Live, since the editor is a Live-tab action).
          onApply: (v) => _applyView(v, toLive: true),
        ),
      ),
    );
    // Views may have been created/edited/deleted/reordered — refresh the row.
    if (mounted) setState(() => _viewsRefreshToken++);
  }

  /// Open Bookmarks — a top-level quick action (not buried in Settings), since
  /// bookmarks are meant for fast access. Shown as a floating window (dialog),
  /// not a full-screen takeover.
  void _openBookmarks(Session session) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 760,
          height: 620,
          child: BookmarksScreen(
            api: widget.api,
            session: session,
            cameras: widget.cameras,
            onJumpToPlayback: (cameraId, ts) {
              Navigator.of(ctx).pop();
              setState(() => _index = _playbackIndex);
            },
          ),
        ),
      ),
    );
  }

  /// Confirm before signing out — the button is easy to hit by accident.
  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You\'ll need to log in again to view cameras.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onLogout();
  }

  /// The cameras Playback should review: the currently-applied view's cameras
  /// (so Playback mirrors what you were watching on Live), or all cameras when
  /// no specific view is applied.
  List<Camera> _playbackCameras() {
    // Clips "View on timeline" scopes Playback to a single camera.
    final focus = _playbackFocusCameraId;
    if (focus != null) {
      final cam = widget.cameras.where((c) => c.id == focus);
      if (cam.isNotEmpty) return [cam.first];
    }
    final view = _appliedView;
    if (view == null) return widget.cameras;
    final byId = {for (final c in widget.cameras) c.id: c};
    final seen = <String>{};
    final out = <Camera>[];
    for (final i in view.slots.keys.toList()..sort()) {
      final id = view.slots[i];
      if (id != null && byId[id] != null && seen.add(id)) out.add(byId[id]!);
    }
    return out.isEmpty ? widget.cameras : out;
  }

  /// Apply a saved view. "All Cameras" (id == [ViewPrefs.allCamerasId]) resets
  /// to the default auto-grid; any other view renders its custom layout.
  ///
  /// Applied from the Live/Playback view row it keeps the current tab (so
  /// picking a view on Playback re-scopes the review set without bouncing to
  /// Live); applied from the Config View editor it lands on Live ([toLive]).
  void _applyView(AppliedView view, {bool toLive = false}) {
    setState(() {
      _activeViewId = view.id;
      _appliedView = view.id == ViewPrefs.allCamerasId ? null : view;
      if (toLive) _index = _liveIndex;
      _settingsOpen = false;
    });
  }

  /// Push a secondary screen (from the Settings panel or a toolbar button) with
  /// a back-navigable app bar.
  void _pushScreen(String title, Widget child) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: child,
        ),
      ),
    );
  }

  /// What occupies the left of the bottom status bar per tab: the Playback
  /// camera legend + hints, the Live wall's perf/debug line, else nothing
  /// (falls back to the status message).
  Widget? _statusBarLeading() {
    if (_index == _playbackIndex && _playbackMotion != null) {
      return PlaybackLegendBar(
        motion: _playbackMotion!,
        cameras: widget.cameras,
      );
    }
    if (_index == _liveIndex) {
      return ValueListenableBuilder<String?>(
        valueListenable: _wallStats,
        builder: (context, v, _) {
          if (v == null || v.isEmpty) return const SizedBox.shrink();
          return Text(
            v,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
        },
      );
    }
    return null;
  }

  Widget _buildBody(Session session) {
    switch (_index) {
      case _playbackIndex:
        return PlaybackScreen(
          // Remount when a "View on timeline" hand-off arrives (open at that
          // moment) or when the applied view changes (re-scope the review set
          // to the newly-picked view's cameras).
          key: ValueKey(
            'pb-${_activeViewId ?? "all"}-'
            '${_playbackFocusCameraId ?? ""}-'
            '${_playbackSeekTo?.millisecondsSinceEpoch ?? 0}',
          ),
          api: widget.api,
          session: session,
          // Mirror the current Live view's cameras (or all if none applied);
          // a Clips focus scopes it to that single camera.
          cameras: _playbackCameras(),
          // Reproduce the wall's custom layout — but a single-camera focus
          // (from Clips) has no layout, it just maximizes that camera.
          view: _playbackFocusCameraId != null ? null : _appliedView,
          initialTime: _playbackSeekTo,
          // Carry a maximized live pane (or the Clips focus) into Playback.
          initialMaximizedCameraId:
              _playbackFocusCameraId ?? _liveMaximizedId,
          onClose: () => setState(() => _index = _liveIndex),
          // A clip-originated focus has no grid to restore to — double-click
          // (and Esc, via the handler above) goes back to the Clips box that
          // opened it, not to a live view the camera may not even be in.
          onExitFocus: _playbackFocusCameraId == null ? null : _returnToClips,
          // Report the motion controller so the bottom status bar can host the
          // legend + hints. Store on register; clear only on a matching
          // unregister (a keyed remount inits the new one before old disposes).
          onMotionController: (c, active) {
            if (active) {
              _playbackMotion = c;
            } else if (identical(_playbackMotion, c)) {
              _playbackMotion = null;
            }
          },
          // Number-key hotkeys load a camera's timeline in playback.
          hotkeys: widget.hotkeys,
          // "Add clip to export list" → APPEND to the batch (don't replace) and
          // jump to the Export tab.
          onExportRange: (camId, start, end) => setState(() {
            _exportClips.add(ExportClipDraft(
              id: ++_exportSeq,
              cameraId: camId,
              start: start,
              end: end,
            ));
            _index = _exportIndex;
          }),
        );
      case _clipsIndex:
        return ClipsScreen(
          api: widget.api,
          session: session,
          cameras: widget.cameras,
          // Number-key hotkeys filter the list to that camera.
          hotkeys: widget.hotkeys,
          // Esc priority: leave OS fullscreen before closing an open clip.
          fullscreen: widget.fullscreen,
          // Returning from a clip-originated Playback → reopen that clip.
          initialClip: _originClip,
          // "View on timeline" → open Playback single-window on that camera.
          onViewOnTimeline: (clip) => setState(() {
            _originClip = clip;
            _playbackSeekTo = clip.startTs;
            _playbackFocusCameraId = clip.cameraId;
            _index = _playbackIndex;
          }),
        );
      case _exportIndex:
        return ExportScreen(
          api: widget.api,
          session: session,
          cameras: widget.cameras,
          // The batch is owned by the shell so it accumulates across adds; the
          // Export tab seeds from it and syncs edits back.
          initialClips: _exportClips,
          onListChanged: (list) {
            _exportClips
              ..clear()
              ..addAll(list);
          },
        );
      case _liveIndex:
      default:
        return WallScreen(
          api: widget.api,
          session: session,
          cameras: widget.cameras,
          onLogout: widget.onLogout,
          // The wall listens to client options so the per-tile header bar
          // (showInfoBar) restyles live when toggled in the Settings panel.
          clientOptions: widget.clientOptions,
          // Per-camera stream (main/sub) + PTZ-disable prefs (right-click menu).
          streamPrefs: widget.streamPrefs,
          // The applied saved view (null → default auto-grid of all cameras).
          view: _appliedView,
          // Play-on-focus audio (global audio button governs it).
          audio: _audio,
          // Number-key hotkeys maximize the assigned camera on the wall.
          hotkeys: widget.hotkeys,
          // Remember which pane is maximized so Playback can open on it.
          onMaximizedCameraChanged: (id) => _liveMaximizedId = id,
          // Perf/debug line → bottom status bar (not a floating wall overlay).
          statsSink: _wallStats,
        );
    }
  }

}

/// A top-bar tab: label (+ small icon) with a 2px accent underline when active,
/// in the tab's own color. Underline style (not a filled pill) and compact
/// sizing — a professional desktop look rather than a mobile segmented control.
class _TopTab extends StatelessWidget {
  const _TopTab({
    required this.icon,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      hoverColor: Colors.white.withValues(alpha: 0.04),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? color : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? color : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                letterSpacing: 0.2,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crumb Flutter spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LivePane(),
    );
  }
}

class LivePane extends StatefulWidget {
  const LivePane({super.key});

  @override
  State<LivePane> createState() => _LivePaneState();
}

class _LivePaneState extends State<LivePane> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  Timer? _statsTimer;
  HostStats? _stats;
  double? _cpuPercent; // derived from cpu_time_secs deltas
  double? _lastCpuTime;
  DateTime? _lastSample;

  // Draggable PTZ-control stub position (fraction of the pane, 0..1). Dragging
  // this over live video is the airspace stress test: a native widget must
  // receive the drag directly, with no HWND mouse-forwarding shim.
  Offset _ptz = const Offset(0.5, 0.78);
  bool _firstFrame = false;

  // ── Digital zoom/pan state ──────────────────────────────────────────────
  // Transform applied to the VIDEO texture only (overlays stay in screen space).
  // Digital zoom upscales the same decoded frame — identical to mpv `video-zoom`
  // — but done Flutter-native: GPU-composited, no per-wheel-tick FFI round-trip,
  // sub-pixel smooth, and works the same for live + playback. Model:
  //   screen = _scale * content + _offset   (content box == the pane).
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  static const double _maxZoom = 8.0;

  /// Zoom about `cursor` (pane px) by `factor`, keeping the point under the
  /// cursor fixed — the surveillance zoom-to-cursor behaviour.
  void _zoomAt(Offset cursor, double factor, Size pane) {
    final newScale = (_scale * factor).clamp(1.0, _maxZoom);
    if (newScale == _scale) return;
    final newOffset = cursor - (cursor - _offset) * (newScale / _scale);
    setState(() {
      _scale = newScale;
      _offset = _clampOffset(newOffset, pane);
    });
  }

  /// Keep the scaled video covering the viewport (no letterbox gap from panning).
  Offset _clampOffset(Offset o, Size pane) {
    final minX = pane.width * (1 - _scale);
    final minY = pane.height * (1 - _scale);
    return Offset(
      o.dx.clamp(minX <= 0 ? minX : 0.0, 0.0),
      o.dy.clamp(minY <= 0 ? minY : 0.0, 0.0),
    );
  }

  void _panBy(Offset delta, Size pane) {
    if (_scale <= 1.0) return; // nothing to pan at 1x
    setState(() => _offset = _clampOffset(_offset + delta, pane));
  }

  void _resetZoom() => setState(() {
    _scale = 1.0;
    _offset = Offset.zero;
  });

  @override
  void initState() {
    super.initState();
    _startVideo();
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollStats(),
    );
    // Note when the first video frame lands (time-to-first-frame is one of the
    // jank metrics we report).
    _player.stream.width.listen((w) {
      if (w != null && w > 0 && !_firstFrame && mounted) {
        setState(() => _firstFrame = true);
      }
    });
  }

  Future<void> _startVideo() async {
    // Force RTSP-over-TCP for reliability on a high-bitrate MAIN stream — the
    // same call the Tauri `configure_mpv` makes. Best-effort: setProperty is on
    // the native backend and is a no-op on platforms without it.
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('rtsp-transport', 'tcp');
      }
    } catch (_) {
      /* non-fatal for the spike */
    }
    await _player.open(Media(kStreamUrl));
  }

  Future<void> _pollStats() async {
    final s = await hostStats();
    if (!mounted) return;
    final now = DateTime.now();
    double? cpuPct;
    if (_lastCpuTime != null && _lastSample != null) {
      final dt = now.difference(_lastSample!).inMilliseconds / 1000.0;
      if (dt > 0) {
        cpuPct = ((s.cpuTimeSecs - _lastCpuTime!) / dt) / s.numCpus * 100.0;
      }
    }
    setState(() {
      _stats = s;
      _cpuPercent = cpuPct;
      _lastCpuTime = s.cpuTimeSecs;
      _lastSample = now;
    });
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final pane = Size(w, h);
          return Stack(
            children: [
              // ── (1) live video texture + (2) digital zoom/pan ─────────────
              // Wheel → zoom-to-cursor, drag → pan (when zoomed), double-tap →
              // reset. The gesture layer spans the pane but sits BELOW the
              // overlays, so dragging the PTZ stub still moves the stub, not the
              // video. The Transform scales only the texture; overlays are
              // screen-space siblings above it (a zoomed pane must not zoom its
              // own HUD).
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      // ~1.13x per wheel notch; sign selects in/out.
                      final factor =
                          math.pow(1.0013, -e.scrollDelta.dy) as double;
                      _zoomAt(e.localPosition, factor, pane);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: _resetZoom,
                    onPanUpdate: (d) => _panBy(d.delta, pane),
                    child: ClipRect(
                      child: Transform(
                        transform: Matrix4.identity()
                          ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                          ..scaleByDouble(_scale, _scale, 1, 1),
                        child: Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ── (3a) native overlay: camera name + FRB-sourced host stats ──
              Positioned(
                top: 16,
                left: 16,
                child: _StatsOverlay(
                  streamUrl: kStreamUrl,
                  firstFrame: _firstFrame,
                  stats: _stats,
                  cpuPercent: _cpuPercent,
                  zoom: _scale,
                ),
              ),

              // ── (3b) native overlay: draggable PTZ-control stub ───────────
              Positioned(
                left: _ptz.dx * w - 44,
                top: _ptz.dy * h - 44,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      _ptz = Offset(
                        (_ptz.dx + d.delta.dx / w).clamp(0.05, 0.95),
                        (_ptz.dy + d.delta.dy / h).clamp(0.05, 0.95),
                      );
                    });
                  },
                  child: const _PtzStub(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Semi-transparent HUD card: proves a native, text-rendering Flutter widget
/// composites cleanly over the video texture and is fed live data across the
/// Rust FFI boundary once per second.
class _StatsOverlay extends StatelessWidget {
  const _StatsOverlay({
    required this.streamUrl,
    required this.firstFrame,
    required this.stats,
    required this.cpuPercent,
    required this.zoom,
  });

  final String streamUrl;
  final bool firstFrame;
  final HostStats? stats;
  final double? cpuPercent;
  final double zoom;

  String get _cam => Uri.tryParse(streamUrl)?.pathSegments.lastOrNull ?? '?';

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final gpu = s?.gpuUtil == null
        ? 'GPU  —  (no NVIDIA)'
        : 'GPU  ${s!.gpuUtil!.toStringAsFixed(0)}%   '
              'NVDEC ${s.gpuDecUtil?.toStringAsFixed(0) ?? "—"}%   '
              'VRAM ${s.gpuMemMb?.toStringAsFixed(0) ?? "—"} MB';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  firstFrame ? Icons.videocam : Icons.hourglass_top,
                  size: 16,
                  color: firstFrame ? Colors.greenAccent : Colors.amber,
                ),
                const SizedBox(width: 6),
                Text(
                  '$_cam   ${firstFrame ? "LIVE" : "connecting…"}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (zoom > 1.01) ...[
                  const SizedBox(width: 10),
                  Text(
                    '${zoom.toStringAsFixed(1)}×',
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              s == null
                  ? 'host_stats: (waiting for first FRB poll)'
                  : 'CPU  ${cpuPercent?.toStringAsFixed(0) ?? "—"}%   '
                        'RSS ${s.memMb.toStringAsFixed(0)} MB   '
                        '${s.numCpus} cores',
            ),
            const SizedBox(height: 2),
            Text(gpu),
            if (s?.gpuName != null) ...[
              const SizedBox(height: 2),
              Text(
                s!.gpuName!,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A stand-in for the on-video PTZ wheel — the surface Jason called janky in the
/// airspace model. Here it is just a native circular control; the point is that
/// it drags smoothly ON TOP of live video with no mouse-forwarding shim.
class _PtzStub extends StatelessWidget {
  const _PtzStub();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(color: Colors.white70, width: 1.5),
      ),
      child: const Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.keyboard_arrow_up, color: Colors.white, size: 22),
          Align(
            alignment: Alignment.bottomCenter,
            child: Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white,
              size: 22,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Icon(
              Icons.keyboard_arrow_left,
              color: Colors.white,
              size: 22,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Icon(
              Icons.keyboard_arrow_right,
              color: Colors.white,
              size: 22,
            ),
          ),
          Icon(Icons.open_with, color: Colors.white54, size: 16),
        ],
      ),
    );
  }
}
