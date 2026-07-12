// App-wide "hold Shift to see what every button does" hints. A button wraps
// itself in a [ShiftHint] with a short caption; while Shift is held down
// (globally), a small caption floats over every wrapped button at once — handy
// on dense surfaces like the playback transport (frame-step, next-motion, …).
//
// The global Shift signal is owned by [HintsController]; the app root toggles
// it from a HardwareKeyboard handler (see main.dart). Buttons just opt in.

import 'package:flutter/material.dart';

/// Singleton on/off signal for the Shift-held hint layer.
class HintsController {
  HintsController._();
  static final HintsController instance = HintsController._();

  /// True while Shift is held (and not typing in a text field).
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);
}

/// Wrap a button (or any widget) to show [hint] above/below it while the
/// Shift-hint layer is active. Non-intrusive: the caption is an overlay, never
/// affects layout, and ignores pointer events.
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
  final LayerLink _link = LayerLink();
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    HintsController.instance.active.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    final show =
        HintsController.instance.active.value && widget.hint.isNotEmpty;
    if (show && !_portal.isShowing) {
      _portal.show();
    } else if (!show && _portal.isShowing) {
      _portal.hide();
    }
  }

  @override
  void dispose() {
    HintsController.instance.active.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: widget.above
              ? Alignment.topCenter
              : Alignment.bottomCenter,
          followerAnchor: widget.above
              ? Alignment.bottomCenter
              : Alignment.topCenter,
          offset: Offset(0, widget.above ? -4 : 4),
          child: IgnorePointer(
            // Size to the caption text on a single line. Without an explicit
            // width bound the overlay child can be handed a near-zero max-width
            // and wrap one glyph per line — the caption then renders as a thin
            // vertical sliver. ConstrainedBox + softWrap:false keeps it a normal
            // horizontal chip.
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
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
              ),
            ),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
