// Server > Management: the server's full web admin console, embedded via a
// native WebView2 pane with the desktop client's bearer token handed off in
// the URL fragment so the operator isn't asked to log in a second time.
//
// Ports the old Tauri client's `srvEnterAdmin()` (apps/desktop/src/app.js,
// ~line 10946), which built an `<iframe src="{server}/admin#token=…&embed=1">`
// keyed on `server|token` so switching tabs and coming back doesn't reset the
// operator's place in the console. `webview_windows` is the Flutter-native
// equivalent of that iframe on Windows (WebView2/Edge Chromium — no extra
// runtime download on a normal Win10/11 box). "Open in browser" mirrors the
// old client's `invoke('open_url', { url })` fallback (apps/desktop/src-tauri/
// src/lib.rs ~line 1317) for operators who'd rather use their real browser
// (bookmarks, extensions, a second monitor, etc.) or if WebView2 isn't usable.
//
// NOTE (integration): this file assumes the `webview_windows` and
// `url_launcher` packages are added to pubspec.yaml — see this feature's
// integration notes. This file is intentionally self-contained (new files
// only, per the porting rules) and does not touch pubspec.yaml itself.

import 'dart:async' show unawaited;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

import 'package:crumb_desktop/api/admin_console_api.dart';
import 'package:crumb_desktop/api/models.dart';

/// Embeds `{server}/admin?embedded=1#token=<jwt>&embed=1` in a native
/// WebView2 pane (`?embedded=1` hides admin.html's own header chrome so it
/// doesn't double up with this shell's header).
///
/// Give this widget a STABLE key across rebuilds of the surrounding nav (e.g.
/// `const ValueKey('admin-console')`) so Flutter doesn't tear down and
/// recreate the WebviewController just because a parent rebuilt — that would
/// reset the operator's place in the console exactly like the bug the old
/// client's `adminSrcKey` guard avoided. This widget itself already avoids
/// reloading the page when [session] is unchanged (see [_maybeLoad]).
class AdminConsoleScreen extends StatefulWidget {
  const AdminConsoleScreen({super.key, required this.session});

  final Session session;

  @override
  State<AdminConsoleScreen> createState() => _AdminConsoleScreenState();
}

enum _LoadState { initializing, ready, unsupported, error }

class _AdminConsoleScreenState extends State<AdminConsoleScreen> {
  final WebviewController _controller = WebviewController();
  _LoadState _state = _LoadState.initializing;
  String? _errorMessage;

  // Mirrors the old client's `srvState.adminSrcKey` (`${base}|${token}`):
  // only (re)navigate the webview when the server or token actually changed,
  // so re-entering this screen (e.g. switching nav tabs) doesn't reload the
  // page and lose the operator's place in the console.
  String? _loadedKey;

  String get _key => '${widget.session.base}|${widget.session.token}';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // Throws (or the platform channel is simply unavailable) if the
      // WebView2 runtime isn't installed / this isn't Windows — surfaced as
      // "unsupported" so the UI can steer the operator to "Open in browser"
      // instead of a raw exception.
      await _controller.initialize();
      if (!mounted) return;
      setState(() => _state = _LoadState.ready);
      await _maybeLoad();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.unsupported;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  void didUpdateWidget(covariant AdminConsoleScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_state == _LoadState.ready) {
      unawaited(_maybeLoad());
    }
  }

  Future<void> _maybeLoad() async {
    if (_loadedKey == _key) return; // already current, keep operator's place
    _loadedKey = _key;
    try {
      await _controller.loadUrl(adminConsoleUrl(widget.session));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _openInBrowser() async {
    // A real browser tab has no Flutter shell header, so let the console keep
    // its own chrome there.
    final uri = Uri.parse(adminConsoleUrl(widget.session, embedded: false));
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _showLaunchFailure();
    } catch (_) {
      if (mounted) _showLaunchFailure();
    }
  }

  void _showLaunchFailure() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the console.')),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Management — ${adminConsoleHostLabel(widget.session)}'),
        actions: [
          IconButton(
            tooltip: 'Open in browser',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openInBrowser,
          ),
          if (_state == _LoadState.ready)
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _loadedKey = null;
                unawaited(_maybeLoad());
              },
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    switch (_state) {
      case _LoadState.initializing:
        return const Center(child: CircularProgressIndicator());
      case _LoadState.ready:
        // webview_windows doesn't forward the mouse wheel to the page, so the
        // console can't be scrolled. Intercept the scroll and drive it into the
        // page via JS (window + the element under the cursor, to cover inner
        // scroll containers).
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              final dy = e.scrollDelta.dy;
              unawaited(
                _controller.executeScript(
                  '(function(d){'
                  'var el=document.elementFromPoint('
                  '${e.localPosition.dx.round()},${e.localPosition.dy.round()});'
                  'while(el){var s=getComputedStyle(el);'
                  'if(/(auto|scroll)/.test(s.overflowY)&&'
                  'el.scrollHeight>el.clientHeight){el.scrollTop+=d;return;}'
                  'el=el.parentElement;}'
                  'window.scrollBy(0,d);'
                  '})($dy);',
                ),
              );
            }
          },
          child: Webview(_controller),
        );
      case _LoadState.unsupported:
      case _LoadState.error:
        return _fallback();
    }
  }

  /// Shown when the embedded WebView2 pane can't be used (runtime missing,
  /// non-Windows platform, or a navigation error) — steer the operator to
  /// the same destination via their real browser rather than a dead screen.
  Widget _fallback() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off, size: 40, color: Colors.white38),
            const SizedBox(height: 12),
            const Text(
              'The embedded console pane is unavailable on this machine.',
              textAlign: TextAlign.center,
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openInBrowser,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open in browser'),
            ),
          ],
        ),
      ),
    );
  }
}
