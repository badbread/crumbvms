// Guard for native OS file/folder/save dialogs (file_selector's
// getDirectoryPath / getSaveLocation / openFile) so they don't wedge the app
// under borderless fullscreen.
//
// The Win32 dialog (IFileDialog) is modal to — and DISABLES — the app's window.
// Under window_manager's borderless fullscreen (setFullScreen) the dialog can
// open BEHIND the fullscreen surface, so the user sees a disabled, apparently
// frozen app with no visible dialog. [runNativePicker] drops to windowed +
// foregrounds the window for the duration of the pick, then restores fullscreen
// — every window_manager call is best-effort so it degrades to the old
// behavior if the plugin is unavailable. FullscreenController hears the
// enter/leave-fullscreen events (it's built for externally-driven changes) and
// keeps its chrome in sync.

import 'dart:async';

import 'package:window_manager/window_manager.dart';

/// Run [pick] (a native OS dialog call) with the fullscreen-safe window guard.
/// Returns whatever [pick] returns; restores fullscreen even if [pick] throws.
Future<T> runNativePicker<T>(Future<T> Function() pick) async {
  bool wasFullscreen = false;
  try {
    wasFullscreen = await windowManager.isFullScreen();
  } catch (_) {
    // window_manager unavailable — just run the pick as-is.
    return pick();
  }
  try {
    if (wasFullscreen) {
      await windowManager.setFullScreen(false);
      // Let the window transition settle before the modal message loop takes
      // over, so the dialog z-orders against the windowed state.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // The Win32 dialog parents to whatever window is foreground; if ours is
    // hidden or not foreground (e.g. just restored from minimize, issue #91)
    // the dialog can open BEHIND it and the app looks frozen. show() before
    // focus() makes the window a proper visible, foreground owner — the extra
    // step over a bare focus() that the folder picker needs (#87). Both
    // best-effort; show() does not un-maximize, so it's safe on any state.
    try {
      await windowManager.show();
    } catch (_) {
      /* best-effort */
    }
    try {
      await windowManager.focus(); // dialog opens above a foreground owner
    } catch (_) {
      /* best-effort */
    }
    return await pick();
  } finally {
    if (wasFullscreen) {
      try {
        await windowManager.setFullScreen(true);
      } catch (_) {
        /* best-effort */
      }
    }
  }
}
