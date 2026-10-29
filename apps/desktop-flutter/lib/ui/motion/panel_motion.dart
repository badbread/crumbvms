// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Motion for lists, panels, and transient feedback. Items that arrive
// decelerate in; items that leave accelerate out; nothing is longer than 220 ms
// here, and none of it delays the action that triggered it.
//
//   * [SizeFadeRow]      a list row that grows + fades in when it is added and
//                        shrinks + fades out when it is removed (list reflow).
//   * [PopPresence]      a floating panel (Settings) that scales 0.96 -> 1 and
//                        fades in from its origin, and reverses faster on close.
//   * [SideSlidePanel]   a detail panel that slides in from the right while its
//                        contents fade in slightly behind it.
//   * [ToastMotion]      a toast that rises 10 px as it fades in, and drops
//                        6 px as it fades out.
//
// Reduced motion: no size, scale or slide motion; fades capped at 100 ms.

import 'package:flutter/material.dart';

import 'motion_tokens.dart';

/// A list row with add / remove reflow.
///
/// Mount with [animateIn] true for a row that was just added (false for rows
/// that were already there, so opening a screen does not animate its whole
/// list). Flip [leaving] to true to collapse the row; the owner removes it from
/// its data after [leaveDuration] (the model changes immediately, only the
/// picture lingers, so the action itself is never delayed).
class SizeFadeRow extends StatefulWidget {
  const SizeFadeRow({
    super.key,
    required this.child,
    this.animateIn = false,
    this.leaving = false,
  });

  final Widget child;
  final bool animateIn;
  final bool leaving;

  /// How long a leaving row stays on screen.
  static const Duration leaveDuration = MotionTokens.d3;

  /// Leave duration for the current motion preference.
  static Duration leaveDurationFor(BuildContext context) => MotionTokens.scaled(
    leaveDuration,
    reduced: MotionTokens.reduced(context),
  );

  @override
  State<SizeFadeRow> createState() => _SizeFadeRowState();
}

class _SizeFadeRowState extends State<SizeFadeRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MotionTokens.d3,
    value: widget.animateIn ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.leaving) {
      _c.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = MotionTokens.scaled(
      MotionTokens.d3,
      reduced: MotionTokens.reduced(context),
    );
    _c.duration = d;
    // First build of a newly added row: run the entrance.
    if (widget.animateIn && !widget.leaving && _c.value == 0 && !_started) {
      _started = true;
      _c.forward();
    }
  }

  bool _started = false;

  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _c,
    curve: MotionTokens.decelerate,
    reverseCurve: MotionTokens.accelerate.flipped,
  );

  @override
  void didUpdateWidget(SizeFadeRow old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      _c.reverse();
    } else if (!widget.leaving && old.leaving) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MotionTokens.reduced(context);
    // Arrive: decelerate. Leave: accelerate (the reverse of the same run).
    final curved = _curved;
    final faded = FadeTransition(
      opacity: curved,
      child: IgnorePointer(ignoring: widget.leaving, child: widget.child),
    );
    if (reduced) return faded;
    return SizeTransition(sizeFactor: curved, child: faded);
  }
}

/// Keeps [builder]'s panel mounted while it animates out. [present] true:
/// scale 0.96 -> 1 + fade in (220 ms decelerate); false: 0.96 + fade out
/// (150 ms accelerate), then the panel is dropped. Takes no input while leaving.
class PopPresence extends StatefulWidget {
  const PopPresence({
    super.key,
    required this.present,
    required this.builder,
    this.alignment = Alignment.center,
  });

  final bool present;
  final WidgetBuilder builder;

  /// The point the panel grows from.
  final Alignment alignment;

  @override
  State<PopPresence> createState() => _PopPresenceState();
}

