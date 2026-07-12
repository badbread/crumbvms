// Client options / settings screen — port of the old Tauri client's Options
// dialog (apps/desktop/src/app.js: `optOpen`/`optClose` ~line 1671, the
// change-listener block ~line 6503, and `srvReflectClientOptions` ~line
// 11025). All of these are pure client-side preferences — no server API is
// involved, matching the old client's `LS_OPTIONS_KEY` localStorage blob.
//
// This screen is self-contained (new files only, per the porting rules) and
// pulls together:
//   * this feature's own [ClientOptionsStore] (showInfoBar,
//     showAllCamerasView, hotkeysEnabled, maximizeMain, ptzClickMode,
//     ptzStyle, ptzWheelCorner),
//   * the already-ported [LaunchFullscreenOption] widget
//     (lib/ui/fullscreen/launch_fullscreen_option.dart), and
//   * the already-ported [StreamPrefsStore.wallUsesSub]
//     (lib/state/stream_prefs.dart) for "wall tiles use sub streams".
//
// NOTE (integration): give the caller access to the SAME `StreamPrefsStore`
// instance the live wall uses (so toggling "wall uses sub streams" here takes
// effect immediately on already-built tiles) — see integration notes for how
// to wire it up in `main.dart`. If no store is available yet, pass `null` and
// this screen still works, it just won't be able to change a wall that's
// already on screen until the app is restarted (the preference itself still
// persists correctly either way).
//
// The old dialog rebuilt the tile grid and repolled live-status on close
// (`optClose`) because `showInfoBar` changes affect tile layout/insets.
// [onMaybeLayoutAffectingChange] is this screen's equivalent hook: call it
// with the callback that rebuilds your wall's tile grid, and this screen
// invokes it whenever `showInfoBar` changes.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/stream_prefs.dart';
import 'package:crumb_desktop/ui/fullscreen/launch_fullscreen_option.dart';

class ClientOptionsScreen extends StatefulWidget {
  const ClientOptionsScreen({
    super.key,
    required this.options,
    this.streamPrefs,
    this.onMaybeLayoutAffectingChange,
  });

  /// Loaded client-options store (construct via `ClientOptionsStore.load()`
  /// before pushing this screen — see integration notes).
  final ClientOptionsStore options;

  /// The live wall's stream-preference store, if already constructed by the
  /// caller. When present, toggling "wall tiles use sub streams" here updates
  /// it directly so an already-visible wall picks it up immediately.
  final StreamPrefsStore? streamPrefs;

  /// Called after a change that the old client's `optClose()` used to react
  /// to by rebuilding the tile grid (currently just `showInfoBar`, which
  /// changes whether tiles reserve space for the title strip).
  final VoidCallback? onMaybeLayoutAffectingChange;

  @override
  State<ClientOptionsScreen> createState() => _ClientOptionsScreenState();
}

class _ClientOptionsScreenState extends State<ClientOptionsScreen> {
  ClientOptionsStore get _o => widget.options;

  void _setShowInfoBar(bool v) {
    setState(() => _o.showInfoBar = v);
    widget.onMaybeLayoutAffectingChange?.call();
  }

  void _setShowAllCamerasView(bool v) => setState(() => _o.showAllCamerasView = v);
  void _setHotkeysEnabled(bool v) => setState(() => _o.hotkeysEnabled = v);
  void _setMaximizeMain(bool v) => setState(() => _o.maximizeMain = v);
  void _setZoomSwitchesToMain(bool v) =>
      setState(() => _o.zoomSwitchesToMain = v);

  bool get _wallUsesSub => widget.streamPrefs?.wallUsesSub ?? true;
  void _setWallUsesSub(bool v) {
    setState(() {
      if (widget.streamPrefs != null) widget.streamPrefs!.wallUsesSub = v;
    });
  }

  void _setPtzClickMode(PtzClickMode v) => setState(() => _o.ptzClickMode = v);
  void _setPtzStyle(PtzStyle v) => setState(() => _o.ptzStyle = v);
  void _setPtzWheelCorner(PtzWheelCorner v) =>
      setState(() => _o.ptzWheelCorner = v);

