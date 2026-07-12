// App-wide "hold Shift to see what every button does" hints. A button wraps
// itself in a [ShiftHint] with a short caption; while Shift is held down
// (globally), a small caption floats over every wrapped button at once — handy
// on dense surfaces like the playback transport (frame-step, next-motion, …).
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
    if (show != _show) setState(() => _show = show);
  }

  @override
  void dispose() {
    HintsController.instance.active.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                  // Move the caption fully out of the child's box (100% of its
                  // own height) plus a hair, so it sits just above/below it.
                  translation: Offset(0, widget.above ? -1.15 : 1.15),
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
