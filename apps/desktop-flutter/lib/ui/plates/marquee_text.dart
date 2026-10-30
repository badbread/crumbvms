// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A one-line label that scrolls only when it does not fit: a measured, eased
// ping-pong with a hold at each end and soft fade masks, so a long operator
// name on a plate card stays readable without anything else on the card
// moving. When the text fits, or the platform asks for reduced motion
// (MediaQuery.disableAnimations), it is a plain ellipsised Text and nothing
// animates.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Overflow (px) below which the text is treated as fitting.
const double kMarqueeSlop = 2;

/// Extra travel past the exact overflow so the last glyph clears the mask.
const double _kTail = 6;

/// Fraction of each leg held still at either end (the mockup's 18%).
const double _kHold = 0.18;

/// Fade widths at the leading and trailing edge while scrolling.
const double _kFadeIn = 10;
const double _kFadeOut = 14;

/// The eased ping-pong progress (0..1) for controller value [t] (0..1): hold
/// at the start, eased travel, hold at the end.
@visibleForTesting
double marqueeProgress(double t) {
  if (t <= _kHold) return 0;
  if (t >= 1 - _kHold) return 1;
  final x = (t - _kHold) / (1 - 2 * _kHold);
  return const Cubic(0.45, 0.05, 0.55, 0.95).transform(x);
}

/// One leg's duration for an overflow of [dist] px: slow enough to read.
@visibleForTesting
Duration marqueeLegDuration(double dist) {
  final secs = (dist / 28 + 2.5).clamp(4.0, 12.0);
  return Duration(milliseconds: (secs * 1000).round());
}

/// The natural (unconstrained) one-line size of [text] in [style].
Size marqueeTextSize(BuildContext context, String text, TextStyle style) {
  final tp = TextPainter(
    // Merge with the ambient style, exactly as a Text widget does, so the
    // measured width is the rendered width.
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final size = tp.size;
  tp.dispose();
  return size;
}

/// The natural width of [text] in [style].
double marqueeTextWidth(BuildContext context, String text, TextStyle style) =>
    marqueeTextSize(context, text, style).width;

class MarqueeText extends StatelessWidget {
  const MarqueeText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return LayoutBuilder(
      builder: (context, c) {
        Widget plain() => Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
        if (reduce || !c.hasBoundedWidth) return plain();
        final size = marqueeTextSize(context, text, style);
        final dist = size.width - c.maxWidth;
        if (dist <= kMarqueeSlop) return plain();
        return _ScrollingText(
          // A new text or distance restarts the loop from the left.
          key: ValueKey('$text|${dist.round()}'),
          text: text,
          style: style,
          width: c.maxWidth,
          height: size.height,
          dist: dist + _kTail,
        );
      },
    );
  }
}

class _ScrollingText extends StatefulWidget {
  const _ScrollingText({
    super.key,
    required this.text,
    required this.style,
    required this.width,
    required this.height,
    required this.dist,
  });

  final String text;
  final TextStyle style;
  final double width;
  final double height;
  final double dist;

  @override
  State<_ScrollingText> createState() => _ScrollingTextState();
}

class _ScrollingTextState extends State<_ScrollingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: marqueeLegDuration(widget.dist),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    final fadeIn = math.min(_kFadeIn, w / 3) / w;
    final fadeOut = math.min(_kFadeOut, w / 3) / w;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => LinearGradient(
        colors: const [
          Color(0x00000000),
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [0, fadeIn, 1 - fadeOut, 1],
      ).createShader(r),
      child: ClipRect(
        child: SizedBox(
          width: w,
          height: widget.height,
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: AnimatedBuilder(
              animation: _ctl,
              builder: (context, child) => Transform.translate(
                offset: Offset(-widget.dist * marqueeProgress(_ctl.value), 0),
                child: child,
              ),
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: widget.style,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
