// In-app diagnostics (issue #180): a bounded, always-on capture of the
// client's warnings/errors plus an opt-in verbose trace (HTTP, player logs),
// exportable as a scrubbed text file a tester can hand to the maintainer.
//
// Design constraints, in order:
//  1. SCRUB EVERYTHING SENSITIVE. Bearer/JWT/media tokens, `?token=` query
//     params, and password/token JSON fields are redacted AT CAPTURE TIME —
//     nothing token-shaped is ever even held in the buffer, so no later
//     export path can leak what was never stored. Server identity is recorded
//     as host:port only, never the full base URL with credentials-bearing
//     paths. (A leaky "share my logs" button would be worse than none.)
//  2. Bounded by construction: a fixed-capacity ring buffer with a per-line
//     length cap. Verbose mode is safe to leave on indefinitely — it can't
//     grow memory or disk (nothing is written to disk until an export).
//  3. Zero cost when quiet: normal (non-verbose) capture only records
//     warnings, errors, and a handful of lifecycle breadcrumbs.
//
// Singleton (mirrors `SnapshotRegistry.instance`) so the HTTP layer, player
// hooks, and error handlers can log without threading a reference through
// every constructor in the app.

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kVerboseKey = 'crumb.verboseLogging';

/// Ring capacity (records) and per-message length cap. ~4k trimmed lines is
/// hours of verbose capture and well under a megabyte of memory.
const int _kCapacity = 4000;
const int _kMaxMsgLen = 2000;

class _Rec {
  _Rec(this.ts, this.level, this.tag, this.msg);
  final DateTime ts;
  final String level; // 'error' | 'warn' | 'info' | 'debug'
  final String tag;
  final String msg;
}

class DiagnosticsService extends ChangeNotifier {
  DiagnosticsService._();

  static final DiagnosticsService instance = DiagnosticsService._();

  final ListQueue<_Rec> _buf = ListQueue<_Rec>();
  SharedPreferences? _prefs;
  String? _appVersion; // "1.2.3+45" once resolved
  String? _serverHost; // host:port only — never the full base URL

  /// Verbose capture on/off (persisted; off by default). Off = only
  /// warnings/errors/lifecycle are kept; on = HTTP traces + player logs too.
  bool get verbose => _verbose;
  bool _verbose = false;
  set verbose(bool v) {
    if (v == _verbose) return;
    _verbose = v;
    // Bracket the change in the log itself so an exported file shows exactly
    // which stretch was captured verbose.
    log('diag', 'verbose logging ${v ? 'enabled' : 'disabled'}');
    _prefs?.setBool(_kVerboseKey, v);
    notifyListeners();
  }

  /// Buffered record count (drives the pane's "N lines captured" hint).
  int get length => _buf.length;

