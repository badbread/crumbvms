// Static image tile: renders the spec's downscaled `data:` URI
// (vsDownscaleImage-equivalent picking happens in image_tile_picker.dart).

import 'package:flutter/material.dart';

import '../special_tile_spec.dart';

class ImageTile extends StatelessWidget {
  const ImageTile({super.key, required this.spec});

  final ImageSpec spec;

  @override
  Widget build(BuildContext context) {
    final bytes = spec.bytes;
    return ColoredBox(
      color: Colors.black,
      child: bytes == null
          ? Center(
              child: Text(
                'No image set',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 14),
              ),
            )
          : Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => Center(
                child: Text(
                  'Could not decode image',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 14),
                ),
              ),
            ),
    );
  }
}
