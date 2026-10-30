// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Draws one tile of a scrub sprite strip (see scrub_sprite_cache.dart),
// scaled to fit like the per-frame overlay (`BoxFit.contain`).

import 'package:flutter/widgets.dart';

import 'scrub_sprite_cache.dart';

class ScrubSpriteTileView extends StatelessWidget {
  const ScrubSpriteTileView({super.key, required this.tile});

  final ScrubSpriteTile tile;

  @override
  Widget build(BuildContext context) {
    final s = tile.sprite;
    // FittedBox lays the strip out at its natural size, the Align/ClipRect
    // pair cuts that down to one tile, and FittedBox scales the tile up to
    // the pane. gaplessPlayback keeps the previous strip on screen while the
    // next segment's JPEG decodes, so crossing a segment never flashes.
    return FittedBox(
      fit: BoxFit.contain,
      child: ClipRect(
        child: Align(
          alignment: Alignment(tile.alignX, tile.alignY),
          widthFactor: 1 / s.columns,
          heightFactor: 1 / s.rows,
          child: Image.memory(
            s.bytes,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}