  /// Load the persisted verbose flag + resolve the app version. Best-effort:
  /// diagnostics must never be the thing that breaks startup.
  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _verbose = _prefs?.getBool(_kVerboseKey) ?? false;
    } catch (_) {
      /* plugin unavailable — session-only toggle */
    }
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.buildNumber.isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';
    } catch (_) {
      /* dev build — version stays unknown */
    }
    log('diag', 'diagnostics started (app ${_appVersion ?? 'dev'})');
  }

  /// Record the connected server as HOST:PORT only (from `Session.base`).
  /// Called on login/restore; deliberately never stores the full URL.
  void setServerBase(String base) {
    _serverHost = Uri.tryParse(base)?.authority ?? '(unparsed)';
    log('session', 'connected to $_serverHost');
  }

  /// Append one record. `debug` is kept only in verbose mode; `info` and up
  /// always. Message is scrubbed and length-capped before storage.
  void log(String tag, String message, {String level = 'info'}) {
    if (level == 'debug' && !_verbose) return;
    var msg = scrub(message);
    if (msg.length > _kMaxMsgLen) msg = '${msg.substring(0, _kMaxMsgLen)}…';
    _buf.addLast(_Rec(DateTime.now().toUtc(), level, tag, msg));
    while (_buf.length > _kCapacity) {
      _buf.removeFirst();
    }
  }

  /// HTTP trace hook for [TimeoutClient]: failures always captured, routine
  /// traffic only in verbose. `path` must be a bare path — callers never pass
  /// the query string (it can carry `?token=`).
  void httpTrace(String method, String path, int? status, int ms) {
    final failed = status == null || status >= 400;
    if (!failed && !_verbose) return;
    log(
      'http',
      '$method $path → ${status ?? 'timeout/error'} (${ms}ms)',
      level: failed ? 'warn' : 'debug',
    );
  }

  /// Wire a media_kit [player]'s error/log streams into the buffer. Errors
  /// always; mpv's own log lines only in verbose (they're chatty). The
  /// subscriptions die with the player's streams on dispose — fire-and-forget.
  ///
  /// mpv/ffmpeg error and log text routinely echoes back the full URL it was
  /// opening (a go2rtc/RTSP restream, possibly `user:pass@`-embedded) — [log]
  /// already runs every message through [scrub], but these two call sites
  /// pre-scrub the raw text too, belt-and-suspenders, since it's the one place
  /// credential-bearing URLs are most likely to appear verbatim.
  void attachPlayer(String tag, Player player) {
    player.stream.error.listen(
      (e) => log('player:$tag', scrub(e), level: 'warn'),
      onError: (_) {},
    );
    player.stream.log.listen(
      (l) {
        if (!_verbose) return;
        log(
          'player:$tag',
          scrub('[${l.level}] ${l.prefix}: ${l.text}'),
          level: 'debug',
        );
      },
      onError: (_) {},
    );
  }

  /// Redact anything secret-shaped. Applied at capture; applied again over
  /// the assembled export as a belt-and-suspenders pass (headers included).
  static String scrub(String s) {
    var out = s;
    // JWT-shaped triplets (session bearer tokens, media claims).
    out = out.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}'),
      '[REDACTED-JWT]',
    );
    // Authorization header values.
    out = out.replaceAll(
      RegExp('Bearer [A-Za-z0-9._~+/=-]+'),
      'Bearer [REDACTED]',
    );
    // token/password/secret-ish query params or key=value fragments.
    out = out.replaceAllMapped(
      RegExp(
        r'''(token|password|secret|api_key|apikey)=[^&\s"']+''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}=[REDACTED]',
    );
    // JSON fields: "password": "...", "token": "...", "secret": "..."
    out = out.replaceAllMapped(
      RegExp(
        r'"(password|token|secret|api_key)"\s*:\s*"[^"]*"',
        caseSensitive: false,
      ),
      (m) => '"${m[1]}":"[REDACTED]"',
    );
    // URL userinfo (`scheme://user:pass@host`) — go2rtc/RTSP restream URLs can
    // embed basic-auth-style credentials, and mpv/ffmpeg error + log lines
    // routinely echo back the full URL being opened. Strip the userinfo
    // regardless of scheme so a restream credential never survives into an
    // exported diagnostics file.
    // Case-insensitive so `RTSP://`/`HTTP://` are covered, and the userinfo is
    // matched GREEDILY up to the LAST `@` before the path — so a password that
    // itself contains `@` (e.g. `user:p@ss@host`) is fully redacted rather than
    // leaving the trailing `ss@` exposed. `[^/\s]+` stops at the first `/`, so a
    // later `@` in the path/query (`?email=a@b`) is never mis-swallowed.
    out = out.replaceAllMapped(
      RegExp(r'([a-z][a-z0-9+.-]*://)[^/\s]+@', caseSensitive: false),
      (m) => '${m[1]}[REDACTED]@',
    );
    return out;
  }

  /// Assemble the scrubbed export text: environment header + buffered lines.
  String buildExport() {
    final b = StringBuffer()
      ..writeln('CrumbVMS desktop diagnostics')
      ..writeln('exported: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('app: ${_appVersion ?? 'unknown (dev build)'}')
      ..writeln(
        'os: ${defaultTargetPlatform.name} '
        '(debug=${kDebugMode ? 'yes' : 'no'})',
      )
      ..writeln('server: ${_serverHost ?? '(not connected)'}')
      ..writeln('verbose: ${_verbose ? 'on' : 'off'}')
      ..writeln('lines: ${_buf.length} (cap $_kCapacity)')
      ..writeln('---');
    for (final r in _buf) {
      b.writeln(
        '${r.ts.toIso8601String()} ${r.level.padRight(5)} '
        '[${r.tag}] ${r.msg}',
      );
    }
    // Second scrub pass over the whole assembly — catches anything a header
    // or a future field addition might have carried through.
    return scrub(b.toString());
  }
}
