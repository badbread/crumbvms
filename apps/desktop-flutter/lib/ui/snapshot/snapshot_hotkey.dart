// Wires the "S" hotkey to [SnapshotService.captureActivePane]. Old client:
// the global keydown handler's `if (e.key === 's' || e.key === 'S')` branch
// (apps/desktop/src/app.js:4132), which called `snapshotActivePane()`
// directly.
//
// Wrap the signed-in shell (same level as ReauthOverlay — see
// lib/ui/reauth/reauth_overlay.dart for the established pattern of wrapping
// `child` rather than editing it) so the hotkey works regardless of which
// pane currently has focus:
//
//   SnapshotHotkey(child: WallShell(...))
//
// This only wires the *hotkey*. The toolbar button (`SnapshotToolbarButton`
// below) is separate so it can be dropped into the existing toolbar without
// needing this wrapper.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/snapshot_service.dart';

class _SnapshotIntent extends Intent {
  const _SnapshotIntent();
}

class SnapshotHotkey extends StatelessWidget {
  const SnapshotHotkey({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyS): _SnapshotIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SnapshotIntent: CallbackAction<_SnapshotIntent>(
            onInvoke: (_) {
              SnapshotService.captureActivePane(context);
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

/// Toolbar button, old client: `#toolbar-snapshot-btn`
/// (apps/desktop/src/app.js:6448). Drop next to the existing toolbar
/// buttons (mute, fullscreen, etc.).
class SnapshotToolbarButton extends StatelessWidget {
  const SnapshotToolbarButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Snapshot active pane (S)',
      icon: const Icon(Icons.camera_alt_outlined),
      onPressed: () => SnapshotService.captureActivePane(context),
    );
  }
}
