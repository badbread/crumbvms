// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The two widget layers that render a [MaximizeTransition]:
//
//   * [MaximizeRecedeLayer] wraps the wall body (all the tiles). While a
//     maximize runs it scales the whole body toward 0.96 and veils it with
//     black (the wall's own background), instead of putting an Opacity/saveLayer
//     over nine video textures. At rest it is an identity transform with no veil.
//   * [MaximizeFrame] wraps the maximized pane. The pane is laid out ONCE at
//     full wall size and is moved with a Transform (uniform scale + translate)
//     from the tile's rect to the full rect, so it is never re-laid-out or
//     re-parented per frame and its video texture is never recreated. The
//     animating subtree is isolated in a RepaintBoundary.
//
// Both rebuild only themselves per animation tick (AnimatedBuilder scoped to
// the moving subtree); the wall's tiles are passed as the stable `child`.

import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import 'maximize_transition.dart';

/// Scale the siblings recede to (the prototype's 0.96).
const double kRecedeScale = 0.96;

class MaximizeRecedeLayer extends StatelessWidget {
  const MaximizeRecedeLayer({
    super.key,
    required this.transition,
    required this.child,
  });

  final MaximizeTransition transition;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // `child` is index 0 in every state, so the tiles' elements (and their
        // GlobalKeys / decoding players) are never disturbed.
        AnimatedBuilder(
          animation: transition.listenable,
          child: child,
          builder: (context, child) {
            final r = transition.recede;
            final s = transition.reduced
                ? 1.0
                : lerpDouble(1.0, kRecedeScale, r)!;
            return Transform.scale(scale: s, child: child);
          },
        ),
        // Veil: black over the receding tiles. IgnorePointer so it never eats a
        // click; painted only while receding.
        IgnorePointer(
          child: AnimatedBuilder(
            animation: transition.listenable,
            builder: (context, _) {
              final r = transition.recede;
              if (r <= 0) return const SizedBox.shrink();
              return ColoredBox(
                color: Color.fromRGBO(0, 0, 0, r.clamp(0.0, 1.0)),
                child: const SizedBox.expand(),
              );
            },
          ),
        ),
      ],
    );
  }
}

class MaximizeFrame extends StatelessWidget {
  const MaximizeFrame({
    super.key,
    required this.transition,
    required this.origin,
    required this.child,
  });

  final MaximizeTransition transition;

  /// The tile's rect in this frame's coordinate space, or null if unknown (the
  /// pane then grows from a centred, half-size rect).
  final Rect? origin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final full = Offset.zero & size;
        final from =
            origin ??
            Rect.fromCenter(
              center: full.center,
              width: size.width * 0.5,
              height: size.height * 0.5,
            );
        return AnimatedBuilder(
          animation: transition.listenable,
          child: RepaintBoundary(child: child),
          builder: (context, child) {
            final p = transition.progress;
            final rect = Rect.lerp(from, full, p)!;
            // Uniform "contain" scale so the pane keeps its aspect; any
            // leftover of `rect` is the black backing below.
            final s = size.isEmpty
                ? 1.0
                : (rect.width / size.width < rect.height / size.height
                      ? rect.width / size.width
                      : rect.height / size.height);
            final dx = rect.center.dx - size.width * s / 2;
            final dy = rect.center.dy - size.height * s / 2;
            final opacity = transition.paneOpacity;
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
                Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: Transform(
                    transform: Matrix4.identity()
                      ..translateByDouble(dx, dy, 0, 1)
                      ..scaleByDouble(s, s, 1, 1),
                    child: child,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
