// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The main shell's vertical layout: optional chrome above (banners, top bar,
// views row), the tab body, optional status bar below. Fullscreen hides the
// chrome; the body must keep its element (and so every mpv player under the
// live wall) when that happens.

import 'package:flutter/widgets.dart';

/// Lays out [top] / [body] / [bottom] in a Column. When [chromeHidden] only
/// the body remains.
///
/// The body is KEYED. An unkeyed Column matches children by position and type,
/// so dropping the leading chrome widgets made the body's `Expanded` be
/// rebuilt from scratch: the whole Live wall was unmounted and every tile
/// opened a fresh libmpv player the moment fullscreen was entered. The key lets
/// the framework find the old body in the middle of the child list and reuse
/// it, so entering/leaving fullscreen only resizes the wall.
class ShellColumn extends StatelessWidget {
  const ShellColumn({
    super.key,
    required this.chromeHidden,
    required this.top,
    required this.body,
    this.bottom,
  });

  /// Stable identity of the body slot (exposed for tests).
  static const bodyKey = ValueKey<String>('shell-body');

  final bool chromeHidden;

  /// Chrome above the body; only called while the chrome is visible.
  final List<Widget> Function() top;
  final Widget body;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!chromeHidden) ...top(),
        Expanded(key: bodyKey, child: body),
        if (!chromeHidden && bottom != null) bottom!,
      ],
    );
  }
}
