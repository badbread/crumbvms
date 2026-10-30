// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Crumb's own transport for a short clip: a scrub bar (app accent, hover time
// preview, optional "moment of interest" tick), play/pause, restart, short
// jumps, frame-exact stepping, a speed menu (0.25x to 4x), loop, mute, the
// clip time and the wall-clock time of day at the playhead, and an optional
// full-screen button.
//
// Shared by the plates tab's pop-up clip player and the plate profile's inline
// hero player, so both show the same controls. The widgets only talk to a
// [ClipTransport], an abstraction over the player: [MediaKitClipTransport]
// drives a real media_kit [Player]; tests drive a fake, so the control logic is
// testable without libmpv.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// Playback speeds offered by the speed menu.
const List<double> kClipSpeeds = [0.25, 0.5, 1, 2, 4];

/// Length of the short skip buttons and of the Left / Right keys' skip.
const Duration kClipJump = Duration(seconds: 5);
const Duration kClipKeyJump = Duration(seconds: 1);

/// Height of [ClipControls] (scrub bar + button row), for callers that budget
/// layout around it.
const double kClipControlsHeight = 68;

// ── formatting ────────────────────────────────────────────────────────────

/// `m:ss` (or `h:mm:ss` from an hour up) for a clip-relative time.
String formatClipTime(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Time of day in the viewer's local zone, e.g. `5:36:21 PM`.
String formatWallClock(DateTime t) {
  final l = t.toLocal();
  final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final mm = l.minute.toString().padLeft(2, '0');
  final ss = l.second.toString().padLeft(2, '0');
  return '$h12:$mm:$ss ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// `0.25x`, `0.5x`, `1x`, `2x`, `4x`.
String formatClipSpeed(double v) =>
    '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v}x';

/// Maps a horizontal position on the scrub bar to a clip time.
Duration scrubFractionToDuration(double fraction, Duration total) {
  final f = fraction.clamp(0.0, 1.0);
  return Duration(microseconds: (total.inMicroseconds * f).round());
}

// ── transport abstraction ─────────────────────────────────────────────────

/// What the controls need from a player. Notifies on any state change.
abstract class ClipTransport extends ChangeNotifier {
  Duration get position;
  Duration get duration;
  bool get playing;
  double get rate;
  bool get muted;
  bool get loop;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);

  /// Frame-exact single step (pauses first).
  Future<void> stepFrame(bool forward);
  Future<void> setRate(double rate);
  Future<void> setMuted(bool muted);
  Future<void> setLoop(bool loop);

  Future<void> togglePlay() async {
    if (playing) return pause();
    // A finished clip is parked on its last frame; play from the start.
    if (duration > Duration.zero &&
        position >= duration - const Duration(milliseconds: 80)) {
      await seek(Duration.zero);
    }
    return play();
  }

  Future<void> restart() async {
    await seek(Duration.zero);
    await play();
  }

  /// Relative skip, clamped to the clip.
  Future<void> jump(Duration by) async {
    var to = position + by;
    if (to < Duration.zero) to = Duration.zero;
    if (duration > Duration.zero && to > duration) to = duration;
    await seek(to);
  }
}

/// [ClipTransport] over a media_kit [Player].
class MediaKitClipTransport extends ClipTransport {
  MediaKitClipTransport(this.player, {bool muted = false}) {
    _muted = muted;
    final s = player.stream;
    _subs = [
      s.position.listen((v) {
        _position = v;
        _poke();
      }),
      s.duration.listen((v) {
        _duration = v;
        _poke();
      }),
      s.playing.listen((v) {
        _playing = v;
        _poke();
      }),
      s.rate.listen((v) {
        _rate = v;
        _poke();
      }),
    ];
    final st = player.state;
    _position = st.position;
    _duration = st.duration;
    _playing = st.playing;
    _rate = st.rate;
  }

  final Player player;
  late final List<StreamSubscription<dynamic>> _subs;
  bool _disposed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _rate = 1;
  bool _muted = false;
  bool _loop = false;

  void _poke() {
    if (!_disposed) notifyListeners();
  }

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get playing => _playing;
  @override
  double get rate => _rate;
  @override
  bool get muted => _muted;
  @override
  bool get loop => _loop;

  /// Applies the initial mute state; call once after the player exists.
  Future<void> applyInitialMute() => player.setVolume(_muted ? 0 : 100);

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seek(Duration to) async {
    _position = to;
    _poke();
    await player.seek(to);
  }

  /// Frame-exact step via libmpv's `frame-step` / `frame-back-step`. Do NOT
  /// replace with a position +/- 1000/fps seek: mpv resolves a backward seek to
  /// the nearest keyframe, so the back-step would appear dead (#390).
  @override
  Future<void> stepFrame(bool forward) async {
    await player.pause();
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.command([forward ? 'frame-step' : 'frame-back-step']);
        return;
      }
      const frame = Duration(milliseconds: 33);
      var target = forward ? _position + frame : _position - frame;
      if (target < Duration.zero) target = Duration.zero;
      await player.seek(target);
    } catch (_) {
      // A disposed player must not throw out of a tap handler.
    }
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    _poke();
    await player.setRate(rate);
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    _poke();
    await player.setVolume(muted ? 0 : 100);
  }

  @override
  Future<void> setLoop(bool loop) async {
    _loop = loop;
    _poke();
    await player.setPlaylistMode(loop ? PlaylistMode.single : PlaylistMode.none);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

// ── keyboard ──────────────────────────────────────────────────────────────

/// Shared clip shortcuts: Space play/pause, Left / Right skip 1 s, `,` and `.`
/// step one frame back / forward, and `B` bookmarks the playhead when
/// [onBookmark] is given. Returns true when the key was consumed.
/// Callers are responsible for the context gate (`hotkeyContextBlocked`).
bool handleClipTransportKey(
  KeyEvent event,
  ClipTransport t, {
  VoidCallback? onBookmark,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
  final keys = HardwareKeyboard.instance;
  if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
    return false;
  }
  final k = event.logicalKey;
  if (k == LogicalKeyboardKey.space) {
    if (event is! KeyDownEvent) return true;
    unawaited(t.togglePlay());
    return true;
  }
  if (k == LogicalKeyboardKey.arrowLeft) {
    unawaited(t.jump(-kClipKeyJump));
    return true;
  }
  if (k == LogicalKeyboardKey.arrowRight) {
    unawaited(t.jump(kClipKeyJump));
    return true;
  }
  if (k == LogicalKeyboardKey.comma) {
    unawaited(t.stepFrame(false));
    return true;
  }
  if (k == LogicalKeyboardKey.period) {
    unawaited(t.stepFrame(true));
    return true;
  }
  if (k == LogicalKeyboardKey.keyB && onBookmark != null) {
    if (event is KeyDownEvent) onBookmark();
    return true;
  }
  return false;
}

// ── widgets ───────────────────────────────────────────────────────────────

/// The full control cluster: scrub bar over a button row.
class ClipControls extends StatelessWidget {
  const ClipControls({
    super.key,
    required this.transport,
    this.wallStart,
    this.markAt,
    this.onFullscreen,
    this.onBookmark,
  });

  final ClipTransport transport;

  /// Wall-clock time of clip position zero. Null hides the time-of-day.
  final DateTime? wallStart;

  /// Clip position to flag on the scrub bar (e.g. the plate read).
  final Duration? markAt;

  /// Shows a full-screen button when set.
  final VoidCallback? onFullscreen;

  /// Shows a bookmark button when set and [wallStart] is known; called with the
  /// wall-clock time at the playhead.
  final ValueChanged<DateTime>? onBookmark;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    // The buttons must never take keyboard focus: Space would otherwise both
    // trigger the focused button and the clip shortcut.
    return ExcludeFocus(
      child: ListenableBuilder(
        listenable: transport,
        builder: (context, _) {
          final t = transport;
          Widget btn(
            IconData icon,
            String tip,
            VoidCallback onTap, {
            Color? color,
            double size = 20,
            Key? key,
          }) => IconButton(
            key: key,
            tooltip: tip,
            onPressed: onTap,
            icon: Icon(icon, size: size, color: color ?? Colors.white70),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(5),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          );
          final wall = wallStart;
          return SizedBox(
            height: kClipControlsHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ClipScrubBar(
                    key: const ValueKey('clip-scrub'),
                    position: t.position,
                    duration: t.duration,
                    markAt: markAt,
                    wallStart: wall,
                    onSeek: (d) => unawaited(t.seek(d)),
                  ),
                  SizedBox(
                    height: 36,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          btn(
                            t.playing ? Icons.pause : Icons.play_arrow,
                            t.playing ? 'Pause (Space)' : 'Play (Space)',
                            () => unawaited(t.togglePlay()),
                            color: Colors.white,
                            size: 24,
                            key: const ValueKey('clip-play'),
                          ),
                          btn(
                            Icons.replay,
                            'Restart',
                            () => unawaited(t.restart()),
                            key: const ValueKey('clip-restart'),
                          ),
                          btn(
                            Icons.replay_5,
                            'Back 5 s',
                            () => unawaited(t.jump(-kClipJump)),
                            key: const ValueKey('clip-back5'),
                          ),
                          btn(
                            Icons.navigate_before,
                            'Back one frame (,)',
                            () => unawaited(t.stepFrame(false)),
                            size: 24,
                            key: const ValueKey('clip-frame-back'),
                          ),
                          btn(
                            Icons.navigate_next,
                            'Forward one frame (.)',
                            () => unawaited(t.stepFrame(true)),
                            size: 24,
                            key: const ValueKey('clip-frame-fwd'),
                          ),
                          btn(
                            Icons.forward_5,
                            'Forward 5 s',
                            () => unawaited(t.jump(kClipJump)),
                            key: const ValueKey('clip-fwd5'),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${formatClipTime(t.position)} / '
                            '${formatClipTime(t.duration)}',
                            key: const ValueKey('clip-time'),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          if (wall != null) ...[
                            const SizedBox(width: 10),
                            Text(
                              formatWallClock(wall.add(t.position)),
                              key: const ValueKey('clip-wall'),
                              style: TextStyle(
                                color: accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(width: 10),
                          _SpeedMenu(transport: t, accent: accent),
                          btn(
                            Icons.repeat,
                            t.loop ? 'Loop: on' : 'Loop: off',
                            () => unawaited(t.setLoop(!t.loop)),
                            color: t.loop ? accent : Colors.white54,
                            key: const ValueKey('clip-loop'),
                          ),
                          btn(
                            t.muted ? Icons.volume_off : Icons.volume_up,
                            t.muted ? 'Unmute' : 'Mute',
                            () => unawaited(t.setMuted(!t.muted)),
                            key: const ValueKey('clip-mute'),
                          ),
                          if (onBookmark != null && wall != null)
                            btn(
                              Icons.bookmark_add_outlined,
                              'Bookmark this moment (B)',
                              () => onBookmark!(wall.add(t.position)),
                              key: const ValueKey('clip-bookmark'),
                            ),
                          if (onFullscreen != null)
                            btn(
                              Icons.fullscreen,
                              'Full screen',
                              onFullscreen!,
                              size: 24,
                              key: const ValueKey('clip-fullscreen'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SpeedMenu extends StatelessWidget {
  const _SpeedMenu({required this.transport, required this.accent});

  final ClipTransport transport;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      key: const ValueKey('clip-speed'),
      tooltip: 'Playback speed',
      initialValue: transport.rate,
      color: const Color(0xFF26272D),
      onSelected: (v) => unawaited(transport.setRate(v)),
      itemBuilder: (_) => [
        for (final s in kClipSpeeds)
          PopupMenuItem<double>(
            value: s,
            height: 34,
            child: Text(
              formatClipSpeed(s),
              style: TextStyle(
                color: s == transport.rate ? accent : Colors.white,
                fontWeight: s == transport.rate
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: accent.withValues(alpha: 0.38)),
        ),
        child: Text(
          formatClipSpeed(transport.rate),
          style: TextStyle(
            color: accent,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Click / drag seek bar in the app accent, with a hover time preview.
class ClipScrubBar extends StatefulWidget {
  const ClipScrubBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.markAt,
    this.wallStart,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final Duration? markAt;
  final DateTime? wallStart;

  @override
  State<ClipScrubBar> createState() => _ClipScrubBarState();
}

class _ClipScrubBarState extends State<ClipScrubBar> {
  double? _hover; // 0..1
  double? _drag; // 0..1 while dragging
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  double _frac(double dx, double w) => w <= 0 ? 0 : (dx / w).clamp(0.0, 1.0);

  void _seekTo(double f, {bool force = false}) {
    if (widget.duration <= Duration.zero) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSeek).inMilliseconds < 60) return;
    _lastSeek = now;
    widget.onSeek(scrubFractionToDuration(f, widget.duration));
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final total = widget.duration.inMicroseconds;
    final playFrac = total <= 0
        ? 0.0
        : (widget.position.inMicroseconds / total).clamp(0.0, 1.0);
    final shown = _drag ?? playFrac;
    final markFrac = (widget.markAt == null || total <= 0)
        ? null
        : (widget.markAt!.inMicroseconds / total).clamp(0.0, 1.0);
    return SizedBox(
      height: 26,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final hover = _hover;
          Widget? tip;
          if (hover != null && total > 0) {
            final at = scrubFractionToDuration(hover, widget.duration);
            final ws = widget.wallStart;
            final text = ws == null
                ? formatClipTime(at)
                : '${formatClipTime(at)}  ${formatWallClock(ws.add(at))}';
            tip = Positioned(
              left: (hover * w - 60).clamp(0.0, (w - 120).clamp(0.0, w)),
              top: -22,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('clip-scrub-tip'),
                  width: 120,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xE6101114),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            );
          }
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onHover: (e) => setState(() => _hover = _frac(e.localPosition.dx, w)),
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _seekTo(_frac(d.localPosition.dx, w), force: true),
              onHorizontalDragStart: (d) {
                setState(() => _drag = _frac(d.localPosition.dx, w));
              },
              onHorizontalDragUpdate: (d) {
                final f = _frac(d.localPosition.dx, w);
                setState(() {
                  _drag = f;
                  _hover = f;
                });
                _seekTo(f);
              },
              onHorizontalDragEnd: (_) {
                final f = _drag;
                setState(() => _drag = null);
                if (f != null) _seekTo(f, force: true);
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ScrubPainter(
                        played: shown,
                        mark: markFrac,
                        accent: accent,
                        thick: hover != null || _drag != null,
                      ),
                    ),
                  ),
                  ?tip,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ScrubPainter extends CustomPainter {
  _ScrubPainter({
    required this.played,
    required this.mark,
    required this.accent,
    required this.thick,
  });

  final double played;
  final double? mark;
  final Color accent;
  final bool thick;

  @override
  void paint(Canvas canvas, Size size) {
    final h = thick ? 6.0 : 4.0;
    final y = size.height / 2;
    final track = RRect.fromLTRBR(0, y - h / 2, size.width, y + h / 2, Radius.circular(h / 2));
    canvas.drawRRect(track, Paint()..color = Colors.white24);
    final px = size.width * played;
    if (px > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, y - h / 2, px, y + h / 2, Radius.circular(h / 2)),
        Paint()..color = accent,
      );
    }
    if (mark != null) {
      final mx = size.width * mark!;
      canvas.drawRect(
        Rect.fromLTWH(mx - 1, y - 7, 2, 14),
        Paint()..color = Colors.white70,
      );
    }
    canvas.drawCircle(Offset(px, y), thick ? 7 : 5, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_ScrubPainter o) =>
      o.played != played ||
      o.mark != mark ||
      o.accent != accent ||
      o.thick != thick;
}
