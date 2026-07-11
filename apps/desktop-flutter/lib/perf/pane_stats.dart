// Per-pane decode/playback telemetry, read directly off a media_kit
// [NativePlayer]'s libmpv properties.
//
// This is the Flutter analogue of the Tauri `pane_stats` command
// (apps/desktop/src-tauri/src/lib.rs ~869-927): there is no server endpoint
// for this data, it is purely local mpv instance introspection. Where the old
// client polled ALL native panes from one Rust HashMap<paneId, MpvHandle> in a
// single `invoke('pane_stats')`, media_kit gives each tile its own [Player],
// so here we sample one [Player] at a time via `NativePlayer.getProperty`.
//
// Property names and fallbacks are ported 1:1 from the Rust struct so the
// health-classification math in [HudController] stays comparable to the old
// client's thresholds.

import 'package:media_kit/media_kit.dart';

/// One sample of a single pane's mpv decode telemetry.
///
/// `dropCount`/`decDropCount` are CUMULATIVE counters (mirrors the Rust doc
/// comment) — callers derive a per-second rate from deltas between samples,
/// see `HudController._updateDrops`.
class PaneStats {
  const PaneStats({
    required this.width,
    required this.height,
    required this.decodeFps,
    required this.containerFps,
    required this.dropCount,
    required this.decDropCount,
    required this.hwdec,
    required this.videoBitrate,
    required this.cacheSecs,
    required this.avsync,
  });

  final int width;
  final int height;
  final double decodeFps;
  final double containerFps;
  final int dropCount;
  final int decDropCount;

  /// mpv `hwdec-current`: `"cuda"`, `"d3d11va"`, `"no"`, or `""` while loading.
  final String hwdec;
  final double videoBitrate;
  final double cacheSecs;
  final double avsync;

  static const zero = PaneStats(
    width: 0,
    height: 0,
    decodeFps: 0,
    containerFps: 0,
    dropCount: 0,
    decDropCount: 0,
    hwdec: '',
    videoBitrate: 0,
    cacheSecs: 0,
    avsync: 0,
  );

  /// True once mpv has actually decoded a frame or is producing output.
  bool get hasSignal => width > 0 || decodeFps > 0;

  /// True when a real hardware decoder is active (not `""`/`"no"`).
  bool get isHardwareDecoded => hwdec.isNotEmpty && hwdec != 'no';

  double get videoMegabits => videoBitrate / 1e6;

  /// Best-effort read of one mpv double property; `0.0` (never throws) if the
  /// property doesn't exist yet (e.g. pane still connecting).
  static Future<double> _getDouble(NativePlayer p, String name) async {
    try {
      final s = await p.getProperty(name);
      return double.tryParse(s) ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// Best-effort read of one mpv int property, with an optional fallback
  /// property name (mirrors the Rust `geti(...).or_else(...)` chain for
  /// `width`/`height`, which fall back to `video-params/w`/`h` while mpv is
  /// still negotiating decode params).
  static Future<int> _getInt(
    NativePlayer p,
    String name, [
    String? fallback,
  ]) async {
    try {
      final s = await p.getProperty(name);
      final v = int.tryParse(s);
      if (v != null) return v;
    } catch (_) {
      /* fall through to fallback / default */
    }
    if (fallback != null) {
      try {
        final s = await p.getProperty(fallback);
        return int.tryParse(s) ?? 0;
      } catch (_) {
        /* not available yet */
      }
    }
    return 0;
  }

  static Future<String> _getString(NativePlayer p, String name) async {
    try {
      return await p.getProperty(name);
    } catch (_) {
      return '';
    }
  }

  /// Sample one pane's telemetry. Returns [PaneStats.zero] for a non-native
  /// (e.g. web) platform rather than throwing — callers just see "no signal".
  static Future<PaneStats> sample(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return zero;

    // Fire every property read in parallel (10 cheap mpv IPC round-trips per
    // pane per tick) rather than serially awaiting each one.
    final intsF = Future.wait([
      _getInt(platform, 'width', 'video-params/w'),
      _getInt(platform, 'height', 'video-params/h'),
      _getInt(platform, 'frame-drop-count'),
      _getInt(platform, 'decoder-frame-drop-count'),
    ]);
    final doublesF = Future.wait([
      _getDouble(platform, 'estimated-vf-fps'),
      _getDouble(platform, 'container-fps'),
      _getDouble(platform, 'video-bitrate'),
      _getDouble(platform, 'demuxer-cache-duration'),
      _getDouble(platform, 'avsync'),
    ]);
    final hwdecF = _getString(platform, 'hwdec-current');

    final ints = await intsF;
    final doubles = await doublesF;
    final hwdec = await hwdecF;

    return PaneStats(
      width: ints[0],
      height: ints[1],
      decodeFps: doubles[0],
      containerFps: doubles[1],
      dropCount: ints[2],
      decDropCount: ints[3],
      hwdec: hwdec,
      videoBitrate: doubles[2],
      cacheSecs: doubles[3],
      avsync: doubles[4],
    );
  }
}
