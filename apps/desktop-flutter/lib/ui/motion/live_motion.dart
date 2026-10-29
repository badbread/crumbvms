// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Motion for loading and live states:
//
//   * [RecBreath] / [RecDot]: the REC indicator breathes (opacity 1 -> 0.45 ->
//     1 over 2.2 s). ONE shared ticker drives every dot on screen (and runs
//     only while at least one dot is listening); each dot is a FadeTransition
//     in its own RepaintBoundary, so a tick only updates a layer's alpha, with
//     no widget rebuild and no repaint of the video next to it. Reduced motion:
//     a solid dot, no ticker.
//   * [MotionFlash]: when a camera starts reporting motion, its tile border
//     flashes once, "subtle" variant (1.5 px warn-coloured inset line, 1.4 s,
//     decelerate). A painter driven straight by the controller: no rebuilds.
//   * [ShimmerBox]: low-contrast skeleton for thumbnails that are still
//     loading (1.8 s sweep). Static under reduced motion.
//
// None of this touches video content, live values, or alarm state.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import 'crumb_ripple.dart' show isReducedMotionNow;
import 'motion_tokens.dart';

/// The shared REC breathing clock.
class RecBreath extends Animation<double>
    with
        AnimationLazyListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  RecBreath._();

  static final RecBreath instance = RecBreath._();

  /// One full breath (down and back up).
  static const Duration period = Duration(milliseconds: 2200);

  /// The dimmest the dot gets.
  static const double minOpacity = 0.45;

  /// Opacity at [elapsed] since the clock started: 1 -> [minOpacity] -> 1,
  /// eased, repeating every [period]. Pure, for testing.
  static double opacityAt(Duration elapsed) {
    final t =
        (elapsed.inMicroseconds % period.inMicroseconds) /
        period.inMicroseconds;
    final phase = t < 0.5 ? t * 2 : (1 - t) * 2; // 0 -> 1 -> 0
    return 1.0 - (1.0 - minOpacity) * Curves.easeInOut.transform(phase);
  }

  Ticker? _ticker;
  double _value = 1.0;

  @override
  double get value => _value;

  @override
  AnimationStatus get status => AnimationStatus.forward;

  /// Whether the shared ticker is currently running (it only runs while a dot
  /// is listening).
  bool get isTicking => _ticker != null;

  @override
  void didStartListening() {
    _ticker = Ticker(_tick)..start();
  }

  @override
  void didStopListening() {
    _ticker?.dispose();
    _ticker = null;
    _value = 1.0;
  }

  void _tick(Duration elapsed) {
    final v = opacityAt(elapsed);
    // ~0.4% steps are invisible; skip the notification.
    if ((v - _value).abs() < 0.004) return;
    _value = v;
    notifyListeners();
  }
}

/// The REC dot. Breathes via [RecBreath]; solid under reduced motion.
class RecDot extends StatelessWidget {
  const RecDot({super.key, this.color = Colors.redAccent, this.size = 7});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
    if (MotionTokens.reduced(context)) return dot;
    return RepaintBoundary(
      child: FadeTransition(opacity: RecBreath.instance, child: dot),
    );
  }
}

/// Envelope of the border flash at [t] in 0..1: quick rise over the first 12%,
/// then a long decelerating fade. Pure, for testing.
double motionFlashAlpha(double t) {
  if (t <= 0 || t >= 1) return 0;
  const rise = 0.12;
  if (t < rise) return MotionTokens.decelerate.transform(t / rise);
  return 1.0 - MotionTokens.decelerate.transform((t - rise) / (1 - rise));
}

/// Flashes a thin warn-coloured border over its tile whenever [active] goes
/// false -> true (a new motion event). Does not flash for a tile that is
/// already in motion when it mounts.
class MotionFlash extends StatefulWidget {
  const MotionFlash({super.key, required this.active});

  final bool active;

  static const Duration duration = Duration(milliseconds: 1400);

  /// Under reduced motion the flash is a plain, shorter fade.
  static const Duration reducedDuration = Duration(milliseconds: 600);

  static const Color color = Color(0xFFE8A33D);

  @override
  State<MotionFlash> createState() => _MotionFlashState();
}

class _MotionFlashState extends State<MotionFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didUpdateWidget(MotionFlash old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _c.duration = isReducedMotionNow()
          ? MotionFlash.reducedDuration
          : MotionFlash.duration;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _FlashPainter(_c),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _FlashPainter extends CustomPainter {
  _FlashPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final a = motionFlashAlpha(animation.value);
    if (a <= 0) return;
    canvas.drawRect(
      (Offset.zero & size).deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = MotionFlash.color.withValues(alpha: a),
    );
  }

  @override
  bool shouldRepaint(_FlashPainter old) => old.animation != animation;
}

/// A low-contrast loading placeholder with a slow highlight sweep (1.8 s).
/// Static (no sweep, no ticker) under reduced motion.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.child,
    this.base = const Color(0xFF1B1D22),
  });

  final Widget? child;
  final Color base;

  static const Duration period = Duration(milliseconds: 1800);

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MotionTokens.reduced(context);
    if (reduced) {
      _c?.dispose();
      _c = null;
    } else {
      _c ??= AnimationController(vsync: this, duration: ShimmerBox.period)
        ..repeat();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ShimmerPainter(widget.base, c),
        child: widget.child ?? const SizedBox.expand(),
      ),
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter(this.base, this.animation) : super(repaint: animation);

  final Color base;
  final Animation<double>? animation;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = base);
    final anim = animation;
    if (anim == null || size.isEmpty) return;
    // A soft ~40%-wide band sweeping left to right, white at ~4% alpha.
    final eased = Curves.easeInOut.transform(anim.value);
    final band = size.width * 0.4;
    final x = -band + (size.width + band) * eased;
    final r = Rect.fromLTWH(x, 0, band, size.height);
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0x00FFFFFF),
            const Color(0x0AFFFFFF),
            const Color(0x00FFFFFF),
          ],
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) =>
      old.base != base || old.animation != animation;
}

/// `Image.frameBuilder` for still thumbnails: the decoded image fades in over
/// its skeleton (150 ms, decelerate; <= 100 ms under reduced motion) instead
/// of popping. An image that was already decoded (cache hit) shows at once.
Widget thumbFadeFrameBuilder(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: MotionTokens.scaled(
      MotionTokens.d2,
      reduced: MotionTokens.reduced(context),
    ),
    curve: MotionTokens.decelerate,
    child: child,
  );
}
