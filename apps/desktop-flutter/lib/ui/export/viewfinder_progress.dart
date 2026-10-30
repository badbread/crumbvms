// "Viewfinder lock" export progress: a camera-viewfinder frame (corner
// brackets, scanlines, REC dot, timecode) around a 40-tick level meter.
//
// Every number it shows is real: the server's ffmpeg progress (weighted by
// clip length) and clip counter while encoding, a "building zip" phase while
// packaging, and bytes received while saving. Phases without a meaningful
// percentage (submitting, packaging) show "--" and a sweeping tick instead of
// inventing one. On completion the brackets close in to a "lock".
//
// Cheap to keep on screen for a long export: one painter, one animation
// controller that runs only while the export is active (scan band + REC dot),
// and nothing animates under MediaQuery.disableAnimations.

import 'package:flutter/material.dart';

enum ViewfinderPhase {
  submitting,
  encoding,
  packaging,
  saving,
  done,
  failed,
  cancelled,
}

class ViewfinderProgress extends StatefulWidget {
  const ViewfinderProgress({
    super.key,
    required this.phase,
    required this.elapsed,
    this.percent,
    this.detail,
  });

  final ViewfinderPhase phase;

  /// 0-100 for the current phase, or null when there is no honest number.
  final int? percent;

  /// One line under the percentage, e.g. "clip 2 of 4" or "340 of 850 MB".
  final String? detail;
  final Duration elapsed;

  @override
  State<ViewfinderProgress> createState() => _ViewfinderProgressState();
}

