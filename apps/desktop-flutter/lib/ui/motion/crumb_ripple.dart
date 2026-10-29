// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The app-wide press ripple (the approved "Ripple" press variant): a restrained
// white circle that grows from the press point and fades out, clipped to the
// control by the InkWell that hosts it. 420 ms on the standard curve, peak
// alpha ~15%, capped radius so a wide button doesn't flood.
//
// Installed once via ThemeData.splashFactory (see [applyCrumbInteraction]), so
// every InkWell / button / chip / list tile picks it up without call-site
// edits. Under reduced motion the circle does not travel: the whole control
// gets a brief (<=100 ms) fading wash instead.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion_tokens.dart';

class _CrumbRippleFactory extends InteractiveInkFeatureFactory {
  const _CrumbRippleFactory();

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    return CrumbRipple(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      textDirection: textDirection,
      containedInkWell: containedInkWell,
      rectCallback: rectCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
    );
  }
}

class CrumbRipple extends InteractiveInkFeature {
  CrumbRipple({
    required MaterialInkController controller,
    required super.referenceBox,
    required Offset position,
    required super.color,
    required this.textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    super.customBorder,
    double? radius,
    super.onRemoved,
  }) : _position = position,
       _borderRadius = borderRadius ?? BorderRadius.zero,
       _reduced = isReducedMotionNow(),
       _clipCallback = rectCallback ??
           (containedInkWell ? (() => Offset.zero & referenceBox.size) : null),
       super(controller: controller) {
    final size = rectCallback != null
        ? rectCallback().size
        : referenceBox.size;
    // Reach the farthest corner from the press point, but never grow past
    // kMaxRadius: a very wide control should still read as a local touch.
    final farthest = math.max(
      math.max(
        (position - Offset.zero).distance,
        (position - Offset(size.width, 0)).distance,
      ),
      math.max(
        (position - Offset(0, size.height)).distance,
        (position - size.bottomRight(Offset.zero)).distance,
      ),
    );
    _targetRadius = radius ?? (_reduced ? farthest : math.min(farthest, kMaxRadius));
    _anim = AnimationController(
      duration: _reduced ? MotionTokens.reducedFadeCap : kDuration,
      vsync: controller.vsync,
    )
      ..addListener(controller.markNeedsPaint)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) dispose();
      })
      ..forward();
    controller.addInkFeature(this);
  }

  /// Ripple lifetime (the prototype's 420 ms).
  static const Duration kDuration = Duration(milliseconds: 420);

  /// Cap on the ripple radius (prototype: 10 px circle scaled 14x = 70 px).
  static const double kMaxRadius = 70;

  static const InteractiveInkFeatureFactory splashFactory =
      _CrumbRippleFactory();

  final Offset _position;
  final BorderRadius _borderRadius;
  final TextDirection textDirection;
  final RectCallback? _clipCallback;
  final bool _reduced;
  late final double _targetRadius;
  late final AnimationController _anim;

  // The press itself is already shown by the highlight overlay; the ripple is a
  // one-shot flourish, so confirm/cancel don't alter it.
  @override
  void confirm() {}

  @override
  void cancel() {}

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    final t = _anim.value;
    // Peak ~0.6 of the (already translucent) splash colour, fading to 0.
    final alpha = (_reduced ? (1 - t) * 0.5 : (1 - t) * 0.6) * color.a;
    if (alpha <= 0) return;
    final eased = MotionTokens.standard.transform(t);
    final r = _reduced
        ? _targetRadius
        : 5 + (_targetRadius - 5) * eased;
    paintInkCircle(
      canvas: canvas,
      transform: transform,
      paint: Paint()..color = color.withValues(alpha: alpha),
      center: _position,
      textDirection: textDirection,
      radius: r,
      customBorder: customBorder,
      borderRadius: _borderRadius,
      clipCallback: _clipCallback,
    );
  }
}

/// Reduced-motion state for code that has no BuildContext (ink features,
/// shared tickers): the OS accessibility flag OR the in-app option.
bool isReducedMotionNow() {
  final os = WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .disableAnimations;
  return os || MotionPrefs.reduceMotion.value;
}
