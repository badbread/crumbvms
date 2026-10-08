// Sign-out cleanup for the embedded management console's WebView2 storage.
//
// Older consoles persisted the bearer token to `localStorage` in the shared
// WebView2 profile (and a signed-out wall PC kept it there). The console no
// longer does that when embedded, but a profile that predates the change may
// still hold one, so sign-out wipes the console origin's storage, cookies and
// cache. Best effort and time-boxed: it must never block or fail a sign-out.

import 'dart:async';

import 'package:webview_windows/webview_windows.dart';

/// The script that removes every credential the console may have stored.
const String kConsoleStorageWipeScript =
    "try{localStorage.removeItem('crumb_admin_token');}catch(e){}"
    'try{sessionStorage.clear();}catch(e){}';

/// Wipe the console's stored credential for [serverBase] (e.g.
/// `http://host:8080`). Opens a throwaway controller in the same profile,
/// navigates it to a same-origin page so the origin's storage is reachable,
/// clears it, then clears cookies and cache. Returns true when the wipe ran.
Future<bool> wipeConsoleStorage(
  String serverBase, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final controller = WebviewController();
  try {
    return await _wipe(controller, serverBase).timeout(timeout);
  } catch (_) {
    return false; // runtime missing / not Windows / timed out: nothing to do
  } finally {
    try {
      await controller.dispose();
    } catch (_) {
      /* ignore */
    }
  }
}

Future<bool> _wipe(WebviewController controller, String serverBase) async {
  var base = serverBase.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  await controller.initialize();
  // Subscribe before navigating so a fast load cannot be missed.
  final loaded = controller.loadingState.firstWhere(
    (s) => s == LoadingState.navigationCompleted,
  );
  // /health is unauthenticated and tiny; any same-origin document exposes the
  // origin's localStorage.
  await controller.loadUrl('$base/health');
  await loaded;
  await controller.executeScript(kConsoleStorageWipeScript);
  await controller.clearCookies();
  await controller.clearCache();
  return true;
}
