// The floating Settings panel — a draggable + resizable in-app window that
// overlays the current tab (usually the live wall) WITHOUT a modal scrim, so
// the wall keeps running and updates live behind it. This replaces the old
// full-screen "Settings" tab + tile hub: all settings sit in one left-nav list
// and the selected one renders in the right pane (master-detail), one click.
//
// Two kinds of nav entries:
//   * PANE   — pure-Flutter settings (Options, Hotkeys, Server dashboard,
//              Bookmarks) render right here in the pane; changing an Option
//              (e.g. "Show tile info bar") restyles the wall live behind the
//              panel via the ClientOptionsStore ChangeNotifier.
//   * LAUNCH — WebView2-backed surfaces (Server console `/admin`, Motion tuner)
//              would composite a native web pane OVER the live media_kit wall
//              and reintroduce the exact airspace jank the Flutter rewrite
//              escaped, so they are NOT floated: selecting one closes the panel
//              and opens it as its own full screen (handled by the caller).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hotkey_config.dart';
import 'package:crumb_desktop/state/keyboard_shortcuts.dart';
import 'package:crumb_desktop/state/stream_prefs.dart';
import 'package:crumb_desktop/ui/client_options/client_options_screen.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_remap_screen.dart';
import 'package:crumb_desktop/ui/hotkeys/keyboard_shortcuts_screen.dart';
import 'package:crumb_desktop/ui/server/server_dashboard_screen.dart';
import 'package:crumb_desktop/ui/settings/ha_settings_screen.dart';
import 'package:crumb_desktop/ui/updates/about_panel.dart';
import 'package:crumb_desktop/ui/updates/update_check_controller.dart';

/// Identifies a settings section. PANE sections render in the right pane;
/// LAUNCH sections open as their own full screen (see file header).
enum SettingsSection {
  options(Icons.tune, 'Options', pane: true),
  keyboardShortcuts(Icons.keyboard_alt_outlined, 'Keyboard Shortcuts',
      pane: true),
  hotkeys(Icons.keyboard_outlined, 'Camera Hotkeys', pane: true),
  serverDashboard(Icons.dns_outlined, 'Server dashboard', pane: true),
  // Admin-only (issue #52 desktop port) — SettingsWindow hides this nav
  // entry entirely for non-admins (see `_leftNav`); `PUT/POST /config/ha*`
  // are admin-enforced server-side regardless.
  homeAssistant(Icons.home_outlined, 'Home Assistant', pane: true),
  about(Icons.info_outline, 'About', pane: true),
  serverConsole(Icons.admin_panel_settings_outlined, 'Server console',
      pane: false),
  motionTuner(Icons.sensors, 'Motion tuner', pane: false);

  const SettingsSection(this.icon, this.label, {required this.pane});

  final IconData icon;
  final String label;