class _PopPresenceState extends State<PopPresence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(
        vsync: this,
        duration: MotionTokens.d3,
        reverseDuration: MotionTokens.d2,
        value: widget.present ? 1 : 0,
      )..addStatusListener((status) {
        // Drop the panel once its exit has finished. Deferred: a status change can
        // fire synchronously from didUpdateWidget, where setState is illegal.
        if (status != AnimationStatus.dismissed) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      });

  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _c,
    curve: MotionTokens.decelerate,
    reverseCurve: MotionTokens.accelerate.flipped,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MotionTokens.reduced(context);
    _c.duration = MotionTokens.scaled(MotionTokens.d3, reduced: reduced);
    _c.reverseDuration = MotionTokens.scaled(MotionTokens.d2, reduced: reduced);
  }

  @override
  void didUpdateWidget(PopPresence old) {
    super.didUpdateWidget(old);
    if (widget.present && !old.present) {
      _c.forward();
    } else if (!widget.present && old.present) {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.present && _c.status == AnimationStatus.dismissed) {
      return const SizedBox.shrink();
    }
    final reduced = MotionTokens.reduced(context);
    final curved = _curved;
    Widget panel = FadeTransition(
      opacity: curved,
      child: widget.builder(context),
    );
    if (!reduced) {
      panel = ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
        alignment: widget.alignment,
        child: panel,
      );
    }
    return IgnorePointer(ignoring: !widget.present, child: panel);
  }
}

/// A detail panel that slides in from the right edge (220 ms decelerate,
/// 220 ms accelerate out) while its contents fade in 60 ms behind it. Place it
/// in a Stack; it sizes to [width] and the Stack's height.
class SideSlidePanel extends StatefulWidget {
  const SideSlidePanel({
    super.key,
    required this.open,
    required this.width,
    required this.child,
    this.color,
  });

  final bool open;
  final double width;
  final Widget child;
  final Color? color;

  @override
  State<SideSlidePanel> createState() => _SideSlidePanelState();
}

class _SideSlidePanelState extends State<SideSlidePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MotionTokens.d3,
    value: widget.open ? 1 : 0,
  );

  late final CurvedAnimation _slide = CurvedAnimation(
    parent: _c,
    curve: MotionTokens.decelerate,
    reverseCurve: MotionTokens.accelerate.flipped,
  );
  // Contents trail the panel by 60 ms (of the 220) and fade in over the rest.
  late final CurvedAnimation _inner = CurvedAnimation(
    parent: _c,
    curve: const Interval(60 / 220, 1, curve: MotionTokens.standard),
    reverseCurve: const Interval(0, 0.5, curve: MotionTokens.standard),
  );

  @override
  void didUpdateWidget(SideSlidePanel old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      widget.open ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    _inner.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MotionTokens.reduced(context);
    _c.duration = MotionTokens.scaled(MotionTokens.d3, reduced: reduced);
    final slide = _slide;
    final inner = _inner;
    final body = FadeTransition(opacity: inner, child: widget.child);
    return IgnorePointer(
      ignoring: !widget.open,
      child: reduced
          ? FadeTransition(opacity: slide, child: _shell(body))
          : SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(slide),
              child: _shell(body),
            ),
    );
  }

  Widget _shell(Widget body) => SizedBox(
    width: widget.width,
    child: ColoredBox(color: widget.color ?? Colors.transparent, child: body),
  );
}

/// Toast entrance / exit. [visible] true: fade in while rising from 10 px below
/// (220 ms decelerate); false: fade out while dropping 6 px (150 ms accelerate).
class ToastMotion extends StatefulWidget {
  const ToastMotion({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<ToastMotion> createState() => _ToastMotionState();
}

class _ToastMotionState extends State<ToastMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MotionTokens.d3,
    reverseDuration: MotionTokens.d2,
  );

  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _c,
    curve: MotionTokens.decelerate,
    reverseCurve: MotionTokens.accelerate.flipped,
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MotionTokens.reduced(context);
    _c.duration = MotionTokens.scaled(MotionTokens.d3, reduced: reduced);
    _c.reverseDuration = MotionTokens.scaled(MotionTokens.d2, reduced: reduced);
  }

  @override
  void didUpdateWidget(ToastMotion old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) {
      widget.visible ? _c.forward() : _c.reverse();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MotionTokens.reduced(context);
    final curved = _curved;
    final faded = FadeTransition(opacity: curved, child: widget.child);
    if (reduced) return faded;
    return AnimatedBuilder(
      animation: curved,
      child: faded,
      builder: (context, child) {
        // Rises 10 px on the way in; the way out only drops 6 px.
        final t = curved.value;
        final dy = _c.status == AnimationStatus.reverse
            ? (1 - t) * 6
            : (1 - t) * 10;
        return Transform.translate(offset: Offset(0, dy), child: child);
      },
    );
  }
}