class _ViewfinderProgressState extends State<ViewfinderProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  bool get _active => switch (widget.phase) {
    ViewfinderPhase.submitting ||
    ViewfinderPhase.encoding ||
    ViewfinderPhase.packaging ||
    ViewfinderPhase.saving => true,
    _ => false,
  };

  void _syncAnimation() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_active && !reduce) {
      if (!_anim.isAnimating) _anim.repeat();
    } else {
      _anim.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ViewfinderProgress old) {
    super.didUpdateWidget(old);
    _syncAnimation();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  static const _ok = Color(0xFF57C888);
  static const _warn = Color(0xFFE8A33D);
  static const _bad = Color(0xFFE05A5A);

  Color get _accent => switch (widget.phase) {
    ViewfinderPhase.failed => _bad,
    ViewfinderPhase.cancelled => _warn,
    _ => _ok,
  };

  String get _label => switch (widget.phase) {
    ViewfinderPhase.submitting => 'ACQUIRING',
    ViewfinderPhase.encoding => 'EXPORT',
    ViewfinderPhase.packaging => 'PACKAGING',
    ViewfinderPhase.saving => 'SAVING',
    ViewfinderPhase.done => 'SAVED',
    ViewfinderPhase.failed => 'FAILED',
    ViewfinderPhase.cancelled => 'CANCELLED',
  };

  /// A state glyph as text, so the state never relies on colour alone.
  String? get _glyph => switch (widget.phase) {
    ViewfinderPhase.done => 'OK',
    ViewfinderPhase.failed => 'X',
    ViewfinderPhase.cancelled => '||',
    _ => null,
  };

  static String _timecode(Duration d) {
    String p(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h:${p(m)}:${p(s)}' : '${p(m)}:${p(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final pct = widget.percent?.clamp(0, 100);
    final mono = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['monospace'],
      color: Colors.white.withValues(alpha: 0.72),
      fontSize: 11,
      letterSpacing: 0.9,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final locked = widget.phase == ViewfinderPhase.done;
    return Semantics(
      label: 'Export progress',
      value: [
        _label.toLowerCase(),
        if (pct != null) '$pct percent',
        ?widget.detail,
      ].join(', '),
      child: RepaintBoundary(
        child: SizedBox(
          height: 92,
          child: CustomPaint(
            painter: _ViewfinderPainter(
              anim: _anim,
              accent: _accent,
              percent: pct,
              phase: widget.phase,
              // Brackets close in when the export is done.
              inset: locked ? 10 : 4,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (_glyph == null)
                        AnimatedBuilder(
                          animation: _anim,
                          builder: (context, _) {
                            // Breathing REC dot (opacity 1 -> 0.4 -> 1), never
                            // a hard blink.
                            final t = (_anim.value * 2 % 1.0);
                            final a = _active
                                ? 0.4 + 0.6 * (1 - (2 * t - 1).abs())
                                : 1.0;
                            return Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _bad.withValues(alpha: a),
                              ),
                            );
                          },
                        )
                      else
                        Text(
                          _glyph!,
                          style: mono.copyWith(
                            color: _accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      const SizedBox(width: 6),
                      Text(_label, style: mono),
                      const Spacer(),
                      Text(_timecode(widget.elapsed), style: mono),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        pct == null ? '--' : '$pct%',
                        style: mono.copyWith(
                          fontSize: 26,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.detail ?? '',
                          style: mono.copyWith(letterSpacing: 0.2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter({
    required this.anim,
    required this.accent,
    required this.percent,
    required this.phase,
    required this.inset,
  }) : super(repaint: anim);

  final Animation<double> anim;
  final Color accent;
  final int? percent;
  final ViewfinderPhase phase;
  final double inset;

  static const _ticks = 40;

  bool get _active =>
      phase == ViewfinderPhase.submitting ||
      phase == ViewfinderPhase.encoding ||
      phase == ViewfinderPhase.packaging ||
      phase == ViewfinderPhase.saving;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = const Color(0xFF24272E),
    );

    // Scanlines: faint horizontal lines every 3 px.
    final scan = Paint()..color = Colors.black.withValues(alpha: 0.18);
    for (double y = 2; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), scan);
    }

    // Slow scan band drifting down while active.
    if (_active && anim.isAnimating) {
      final y = -18 + (size.height + 18) * anim.value;
      final band = Rect.fromLTWH(0, y, size.width, 18);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              accent.withValues(alpha: 0),
              accent.withValues(alpha: 0.10),
              accent.withValues(alpha: 0),
            ],
          ).createShader(band),
      );
    }

    // Corner brackets.
    final b = Paint()
      ..color = accent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const len = 12.0;
    final l = inset, t = inset;
    final r = size.width - inset, btm = size.height - inset;
    canvas.drawPath(
      Path()
        ..moveTo(l, t + len)
        ..lineTo(l, t)
        ..lineTo(l + len, t)
        ..moveTo(r - len, t)
        ..lineTo(r, t)
        ..lineTo(r, t + len)
        ..moveTo(l, btm - len)
        ..lineTo(l, btm)
        ..lineTo(l + len, btm)
        ..moveTo(r - len, btm)
        ..lineTo(r, btm)
        ..lineTo(r, btm - len),
      b,
    );

    // 40-tick level meter along the bottom.
    const barH = 8.0;
    final barTop = size.height - 18;
    final barLeft = 16.0;
    final barW = size.width - 32;
    const gap = 2.0;
    final tickW = (barW - gap * (_ticks - 1)) / _ticks;
    final filled = percent == null ? 0 : (percent! / 100 * _ticks).round();
    // Unknown percentage (submitting, packaging): one bright tick sweeps.
    final sweep = percent == null && _active
        ? ((1 - (2 * anim.value - 1).abs()) * (_ticks - 1)).round()
        : -1;
    final outline = Paint()
      ..color = accent.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final fill = Paint()..color = accent;
    // Saving fills with a hollow-to-solid look so it reads as a different
    // phase without relying on colour.
    final savingFill = Paint()..color = accent.withValues(alpha: 0.65);
    for (var i = 0; i < _ticks; i++) {
      final x = barLeft + i * (tickW + gap);
      final r = Rect.fromLTWH(x, barTop, tickW, barH);
      if (i < filled) {
        canvas.drawRect(r, phase == ViewfinderPhase.saving ? savingFill : fill);
      } else if (i == sweep) {
        canvas.drawRect(r, fill);
      } else {
        canvas.drawRect(r.deflate(0.5), outline);
      }
    }
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) =>
      old.accent != accent ||
      old.percent != percent ||
      old.phase != phase ||
      old.inset != inset;
}
