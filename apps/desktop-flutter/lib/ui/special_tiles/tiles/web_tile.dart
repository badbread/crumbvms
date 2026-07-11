// Embedded web page tile (an `<iframe>` in app.js; ported to a native Windows
// webview control here since Flutter has no cross-platform `<iframe>`).
//
// PLATFORM DEPENDENCY: this widget is written against `webview_windows`
// (https://pub.dev/packages/webview_windows), the standard Flutter plugin for
// embedding an OS WebView2 control on Windows desktop (same underlying engine
// Tauri used) — no custom Rust/FFI needed. It is NOT yet in pubspec.yaml; see
// this feature's integration notes for the dependency line + any
// platform-specific setup (WebView2 runtime — normally already present on
// Windows 10/11, same as the old Tauri build's requirement).
//
// If the desktop app later targets macOS/Linux too, `webview_windows` won't
// cover those — swap for `webview_flutter` there (its Windows support has
// historically lagged, hence picking `webview_windows` for this Windows-first
// build; see apps/desktop's WebView2 precedent in AGENTS.md).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import '../special_tile_spec.dart';

class WebTile extends StatefulWidget {
  const WebTile({super.key, required this.spec});

  final WebSpec spec;

  @override
  State<WebTile> createState() => _WebTileState();
}

class _WebTileState extends State<WebTile> {
  final _controller = WebviewController();
  bool _initializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await _controller.initialize();
      if (!mounted) return;
      await _loadUrl();
      if (!mounted) return;
      setState(() => _initializing = false);
    } catch (e) {
      if (mounted) setState(() => _error = 'Web view unavailable: $e');
    }
  }

  Future<void> _loadUrl() async {
    final url = widget.spec.url;
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;
    await _controller.loadUrl(url);
  }

  @override
  void didUpdateWidget(covariant WebTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_initializing && _error == null && oldWidget.spec.url != widget.spec.url) {
      unawaited(_loadUrl());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
            ),
          ),
        ),
      );
    }
    if (_initializing) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (widget.spec.url.isEmpty) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            'No URL set',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 14),
          ),
        ),
      );
    }
    // Some sites block embedding (X-Frame-Options / CSP) — same caveat as the
    // old client's iframe (vs-cfg-hint in app.js); WebView2 will simply show
    // that site's own refusal page in that case, nothing to catch client-side.
    return Webview(_controller);
  }
}
