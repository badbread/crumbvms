// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared press / hover / focus behaviour for every control, applied once at the
// theme level so no call site needs editing:
//
//   * press: a restrained ripple clipped to the control ([CrumbRipple]), a
//     faint highlight, and the control's content settles to 0.97 in 90 ms and
//     returns in 150 ms (decelerate).
//   * hover: the surface brightens slightly. No shadows, no elevation change.
//   * focus: a visible 2 px ring in the accent colour, keyboard focus only
//     (Flutter only reports `focused` for keyboard navigation).
//
// Covers FilledButton / ElevatedButton / OutlinedButton / TextButton /
// IconButton / SegmentedButton, chips, switches, checkboxes, and every plain
// InkWell (via ThemeData.splashFactory + the hover/focus/highlight colours).
// Custom controls that are not Material buttons (e.g. the PTZ pad) use
// [PressScale] directly.

import 'package:flutter/material.dart';

import 'crumb_ripple.dart';
import 'motion_tokens.dart';

/// Press scale applied to a control's content.
const double kPressScale = 0.97;

// Overlay alphas. The pressed colour doubles as the ripple colour (Material
// reuses it), so it is the knob that keeps the ripple restrained.
const double _kHoverAlpha = 0.05;
const double _kFocusAlpha = 0.10;
const double _kPressAlpha = 0.16;

Color _white(double a) => Colors.white.withValues(alpha: a);

WidgetStateProperty<Color?> _overlay() => WidgetStateProperty.resolveWith((s) {
  if (s.contains(WidgetState.pressed)) return _white(_kPressAlpha);
  if (s.contains(WidgetState.focused)) return _white(_kFocusAlpha);
  if (s.contains(WidgetState.hovered)) return _white(_kHoverAlpha);
  return null;
});

/// Applies the shared interaction rules to [base]. [accent] is the focus-ring
/// colour (the active tab's accent); defaults to the theme's primary.
ThemeData applyCrumbInteraction(ThemeData base, {Color? accent}) {
  final ring = accent ?? base.colorScheme.primary;
  final focusSide = WidgetStateProperty.resolveWith<BorderSide?>(
    (s) => s.contains(WidgetState.focused)
        ? BorderSide(color: ring, width: 2)
        : null,
  );
  ButtonStyle common() => ButtonStyle(
    overlayColor: _overlay(),
    splashFactory: CrumbRipple.splashFactory,
    animationDuration: MotionTokens.d2,
    side: focusSide,
    foregroundBuilder: (context, states, child) => PressScale(
      pressed: states.contains(WidgetState.pressed),
      child: child!,
    ),
  );
  // Chip and checkbox sides must resolve to a real BorderSide in EVERY state,
  // including the empty set: ThemeData.lerp (run by MaterialApp's
  // AnimatedTheme whenever the theme changes, e.g. the per-tab accent) resolves
  // them with no states and null-checks the result. Returning null for "use
  // the default" crashed the whole app into a grey error screen. These return
  // Material 3's own defaults, plus the focus ring.
  final scheme = base.colorScheme;
  final chipSide = WidgetStateBorderSide.resolveWith((s) {
    if (s.contains(WidgetState.focused))
      return BorderSide(color: ring, width: 2);
    if (s.contains(WidgetState.disabled)) {
      return BorderSide(color: scheme.onSurface.withValues(alpha: 0.12));
    }
    if (s.contains(WidgetState.selected)) return BorderSide.none;
    return BorderSide(color: scheme.outlineVariant);
  });
  return base.copyWith(
    splashFactory: CrumbRipple.splashFactory,
    splashColor: _white(0.25),
    highlightColor: _white(0.06),
    hoverColor: _white(_kHoverAlpha),
    focusColor: _white(_kFocusAlpha),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.merge(common()) ?? common(),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: base.elevatedButtonTheme.style?.merge(common()) ?? common(),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.merge(common()) ?? common(),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.merge(common()) ?? common(),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: base.iconButtonTheme.style?.merge(common()) ?? common(),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: base.segmentedButtonTheme.style?.merge(common()) ?? common(),
    ),
    // Expand / collapse sections animate their height on the standard curve.
    expansionTileTheme: base.expansionTileTheme.copyWith(
      expansionAnimationStyle: AnimationStyle(
        duration: MotionTokens.d3,
        reverseDuration: MotionTokens.d3,
        curve: MotionTokens.standard,
        reverseCurve: MotionTokens.standard,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(side: chipSide),
    switchTheme: base.switchTheme.copyWith(
      overlayColor: _overlay(),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.focused) ? ring : null,
      ),
    ),
    checkboxTheme: base.checkboxTheme.copyWith(
      overlayColor: _overlay(),
      side: WidgetStateBorderSide.resolveWith((s) {
        if (s.contains(WidgetState.focused)) {
          return BorderSide(color: ring, width: 2);
        }
        if (s.contains(WidgetState.disabled)) {
          return BorderSide(
            width: 2,
            color: scheme.onSurface.withValues(alpha: 0.38),
          );
        }
        if (s.contains(WidgetState.selected)) {
          return const BorderSide(width: 0, color: Colors.transparent);
        }
        return BorderSide(width: 2, color: scheme.onSurfaceVariant);
      }),
    ),
  );
}

/// Scales [child] to [kPressScale] while [pressed]: 90 ms in, 150 ms back out
/// (decelerate). A no-op scale under reduced motion. Content only: never put
/// this around video.
class PressScale extends StatelessWidget {
  const PressScale({super.key, required this.pressed, required this.child});

  final bool pressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final on = pressed && !MotionTokens.reduced(context);
    return AnimatedScale(
      scale: on ? kPressScale : 1.0,
      duration: on ? MotionTokens.d1 : MotionTokens.d2,
      curve: on ? MotionTokens.standard : MotionTokens.decelerate,
      child: child,
    );
  }
}

/// A [PressScale] that tracks its own pointer press, for custom (non-Material)
/// controls. Purely visual: never absorbs or delays the gesture, so the
/// control's own handlers fire immediately.
class PressScaleListener extends StatefulWidget {
  const PressScaleListener({super.key, required this.child});

  final Widget child;

  @override
  State<PressScaleListener> createState() => _PressScaleListenerState();
}

class _PressScaleListenerState extends State<PressScaleListener> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: PressScale(pressed: _down, child: widget.child),
    );
  }
}
