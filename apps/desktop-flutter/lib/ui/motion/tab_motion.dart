// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Tab switching motion ("slide + fade"):
//
//   * [SlidingUnderlineRow]: the accent underline slides between tabs and
//     morphs its width (220 ms, standard curve) while its colour tweens to the
//     new tab's accent.
//   * [TabContentTransition]: the new tab's content fades in with a 6 px
//     directional slide (180 ms, decelerate, starting 40 ms in); the outgoing
//     content fades out first (90 ms, accelerate).
//
// Video-heavy tabs (Live, Playback) dispose their mpv players when you leave
// them, on purpose. A cross-fade must never keep two of those alive, so a
// video-heavy OUTGOING tab is not kept: it is disposed at once, exactly as
// before, and only the incoming content fades in (over the solid surface behind
// it). A light outgoing tab (Clips / LPR / Export) does fade out underneath.
// Content is interactive from the first frame: no animation gates input.
//
// Reduced motion: no slide, no underline travel, fades capped at 100 ms.

import 'package:flutter/material.dart';

import 'motion_tokens.dart';

/// What a tab switch should do. Pure so the selection logic is testable.
class TabSwitchPlan {
  const TabSwitchPlan({
    required this.keepOutgoing,
    required this.direction,
    required this.slide,
    required this.duration,
  });

  /// Keep the outgoing content mounted while it fades out. False when it is
  /// video-heavy (its players must be disposed immediately).
  final bool keepOutgoing;

  /// +1 when the new tab is to the right of the old one, -1 when to the left.
  final int direction;

  /// Horizontal travel of the incoming content in logical px (signed; 0 under
  /// reduced motion). The outgoing content drifts the other way by the same.
  final double slide;

  /// Total run: out 90 ms then in over 180 ms (starting 40 ms in) = 220 ms.
  final Duration duration;
}

/// Decide how to switch from tab [from] to tab [to].
///
/// [order] maps a tab index to its on-screen position (the display order is not
/// the numeric order: LPR renders before Export); [isVideoHeavy] says whether a
/// tab disposes live players when left.
TabSwitchPlan planTabSwitch({
  required int from,
  required int to,
  required int Function(int tab) order,
  required bool Function(int tab) isVideoHeavy,
  required bool reduced,
}) {
  final dir = order(to) >= order(from) ? 1 : -1;
  return TabSwitchPlan(
    keepOutgoing: !isVideoHeavy(from),
    direction: dir,
    slide: reduced ? 0 : 6.0 * dir,
    duration: MotionTokens.scaled(MotionTokens.d3, reduced: reduced),
  );
}

// Timing within one run (fractions of [TabSwitchPlan.duration] at 220 ms).
const double _outEnd = 90 / 220;
const double _inStart = 40 / 220;

/// Wraps the current tab's content and animates tab changes. [index] is the
/// stable id of the shown tab; when it changes the previous [child] may be
/// kept for the fade-out (see [planTabSwitch]).
class TabContentTransition extends StatefulWidget {
  const TabContentTransition({
    super.key,
    required this.index,
    required this.order,
    required this.isVideoHeavy,
    required this.child,
  });

  final int index;
  final int Function(int tab) order;
  final bool Function(int tab) isVideoHeavy;
  final Widget child;

  @override
  State<TabContentTransition> createState() => _TabContentTransitionState();
}

