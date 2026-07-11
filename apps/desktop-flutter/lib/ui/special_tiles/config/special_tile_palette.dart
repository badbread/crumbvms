// Draggable palette of the seven special view-item types, for a view-designer
// screen's "drag onto a box" UX (VS_PALETTE / vsRenderPalette in app.js
// ~1071-1108). Unlike app.js's manual pointer-drag workaround (needed
// because Tauri/WebView2 swallowed HTML5 DnD), this uses Flutter's native
// `Draggable` — the host wraps each grid cell in a `DragTarget<SpecialTileType>`
// and, on accept, calls `SpecialTileSpec.defaultFor(type, ...)` to build the
// dropped spec (opening `showSpecialTileConfigSheet` next if
// `kSpecialTileConfigurable.contains(type)`, matching vsDragSpec's drop
// handler).
//
// This file only renders the drag SOURCE (the chip list) — the drop target
// lives on the host's existing grid cells, which this feature does not edit.

import 'package:flutter/material.dart';

import '../special_tile_spec.dart';

/// One draggable palette chip. `data` carries `SpecialTileType` so a
/// `DragTarget<SpecialTileType>` on a grid cell can accept it directly.
class SpecialTilePaletteChip extends StatelessWidget {
  const SpecialTilePaletteChip({super.key, required this.item});

  final SpecialTilePaletteItem item;

  @override
  Widget build(BuildContext context) {
    final chip = _ChipVisual(item: item);
    return Draggable<SpecialTileType>(
      data: item.type,
      feedback: Material(color: Colors.transparent, child: Opacity(opacity: 0.85, child: chip)),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: Tooltip(message: 'Drag "${item.label}" onto a box', child: chip),
    );
  }
}

/// The full palette, in `SpecialTilePaletteItem.all` order.
class SpecialTilePalette extends StatelessWidget {
  const SpecialTilePalette({super.key});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: SpecialTilePaletteItem.all
          .map((item) => SpecialTilePaletteChip(item: item))
          .toList(growable: false),
    );
  }
}

class _ChipVisual extends StatelessWidget {
  const _ChipVisual({required this.item});
  final SpecialTilePaletteItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2C30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3A3C40)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(item.icon, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 6),
          Text(item.label, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}
