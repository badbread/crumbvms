// Embedded /admin console URL building — no HTTP calls of its own.
//
// The server serves its ENTIRE web admin console (services/api/src/admin.html,
// `include_str!`-embedded) at the root route `GET /admin` (services/api/src/
// main.rs `.route("/admin", get(serve_admin))`). admin.html's `bootSSO` reads a
// `#token=<jwt>` URL FRAGMENT (never a query param — fragments aren't sent to
// the server or logged) to adopt the desktop client's existing bearer session
// instead of showing its own login form, then scrubs the fragment from the
// visible URL. `&embed=1` tells admin.html it's hosted inside another client
// shell (old Tauri client: an <iframe>; here: an embedded WebView) so it can
// hide its own top-level chrome that would duplicate ours.
//
// See the old client's `srvEnterAdmin()` in apps/desktop/src/app.js (~line
// 10946) for the reference implementation this ports.

import 'models.dart';

/// Builds the `{server}/admin?embedded=1#token=<jwt>&embed=1` URL for
/// [session].
///
/// Deliberately takes the *full* bearer JWT (matching the old client), not a
/// scoped media token — the admin console needs the operator's real
/// privileges (it's the same RBAC-gated admin UI, not a media stream) and
/// admin.html's `bootSSO` expects a bearer-shaped token in the fragment.
///
/// `?embedded=1` (default) makes admin.html hide its own top header chrome
/// (back arrow / title bar) so it doesn't double up with the Flutter shell's
/// header around the webview; the legacy `&embed=1` fragment flag is kept so
/// older servers that only understand it still get the old embed behavior.
/// Pass `embedded: false` when the console will live in a real browser tab
/// ("Open in browser") — there's no shell header there, so the console keeps
/// its own.
String adminConsoleUrl(Session session, {bool embedded = true}) {
  final base = session.base.endsWith('/')
      ? session.base.substring(0, session.base.length - 1)
      : session.base;
  final q = embedded ? '?embedded=1' : '';
  return '$base/admin$q#token=${Uri.encodeComponent(session.token)}&embed=1';
}

/// The console's hostname, for display next to the pane (e.g. in a header
/// label) without the scheme — mirrors the old client's `srv-admin-host`
/// label (`base.replace(/^https?:\/\//, '')`).
String adminConsoleHostLabel(Session session) {
  return session.base.replaceFirst(RegExp(r'^https?://'), '');
}
