// Embedded /admin console URL building, plus the single-use handoff code that
// opens the console in the operator's real browser.
//
// The server serves its ENTIRE web admin console (services/api/src/admin.html,
// `include_str!`-embedded) at the root route `GET /admin` (services/api/src/
// main.rs `.route("/admin", get(serve_admin))`). admin.html's `bootSSO` reads a
// URL FRAGMENT (never a query param, fragments aren't sent to the server or
// logged) to adopt a session instead of showing its own login form, then scrubs
// the fragment from the visible URL. `&embed=1` tells admin.html it's hosted
// inside another client shell (old Tauri client: an <iframe>; here: an embedded
// WebView) so it can hide its own top-level chrome that would duplicate ours.
//
// Two fragment shapes, for two very different destinations:
//   #token=<jwt>      our OWN embedded WebView: same process, same session.
//   #handoff=<code>   an external browser, which trades the single-use code for
//                     its own session via POST /auth/handoff/exchange.
// A browser keeps history and profile storage we don't control, so the session
// token never goes there; the code is good once and for about a minute.
//
// See the old client's `srvEnterAdmin()` in apps/desktop/src/app.js (~line
// 10946) for the reference implementation this ports.

import 'dart:convert';

import 'http_client.dart';
import 'models.dart';

/// Builds the `{server}/admin?embedded=1#token=<jwt>&embed=1` URL for
/// [session], for THIS app's embedded WebView only.
///
/// Deliberately takes the *full* bearer JWT (matching the old client), not a
/// scoped media token — the admin console needs the operator's real
/// privileges (it's the same RBAC-gated admin UI, not a media stream) and
/// admin.html's `bootSSO` expects a bearer-shaped token in the fragment. The
/// webview runs in this process and stores nothing we don't control, so the
/// token never leaves the client. For an EXTERNAL browser use
/// [adminConsoleBrowserUrl] instead.
///
/// `?embedded=1` makes admin.html hide its own top header chrome (back arrow /
/// title bar) so it doesn't double up with the Flutter shell's header around
/// the webview; the legacy `&embed=1` fragment flag is kept so older servers
/// that only understand it still get the old embed behavior.
String adminConsoleUrl(Session session) {
  return '${_trimmedBase(session)}/admin?embedded=1'
      '#token=${Uri.encodeComponent(session.token)}&embed=1';
}

/// Asks the server for a single-use console-handoff code and builds the
/// `{server}/admin#handoff=<code>` URL for a REAL browser tab.
///
/// The browser trades the code for its own session (admin.html's `bootSSO` →
/// `POST /auth/handoff/exchange`), so this client's session token never reaches
/// a browser's history, profile storage, or extensions. The code is good once
/// and expires in about a minute, so mint a fresh one per launch.
///
/// No `?embedded=1`: a real browser tab has no Flutter shell header, so the
/// console keeps its own chrome there.
///
/// Returns `null` when the server declines or is unreachable (including older
/// servers with no handoff route, which answer 404), so the caller can report a
/// launch failure rather than open a console the operator can't sign in to.
Future<String?> adminConsoleBrowserUrl(Session session) async {
  final base = _trimmedBase(session);
  try {
    final resp = await sharedHttpClient.post(
      Uri.parse('$base/auth/handoff'),
      headers: {'authorization': 'Bearer ${session.token}'},
    );
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body);
    if (body is! Map<String, dynamic>) return null;
    final code = body['code'];
    if (code is! String || code.isEmpty) return null;
    return '$base/admin#handoff=${Uri.encodeComponent(code)}';
  } catch (_) {
    return null;
  }
}

String _trimmedBase(Session session) {
  return session.base.endsWith('/')
      ? session.base.substring(0, session.base.length - 1)
      : session.base;
}

/// The console's hostname, for display next to the pane (e.g. in a header
/// label) without the scheme — mirrors the old client's `srv-admin-host`
/// label (`base.replace(/^https?:\/\//, '')`).
String adminConsoleHostLabel(Session session) {
  return session.base.replaceFirst(RegExp(r'^https?://'), '');
}
