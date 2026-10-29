// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The maximize / restore transition shared by the live wall (and any grid that
// maximizes a tile): ONE AnimationController per wall, no matter how many tiles.
//
//   expand   280 ms, emphasized decelerate. The tile's visual grows from its
//            grid slot to fill the wall; every other tile recedes (fade to
//            black + scale to 0.96, accelerate, over the first 80%).
//   collapse 220 ms (one tier shorter), accelerate. Siblings return 25% late.
//   Interruptible: expand/collapse mid-flight retargets from the CURRENT
//   geometry (no jump, no restart from 0).
//
// This class is pure state (no widgets) so the state machine is unit-testable.
// It never touches a video widget: the owner moves the same subtree with a
// Transform, so a media_kit texture is never recreated or re-parented.
//
// Reduced motion: [reduced] = true makes the geometry stand still (the pane is
// simply at full size) and shrinks the fade to <= 100 ms.

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart' show Listenable;

import 'motion_tokens.dart';

class MaximizeTransition {
  MaximizeTransition({required TickerProvider vsync})
    : _c = AnimationController(vsync: vsync);

  final AnimationController _c;

  // Geometry progress (0 = the tile's slot, 1 = fills the wall) and sibling
  // recession (0 = visible, 1 = faded + scaled away) at the moment the current
  // run started. The run then eases toward [_target].
  double _fromGeo = 0;
  double _fromRecede = 0;
  double _target = 0;

  /// Set by the owner before [expand] / [collapse] (from MediaQuery).
  bool reduced = false;

  Listenable get listenable => _c;

  void addStatusListener(AnimationStatusListener l) => _c.addStatusListener(l);
  void removeStatusListener(AnimationStatusListener l) =>
      _c.removeStatusListener(l);

  /// True while the controller is running.
  bool get isAnimating => _c.isAnimating;

  /// The state the transition is heading to (or resting at): true = maximized.
  bool get targetExpanded => _target == 1;

  /// Resting maximized (not animating).
  bool get isExpanded => _target == 1 && !_c.isAnimating;

  /// Resting restored (not animating): the pane layer can be dropped.
  bool get isCollapsed => _target == 0 && !_c.isAnimating;

  Curve get _geoCurve =>
      _target == 1 ? MotionTokens.decelerate : MotionTokens.accelerate;

  // Expanding: siblings leave over the first 80%. Collapsing: they come back
  // 25% late, finishing with the run.
  Curve get _recedeCurve => _target == 1
      ? const Interval(0.0, 0.8, curve: MotionTokens.accelerate)
      : const Interval(0.25, 1.0, curve: MotionTokens.decelerate);

  double _along(double from, Curve curve) {
    final t = _c.value;
    if (t >= 1.0) return _target;
    return from + (_target - from) * curve.transform(t);
  }

  /// Eased geometry: 0 = tile rect, 1 = full wall rect.
  double get progress => reduced ? _target : _along(_fromGeo, _geoCurve);

  /// 0 = siblings fully shown, 1 = fully receded. Under reduced motion this is
  /// a plain (<=100 ms) fade with no scale (the owner skips the scale).
  double get recede => _along(_fromRecede, _recedeCurve);

  /// Opacity of the maximized pane itself: always opaque, except under reduced
  /// motion where it fades in/out in place instead of travelling.
  double get paneOpacity => reduced ? _along(_fromGeo, Curves.linear) : 1.0;

  /// The run duration for [expanding].
  Duration durationFor({required bool expanding}) {
    final d = expanding ? MotionTokens.d4 : MotionTokens.reverseOf(MotionTokens.d4);
    return MotionTokens.scaled(d, reduced: reduced);
  }

  void _run(double target, {required bool animate}) {
    // Sample BEFORE changing the target so a mid-flight reversal continues from
    // exactly where the geometry is now.
    final geo = progress;
    final rec = recede;
    _fromGeo = geo;
    _fromRecede = rec;
    _target = target;
    if (!animate || (geo == target && rec == target)) {
      _fromGeo = target;
      _fromRecede = target;
      _c.value = 1.0;
      return;
    }
    _c.duration = durationFor(expanding: target == 1);
    _c.forward(from: 0.0);
  }

  /// Grow to the full wall (animated unless [animate] is false).
  void expand({bool animate = true}) => _run(1, animate: animate);

  /// Shrink back to the slot (animated unless [animate] is false).
  void collapse({bool animate = true}) => _run(0, animate: animate);

  /// Reverse whatever is heading the other way; returns the new target.
  bool toggle() {
    targetExpanded ? collapse() : expand();
    return targetExpanded;
  }

  /// Snap to the maximized state with no animation (camera swap while already
  /// maximized, or a restored maximize after a minimize).
  void snapExpanded() => _run(1, animate: false);

  void dispose() => _c.dispose();
}
