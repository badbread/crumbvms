// App-wide "hold Shift to see what every button does" hints. A button wraps
// itself in a [ShiftHint] with a short caption; while Shift is held down
// (globally), a caption floats over EVERY wrapped button at once — the whole
// keyboard/action map at a glance, which the per-button hover tooltip can't
// give you.
//
// Overlap: on dense rows (the playback transport) many ~200px captions centred
// on ~35px-spaced buttons would pile on top of each other. To keep them
// readable while still showing all at once, each caption is nudged to one of a
// few VERTICAL levels chosen from its horizontal position — neighbouring
// buttons land on different levels, so their captions clear each other.
//
// The global Shift signal is owned by [HintsController]; the app root toggles
// it from a HardwareKeyboard handler (see main.dart). Buttons just opt in.
//
// Rendering: the caption is a sibling in a Clip.none Stack, floated just
// above/below the child with a FractionalTranslation, and given its natural
// width via an OverflowBox. This is deliberately NOT an OverlayPortal /
// CompositedTransformFollower — that approach rendered oversized black boxes in
// practice. Here the caption is a tight text chip in the normal widget tree.

import 'package:flutter/material.dart';

/// Singleton on/off signal for the Shift-held hint layer.
class HintsController {
  HintsController._();
  static final HintsController instance = HintsController._();

  /// True while Shift is held (and not typing in a text field).
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);
}

/// Wrap a button (or any widget) to show [hint] above/below it while the
/// Shift-hint layer is active. Non-intrusive: the caption never affects layout
/// and ignores pointer events.
class ShiftHint extends StatefulWidget {
  const ShiftHint({
    super.key,
    required this.hint,
    required this.child,
    this.above = true,
  });

  final String hint;
  final Widget child;

  /// Float the caption above the child (default) or below (use false near the
  /// top of the screen, e.g. the top bar, so it doesn't clip off-screen).
  final bool above;

  @override
  State<ShiftHint> createState() => _ShiftHintState();
}

class _ShiftHintState extends State<ShiftHint> {
  bool _show = false;

  /// Extra vertical offset (in caption-heights) so neighbouring captions land
  /// on different levels instead of overlapping. Derived from this widget's
  /// horizontal position, measured after layout.
  int _level = 0;

  @override
  void initState() {
    super.initState();
    HintsController.instance.active.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    final show =
        HintsController.instance.active.value && widget.hint.isNotEmpty;
    if (show != _show) {
      setState(() => _show = show);
      if (show) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measureLevel());
      }
    }
  }

  void _measureLevel() {
    if (!mounted || !_show) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final gx = box.localToGlobal(Offset.zero).dx;
    // 5 staggered levels across the screen width so densely-packed captions
    // (transport buttons ~35px apart, captions ~200px wide) clear each other.
    const levels = 5;
    final level = (((gx / 46).floor() % levels) + levels) % levels;
    if (level != _level) setState(() => _level = level);
  }

  @override
  void dispose() {
    HintsController.instance.active.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Base nudge fully clears the child (1.15 caption-heights); each stagger
    // level adds one more so neighbours don't collide.
    final offset = 1.15 + _level * 1.12;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (_show)
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment:
                    widget.above ? Alignment.topCenter : Alignment.bottomCenter,
                child: FractionalTranslation(
                  translation: Offset(0, widget.above ? -offset : offset),
                  child: OverflowBox(
                    minWidth: 0,
                    maxWidth: 260,
                    alignment: Alignment.center,
                    child: _caption(),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _caption() {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          widget.hint,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: const TextStyle(color: Colors.white, fontSize: 10.5),
        ),
      ),
    );
  }
}
