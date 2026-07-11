// Settings-panel control + launch-time application for the "open the wall
// fullscreen on launch" preference. Port of app.js `opt-launch-fullscreen`
// (the Client-options checkbox, reflected/wired at app.js:6511 and
// app.js:11029) and the launch-time check in `applyLaunchPreferences()`
// (app.js:3871-3885): "open to the user's default view... then enter the
// fullscreen camera wall if that option is on".

import 'package:flutter/material.dart';

import 'package:crumb_desktop/ui/fullscreen/fullscreen_controller.dart';
import 'package:crumb_desktop/ui/fullscreen/launch_fullscreen_prefs.dart';

/// Reads the persisted preference and, if set, enters fullscreen. Call this
/// once, AFTER the default view/camera wall has finished its initial load —
/// same ordering as the old client's `applyLaunchPreferences()`, which
/// applies the default view first and only then checks
/// `options.launchFullscreen`.
Future<void> applyLaunchFullscreenPreference(
  FullscreenController controller,
) async {
  final wantsFullscreen = await LaunchFullscreenPrefs.get();
  if (wantsFullscreen) {
    await controller.setFullscreen(true);
  }
}

/// A settings-panel checkbox for the "Launch into fullscreen camera wall"
/// preference — drop into a client-options/settings screen. Self-contained:
/// loads its current value on first build and persists changes immediately
/// (mirrors the old client's change listener at app.js:6511, which set
/// `options.launchFullscreen` and called `saveOptions()` on every toggle).
class LaunchFullscreenOption extends StatefulWidget {
  const LaunchFullscreenOption({super.key});

  @override
  State<LaunchFullscreenOption> createState() =>
      _LaunchFullscreenOptionState();
}

class _LaunchFullscreenOptionState extends State<LaunchFullscreenOption> {
  bool? _value; // null while loading

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await LaunchFullscreenPrefs.get();
    if (mounted) setState(() => _value = v);
  }

  Future<void> _onChanged(bool? v) async {
    final next = v ?? false;
    setState(() => _value = next);
    await LaunchFullscreenPrefs.set(next);
  }

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: _value ?? false,
      onChanged: _value == null ? null : _onChanged,
      title: const Text('Launch into fullscreen camera wall'),
      subtitle: const Text(
        'Skip straight to a chrome-less fullscreen wall after signing in.',
      ),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}
