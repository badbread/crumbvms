// Static caption text tile (vs-cfg-text / vs-cfg-size in app.js's
// vsBuildConfigBody). Purely a rendering widget; editing happens through
// `SpecialTileConfigSheet` in ../config/special_tile_config_sheet.dart.

import 'package:flutter/material.dart';

import '../special_tile_spec.dart';

class TextTile extends StatelessWidget {
  const TextTile({super.key, required this.spec});

  final TextSpec spec;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: spec.text.trim().isEmpty
              ? Text(
                  'Empty text tile',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 14),
                )
              : Text(
                  spec.text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: spec.size,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}