  /// A compact preference row with a small (non-blobby) switch — a desktop
  /// alternative to the touch-sized [SwitchListTile]. Disabled when
  /// [onChanged] is null.
  Widget _switchRow({
    required bool value,
    required ValueChanged<bool>? onChanged,
    required String title,
    String? subtitle,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 7, 12, 7),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: enabled ? null : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Transform.scale(
              scale: 0.72,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Client options')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SectionHeader('Camera wall'),
          _switchRow(
            value: _o.showInfoBar,
            onChanged: _setShowInfoBar,
            title: 'Show tile info bar',
            subtitle: 'Camera name and REC/motion indicators on each tile.',
          ),
          _switchRow(
            value: _o.showAllCamerasView,
            onChanged: _setShowAllCamerasView,
            title: 'Show "All Cameras" quick view',
            subtitle: 'Auto-build a grid of every camera as a selectable view.',
          ),
          _switchRow(
            value: _wallUsesSub,
            onChanged: widget.streamPrefs == null ? null : _setWallUsesSub,
            title: 'Wall tiles use sub streams',
            subtitle: widget.streamPrefs == null
                ? 'Unavailable — no stream preference store wired up for this screen.'
                : 'Lower-bandwidth stream for the grid; maximizing a tile can still switch to main below.',
          ),
          if (widget.streamPrefs != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Right-click a camera to set its stream individually — that '
                      'overrides this default for that camera.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.streamPrefs!.hasAnyOverride
                        ? () => setState(widget.streamPrefs!.clearAllOverrides)
                        : null,
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
          _switchRow(
            value: _o.maximizeMain,
            onChanged: _setMaximizeMain,
            title: 'Maximize plays main stream',
            subtitle:
                'Full-quality stream when a tile is maximized, instead of staying on the wall\'s stream.',
          ),
          _switchRow(
            value: _o.zoomSwitchesToMain,
            onChanged: _setZoomSwitchesToMain,
            title: 'Zoom switches to main stream',
            subtitle:
                'Digitally zooming a wall tile past 100% temporarily loads its full-res main stream; back at 100% it reverts to sub.',
          ),

          const Divider(height: 24),
          _SectionHeader('PTZ controls'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Click behavior on a PTZ-capable video'),
          ),
          RadioListTile<PtzClickMode>(
            value: PtzClickMode.center,
            groupValue: _o.ptzClickMode,
            onChanged: (v) => _setPtzClickMode(v!),
            title: const Text('Click to center'),
            dense: true,
          ),
          RadioListTile<PtzClickMode>(
            value: PtzClickMode.pan,
            groupValue: _o.ptzClickMode,
            onChanged: (v) => _setPtzClickMode(v!),
            title: const Text('Click and hold to pan'),
            dense: true,
          ),
          RadioListTile<PtzClickMode>(
            value: PtzClickMode.off,
            groupValue: _o.ptzClickMode,
            onChanged: (v) => _setPtzClickMode(v!),
            title: const Text('Off'),
            dense: true,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Overlay style'),
          ),
          RadioListTile<PtzStyle>(
            value: PtzStyle.edges,
            groupValue: _o.ptzStyle,
            onChanged: (v) => _setPtzStyle(v!),
            title: const Text('Edge arrows'),
            dense: true,
          ),
          RadioListTile<PtzStyle>(
            value: PtzStyle.wheel,
            groupValue: _o.ptzStyle,
            onChanged: (v) => _setPtzStyle(v!),
            title: const Text('Corner wheel'),
            dense: true,
          ),
          if (_o.ptzStyle == PtzStyle.wheel)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  const Text('Wheel corner:'),
                  const SizedBox(width: 12),
                  DropdownButton<PtzWheelCorner>(
                    value: _o.ptzWheelCorner,
                    onChanged: (v) => _setPtzWheelCorner(v!),
                    items: const [
                      DropdownMenuItem(
                        value: PtzWheelCorner.bottomLeft,
                        child: Text('Bottom left'),
                      ),
                      DropdownMenuItem(
                        value: PtzWheelCorner.bottomRight,
                        child: Text('Bottom right'),
                      ),
                      DropdownMenuItem(
                        value: PtzWheelCorner.topLeft,
                        child: Text('Top left'),
                      ),
                      DropdownMenuItem(
                        value: PtzWheelCorner.topRight,
                        child: Text('Top right'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

          const Divider(height: 24),
          _SectionHeader('Hotkeys'),
          _switchRow(
            value: _o.hotkeysEnabled,
            onChanged: _setHotkeysEnabled,
            title: 'Enable keyboard shortcuts',
          ),

          const Divider(height: 24),
          _SectionHeader('Launch'),
          const LaunchFullscreenOption(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