class _TabContentTransitionState extends State<TabContentTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, value: 1)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && _outgoing != null && mounted) {
        setState(() => _outgoing = null);
      }
    });

  // The previous tab's last-built content, kept only while it fades out.
  int? _outgoingIndex;
  Widget? _outgoing;
  double _slide = 0;

  @override
  void didUpdateWidget(TabContentTransition old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    final plan = planTabSwitch(
      from: old.index,
      to: widget.index,
      order: widget.order,
      isVideoHeavy: widget.isVideoHeavy,
      reduced: MotionTokens.reduced(context),
    );
    _slide = plan.slide;
    _outgoingIndex = plan.keepOutgoing ? old.index : null;
    _outgoing = plan.keepOutgoing ? old.child : null;
    _c.duration = plan.duration;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Animation<double> get _outOpacity => _c.drive(
    Tween<double>(begin: 1, end: 0).chain(
      CurveTween(
        curve: const Interval(0, _outEnd, curve: MotionTokens.accelerate),
      ),
    ),
  );

  Animation<double> get _inOpacity => _c.drive(
    Tween<double>(begin: 0, end: 1).chain(
      CurveTween(
        curve: const Interval(_inStart, 1, curve: MotionTokens.decelerate),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final out = _outgoing;
    return Stack(
      children: [
        // Keyed by tab index so a page's element (and State) survives changing
        // role between "current" and "outgoing".
        if (out != null)
          _TabPage(
            key: ValueKey(_outgoingIndex),
            opacity: _outOpacity,
            slideAnim: _c,
            slide: -_slide,
            ignoring: true,
            child: out,
          ),
        _TabPage(
          key: ValueKey(widget.index),
          opacity: _inOpacity,
          slideAnim: _c,
          slide: _slide,
          ignoring: false,
          // Once settled the page is fully opaque and un-offset.
          child: widget.child,
        ),
      ],
    );
  }
}

class _TabPage extends StatelessWidget {
  const _TabPage({
    super.key,
    required this.opacity,
    required this.slideAnim,
    required this.slide,
    required this.ignoring,
    required this.child,
  });

  final Animation<double> opacity;
  final Animation<double> slideAnim;
  final double slide;
  final bool ignoring;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // At rest (controller dismissed or completed) the incoming page is opaque
    // and un-offset: FadeTransition at 1.0 adds no layer.
    return IgnorePointer(
      ignoring: ignoring,
      child: FadeTransition(
        opacity: opacity,
        child: AnimatedBuilder(
          animation: slideAnim,
          child: child,
          builder: (context, child) {
            final t = slideAnim.value;
            // Incoming: from +slide to 0 over its fade; outgoing: 0 -> slide.
            final dx = slide == 0
                ? 0.0
                : (slide > 0
                      ? slide *
                            (1 -
                                MotionTokens.decelerate.transform(
                                  ((t - _inStart) / (1 - _inStart)).clamp(
                                    0.0,
                                    1.0,
                                  ),
                                ))
                      : slide *
                            MotionTokens.accelerate.transform(
                              (t / _outEnd).clamp(0.0, 1.0),
                            ));
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
        ),
      ),
    );
  }
}

/// A Row of tabs with ONE accent underline that slides and resizes to sit under
/// the [selected] child (220 ms, standard) and tweens its colour to [color].
/// [secondary] is an optional second child (the Settings toggle) that gets its
/// own underline, which fades in and out in place rather than travelling.
///
/// The children are laid out exactly as a plain Row would, with no extra
/// padding; the underline is drawn over their bottom edge.
class SlidingUnderlineRow extends StatefulWidget {
  const SlidingUnderlineRow({
    super.key,
    required this.children,
    required this.selected,
    required this.color,
    this.secondary,
    this.secondaryVisible = false,
    this.secondaryColor = Colors.white54,
    this.thickness = 2,
  });

  final List<Widget> children;

  /// Index into [children] that carries the sliding underline (-1: none).
  final int selected;
  final Color color;
  final int? secondary;
  final bool secondaryVisible;
  final Color secondaryColor;
  final double thickness;

  @override
  State<SlidingUnderlineRow> createState() => _SlidingUnderlineRowState();
}

class _SlidingUnderlineRowState extends State<SlidingUnderlineRow> {
  final GlobalKey _rowKey = GlobalKey();
  final List<GlobalKey> _keys = [];

  // Measured child extents (x, width) in the row's coordinate space.
  Rect? _sel;
  Rect? _sec;
  bool _settled = false; // first measurement is placed without animating

  GlobalKey _key(int i) {
    while (_keys.length <= i) {
      _keys.add(GlobalKey());
    }
    return _keys[i];
  }

  Rect? _measure(int i) {
    if (i < 0 || i >= _keys.length) return null;
    final box = _keys[i].currentContext?.findRenderObject();
    final row = _rowKey.currentContext?.findRenderObject();
    if (box is! RenderBox || row is! RenderBox) return null;
    if (!box.attached || !box.hasSize || !row.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: row) & box.size;
  }

  void _remeasure() {
    if (!mounted) return;
    final sel = _measure(widget.selected);
    final sec = widget.secondary == null ? null : _measure(widget.secondary!);
    if (sel != _sel || sec != _sec) {
      setState(() {
        _sel = sel;
        _sec = sec;
      });
    }
    if (!_settled && sel != null) {
      // Let the first placement land, then animate from then on.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _settled = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Children can change size (selected label turns bold), move (a tab
    // appears), or the window can resize: re-measure after every layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => _remeasure());
    final reduced = MotionTokens.reduced(context);
    final animate = _settled && !reduced;
    final slideDur = animate ? MotionTokens.d3 : Duration.zero;
    final fadeDur = MotionTokens.scaled(MotionTokens.d2, reduced: reduced);
    return Stack(
      key: _rowKey,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              KeyedSubtree(key: _key(i), child: widget.children[i]),
          ],
        ),
        if (_sec != null)
          Positioned(
            left: _sec!.left,
            width: _sec!.width,
            bottom: 0,
            height: widget.thickness,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: widget.secondaryVisible ? 1 : 0,
                duration: fadeDur,
                curve: MotionTokens.standard,
                child: ColoredBox(color: widget.secondaryColor),
              ),
            ),
          ),
        if (_sel != null)
          Positioned.fill(
            child: IgnorePointer(
              child: TweenAnimationBuilder<Rect?>(
                tween: RectTween(end: _sel),
                duration: slideDur,
                curve: MotionTokens.standard,
                builder: (context, rect, _) {
                  return TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: widget.color),
                    duration: reduced ? fadeDur : MotionTokens.d3,
                    curve: MotionTokens.standard,
                    builder: (context, color, _) => Stack(
                      children: [
                        Positioned(
                          left: rect!.left,
                          width: rect.width,
                          bottom: 0,
                          height: widget.thickness,
                          child: ColoredBox(color: color ?? widget.color),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
