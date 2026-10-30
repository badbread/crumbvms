// Remembers the main window's size, position and maximized state across
// launches (it always opened at the native runner's 1280x720 near the top
// left). Fullscreen is not remembered here: that's the separate "launch into
// fullscreen camera wall" option (lib/ui/fullscreen/launch_fullscreen_option.dart).
//
// Saved on every move/resize (debounced) while the window is in its normal
// state, and on maximize/unmaximize. Restored in two steps at launch: the
// normal bounds before the window is first shown (no visible jump), and the
// maximized state right after the first frame, because maximizing a window
// before Flutter has painted shows it early and blank on Windows (same issue
// the fullscreen launch path works around).

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const _kBounds = 'crumb.window.bounds'; // "x,y,w,h" in logical pixels
const _kMaximized = 'crumb.window.maximized';

/// The smallest window we'll restore; anything smaller is treated as junk.
const Size _kMinRestore = Size(480, 320);

/// Serialized form of the window's normal bounds.
@visibleForTesting
String encodeBounds(Rect r) =>
    '${r.left.round()},${r.top.round()},${r.width.round()},${r.height.round()}';

/// Parses [encodeBounds] output; null for anything malformed or too small.
@visibleForTesting
Rect? decodeBounds(String? s) {
  if (s == null) return null;
  final p = s.split(',').map(double.tryParse).toList();
  if (p.length != 4 || p.any((v) => v == null)) return null;
  final r = Rect.fromLTWH(p[0]!, p[1]!, p[2]!, p[3]!);
  if (r.width < _kMinRestore.width || r.height < _kMinRestore.height) {
    return null;
  }
  return r;
}

class WindowStateStore with WindowListener {
  WindowStateStore._();
  static final WindowStateStore instance = WindowStateStore._();

  SharedPreferences? _prefs;
  Timer? _debounce;
  bool _wantMaximized = false;

  /// Call once after `windowManager.ensureInitialized()` and before `runApp`.
  Future<void> restoreAndAttach() async {
    if (!Platform.isWindows) return;
    try {
      _prefs = await SharedPreferences.getInstance();
      final bounds = decodeBounds(_prefs!.getString(_kBounds));
      if (bounds != null && _onSomeMonitor(bounds)) {
        await windowManager.setBounds(bounds);
      }
      _wantMaximized = _prefs!.getBool(_kMaximized) ?? false;
    } catch (_) {
      /* best-effort: a bad or missing saved state just means default size */
    }
    windowManager.addListener(this);
    if (_wantMaximized) {
      unawaited(() async {
        await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
        try {
          await windowManager.maximize();
        } catch (_) {
          /* best-effort */
        }
      }());
    }
  }

  void _saveBoundsSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        if (await windowManager.isMaximized() ||
            await windowManager.isMinimized() ||
            await windowManager.isFullScreen()) {
          return; // keep the last NORMAL bounds for restoring later
        }
        final b = await windowManager.getBounds();
        await _prefs?.setString(_kBounds, encodeBounds(b));
      } catch (_) {
        /* best-effort */
      }
    });
  }

  @override
  void onWindowResized() => _saveBoundsSoon();

  @override
  void onWindowMoved() => _saveBoundsSoon();

  @override
  void onWindowMaximize() {
    unawaited(_prefs?.setBool(_kMaximized, true));
  }

  @override
  void onWindowUnmaximize() {
    unawaited(_prefs?.setBool(_kMaximized, false));
    _saveBoundsSoon();
  }
}

// ── off-screen guard ─────────────────────────────────────────────────────────
// A window saved on a monitor that's since been unplugged would reopen
// invisible. Ask Windows whether the title bar area lies on any monitor.

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

typedef _MonitorFromPointNative = IntPtr Function(_Point pt, Uint32 flags);
typedef _MonitorFromPointDart = int Function(_Point pt, int flags);

bool _onSomeMonitor(Rect logical) {
  try {
    final fn = DynamicLibrary.open('user32.dll')
        .lookupFunction<_MonitorFromPointNative, _MonitorFromPointDart>(
          'MonitorFromPoint',
        );
    // Saved bounds are logical pixels; MonitorFromPoint takes physical ones.
    // Try the primary display's scale and 1x, so a window on a monitor with
    // a different scale isn't wrongly rejected.
    final displays = PlatformDispatcher.instance.displays;
    final dpr = displays.isEmpty ? 1.0 : displays.first.devicePixelRatio;
    for (final scale in {dpr, 1.0}) {
      final pt = Struct.create<_Point>()
        ..x = ((logical.left + logical.width / 2) * scale).round()
        ..y = ((logical.top + 16) * scale).round();
      const monitorDefaultToNull = 0;
      if (fn(pt, monitorDefaultToNull) != 0) return true;
    }
    return false;
  } catch (_) {
    return true; // can't check: trust the saved bounds
  }
}