  /// True → renders in the panel's right pane; false → the panel closes and the
  /// caller launches it full-screen (WebView2 surfaces, see file header).
  final bool pane;
}

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.onClose,
    required this.onOpenServerConsole,
    required this.onOpenMotionTuner,
    required this.updateCheck,
    required this.isAdmin,
    this.clientOptions,
    this.streamPrefs,
    this.hotkeys,
    this.keyboardShortcuts,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Server-side truth (`GET /auth/me`, see `main.dart`'s `_isAdmin`) for
  /// whether this account is an admin. Gates the "Home Assistant" nav entry
  /// entirely (hidden, not just disabled, for non-admins) — the server is
  /// still the authority (`PUT`/`POST /config/ha*` are admin-enforced there
  /// regardless), this only avoids showing a section that would 403 anyway.
  final bool isAdmin;

  /// Close the panel (X button, or after a LAUNCH section is picked).
  final VoidCallback onClose;

  /// Open the WebView2 surfaces as their own full screen (panel closes first).
  final VoidCallback onOpenServerConsole;
  final VoidCallback onOpenMotionTuner;

  /// Drives the About pane's version + update-check status.
  final UpdateCheckController updateCheck;

  final ClientOptionsStore? clientOptions;
  final StreamPrefsStore? streamPrefs;
  final HotkeyConfigStore? hotkeys;
  final KeyboardShortcutsStore? keyboardShortcuts;

  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> {
  static const double _minW = 460;
  static const double _minH = 340;
  static const double _titleBarH = 40;

  SettingsSection _section = SettingsSection.options;

  // Panel geometry. `_pos` is null until the first layout, at which point the
  // panel is centered in the available area. Stored raw; clamped to the
  // available bounds at paint time (and in the drag handlers via `_bounds`).
  Offset? _pos;
  Size _size = const Size(860, 580);
  Size _bounds = Size.zero;

  void _moveBy(Offset delta) {
    final p = (_pos ?? Offset.zero) + delta;
    setState(() => _pos = _clampPos(p, _size));
  }

  void _resizeBy(Offset delta) {
    final w = (_size.width + delta.dx).clamp(_minW, _maxW);
    final h = (_size.height + delta.dy).clamp(_minH, _maxH);
    setState(() {
      _size = Size(w, h);
      // Keep the (unchanged) top-left inside bounds as the panel grows.
      _pos = _clampPos(_pos ?? Offset.zero, _size);
    });
  }

  double get _maxW => _bounds.width <= 0 ? _minW : _bounds.width;
  double get _maxH => _bounds.height <= 0 ? _minH : _bounds.height;

  Offset _clampPos(Offset p, Size size) {
    final maxX = (_bounds.width - size.width).clamp(0.0, double.infinity);
    final maxY = (_bounds.height - size.height).clamp(0.0, double.infinity);
    return Offset(p.dx.clamp(0.0, maxX), p.dy.clamp(0.0, maxY));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _bounds = Size(constraints.maxWidth, constraints.maxHeight);
        final w = _size.width.clamp(_minW, _maxW);
        final h = _size.height.clamp(_minH, _maxH);
        // Center on first appearance.
        final pos = _clampPos(
          _pos ?? Offset((_maxW - w) / 2, (_maxH - h) / 2),
          Size(w, h),
        );
        return Stack(
          children: [
            Positioned(
              left: pos.dx,
              top: pos.dy,
              width: w,
              height: h,
              child: _panel(),
            ),
          ],
        );
      },
    );
  }

  Widget _panel() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 16,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              _titleBar(scheme),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _leftNav(scheme),
                    VerticalDivider(width: 1, color: scheme.outlineVariant),
                    Expanded(child: _rightPane()),
                  ],
                ),
              ),
            ],
          ),
          // Bottom-right resize handle.
          Positioned(
            right: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeDownRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => _resizeBy(d.delta),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.signal_cellular_4_bar, // diagonal "grip" glyph
                    size: 14,
                    color: scheme.outline,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleBar(ColorScheme scheme) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => _moveBy(d.delta),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: Container(
          height: _titleBarH,
          padding: const EdgeInsets.only(left: 14, right: 6),
          color: scheme.surfaceContainerHighest,
          child: Row(
            children: [
              Icon(Icons.settings_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              const Text(
                'Settings',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leftNav(ColorScheme scheme) {
    return SizedBox(
      width: 190,
      child: Container(
        color: scheme.surfaceContainerLow,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            for (final s in SettingsSection.values)
              // Non-admins never see the entry at all (not just disabled) —
              // it would just 403 server-side.
              if (s != SettingsSection.homeAssistant || widget.isAdmin) ...[
                if (s == SettingsSection.serverConsole)
                  Divider(height: 9, color: scheme.outlineVariant),
                _navTile(scheme, s),
              ],
          ],
        ),
      ),
    );
  }

  Widget _navTile(ColorScheme scheme, SettingsSection s) {
    final selected = s.pane && s == _section;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.12),
      leading: Icon(s.icon, size: 20),
      title: Text(s.label, style: const TextStyle(fontSize: 13)),
      // LAUNCH sections show an "opens separately" hint.
      trailing: s.pane
          ? null
          : Icon(Icons.open_in_new, size: 14, color: scheme.onSurfaceVariant),
      onTap: () => _select(s),
    );
  }

  void _select(SettingsSection s) {
    if (s.pane) {
      setState(() => _section = s);
      return;
    }
    // WebView2 surface — close the panel, then launch it full-screen.
    widget.onClose();
    switch (s) {
      case SettingsSection.serverConsole:
        widget.onOpenServerConsole();
      case SettingsSection.motionTuner:
        widget.onOpenMotionTuner();
      default:
        break;
    }
  }

  Widget _rightPane() {
    switch (_section) {
      case SettingsSection.options:
        final opts = widget.clientOptions;
        if (opts == null) return const _Unavailable('Options');
        return ClientOptionsScreen(
          options: opts,
          streamPrefs: widget.streamPrefs,
        );
      case SettingsSection.keyboardShortcuts:
        final ks = widget.keyboardShortcuts;
        if (ks == null) return const _Unavailable('Keyboard shortcuts');
        return KeyboardShortcutsScreen(
          store: ks,
          options: widget.clientOptions,
          cameraHotkeys: widget.hotkeys,
          cameras: widget.cameras,
        );
      case SettingsSection.hotkeys:
        final hk = widget.hotkeys;
        if (hk == null) return const _Unavailable('Camera hotkeys');
        return HotkeyRemapScreen(store: hk, cameras: widget.cameras);
      case SettingsSection.serverDashboard:
        return ServerDashboardScreen(api: widget.api, session: widget.session);
      case SettingsSection.homeAssistant:
        // Defensive fallback: the nav entry is hidden for non-admins (see
        // `_leftNav`), so this only fires if `_section` is somehow forced to
        // this value some other way.
        if (!widget.isAdmin) return const _Unavailable('Home Assistant');
        return HaSettingsScreen(api: widget.api, session: widget.session);
      case SettingsSection.about:
        return AboutPanel(controller: widget.updateCheck);
      case SettingsSection.serverConsole:
      case SettingsSection.motionTuner:
        // Never rendered in-pane (see _select), but keep the switch exhaustive.
        return const SizedBox.shrink();
    }
  }
}

/// Shown when a pane's backing store didn't load (plugin unavailable). Rare —
/// the stores degrade to in-memory, so this is a defensive fallback.
class _Unavailable extends StatelessWidget {
  const _Unavailable(this.name);
  final String name;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '$name are unavailable on this session.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}
