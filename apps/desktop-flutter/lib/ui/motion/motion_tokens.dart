// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The desktop client's motion system, as code. One set of durations and curves
// so every animation in the app speaks the same language (the approved motion
// prototype is the spec):
//
//   * Four duration tiers: 90 ms (press / instant feedback), 150 ms (small state
//     changes, releases), 220 ms (panels, tabs, list reflow), 280 ms (hero:
//     tile maximize). Nothing is longer than 280 ms.
//   * Three curves: standard (symmetric-ish, crisp stop), decelerate (things
//     arriving), accelerate (things leaving). No overshoot, ever.
//   * Reverse is one tier shorter than forward and uses the accelerate curve.
//
// What is NEVER animated: video content, live values (timestamps, counters,
// status values), alarm states, the playhead / timeline, PTZ dispatch, keyboard
// shortcuts. Actions fire immediately; an animation never gates input.
//
// Reduced motion (MediaQuery.disableAnimations, which Flutter fills from the
// Windows "Show animations in Windows" setting, OR the in-app "Reduce motion"
// option): no position/size motion, fades capped at 100 ms, looping indicators
// are static (REC solid, no shimmer).

import 'package:flutter/widgets.dart';

abstract final class MotionTokens {
  // Duration tiers.
  static const Duration d1 = Duration(milliseconds: 90);
  static const Duration d2 = Duration(milliseconds: 150);
  static const Duration d3 = Duration(milliseconds: 220);
  static const Duration d4 = Duration(milliseconds: 280);

  /// Longest fade allowed under reduced motion.
  static const Duration reducedFadeCap = Duration(milliseconds: 100);

  // Curves.
  static const Cubic standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Cubic decelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Cubic accelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  /// The tier one step shorter than [d] (280 -> 220 -> 150 -> 90 -> 90).
  /// Used for the reverse of an animation (close, restore, leave).
  static Duration reverseOf(Duration d) {
    if (d >= d4) return d3;
    if (d >= d3) return d2;
    return d1;
  }

  /// [d] under reduced motion: capped at [reducedFadeCap]. Pass-through when
  /// motion is allowed.
  static Duration scaled(Duration d, {required bool reduced}) =>
      reduced && d > reducedFadeCap ? reducedFadeCap : d;

  /// True when the user (OS or the in-app "Reduce motion" option, which is
  /// folded into [MediaQuery.disableAnimations] at the app root by
  /// [MotionPrefsScope]) wants no spatial motion.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// The in-app "Reduce motion" override (Settings > Options). Process-wide
/// because it is read by [MotionPrefsScope] once at the app root, which then
/// folds it into MediaQuery so every widget sees one signal.
abstract final class MotionPrefs {
  static final ValueNotifier<bool> reduceMotion = ValueNotifier<bool>(false);
}

/// Folds [MotionPrefs.reduceMotion] into `MediaQuery.disableAnimations`, so the
/// OS setting and the in-app option are a single signal for everything below
/// (this app's motion helpers and Flutter's own animated widgets alike).
class MotionPrefsScope extends StatelessWidget {
  const MotionPrefsScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: MotionPrefs.reduceMotion,
      child: child,
      builder: (context, forced, child) {
        final mq = MediaQuery.of(context);
        if (!forced || mq.disableAnimations) return child!;
        return MediaQuery(
          data: mq.copyWith(disableAnimations: true),
          child: child!,
        );
      },
    );
  }
}
