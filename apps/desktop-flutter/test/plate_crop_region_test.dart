// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Content-correctness lock for cropPlateToBbox's engine-native decode path
// (issue #391). The crop used to be derived entirely with package:image; its
// pure-Dart JPEG decode of the full frame (~130 ms at 1080p, ~260 ms at 4 MP,
// per newly-mounted benchmark row) was the Engine Benchmark's measured
// client-side bottleneck, so cropPlateToBbox now decodes with the engine's
// native codec and rasterizes only the bbox region. These tests pin that the
// fast path still crops the RIGHT region with the right dimensions, agrees
// with the pure-Dart reference implementation (cropPlateToBboxSync), and
// keeps the near-black rejection semantics.

import 'dart:typed_data';

import 'package:crumb_desktop/ui/plates/plate_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A [w]x[h] mid-gray JPEG with a solid red rectangle covering exactly the
/// normalized [bbox] — cropping to that bbox must yield an all-red image.
Uint8List _frameWithRedBox(int w, int h, List<double> bbox) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(128, 128, 128));
  final x0 = (bbox[0] * w).round(), y0 = (bbox[1] * h).round();
  final x1 = x0 + (bbox[2] * w).round(), y1 = y0 + (bbox[3] * h).round();
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      im.setPixelRgb(x, y, 220, 30, 30);
    }
  }
  return img.encodeJpg(im, quality: 95);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bbox = [0.25, 0.5, 0.25, 0.125];

  test('engine path crops the correct region at the correct dimensions',
      () async {
    final frame = _frameWithRedBox(640, 360, bbox);
    final res = await cropPlateToBbox(frame, bbox);
    expect(res, isNotNull);
    final (bytes, cw, ch) = res!;
    expect(cw, 160); // 0.25 * 640
    expect(ch, 45); // 0.125 * 360
    final crop = img.decodeImage(bytes)!;
    expect(crop.width, 160);
    expect(crop.height, 45);
    // The bbox region is solid red — if the fast path cropped the right
    // pixels, red must dominate; a mis-mapped rect would pull in gray.
    var r = 0.0, g = 0.0, n = 0;
    for (var y = 0; y < crop.height; y += 3) {
      for (var x = 0; x < crop.width; x += 3) {
        final p = crop.getPixel(x, y);
        r += p.r.toDouble();
        g += p.g.toDouble();
        n++;
      }
    }
    expect(r / n, greaterThan(180), reason: 'crop should be the red region');
    expect(g / n, lessThan(90), reason: 'crop should not include gray frame');
  });

  test('engine path agrees with the pure-Dart reference on dimensions',
      () async {
    // Deliberately non-16:9 and an out-of-range box — the clamping must match.
    const wild = [0.9, 0.85, 0.4, 0.4];
    final frame = _frameWithRedBox(500, 500, const [0.9, 0.85, 0.1, 0.15]);
    final fast = await cropPlateToBbox(frame, wild);
    final reference = cropPlateToBboxSync(frame, wild);
    expect(fast, isNotNull);
    expect(reference, isNotNull);
    expect(fast!.$2, reference!.$2);
    expect(fast.$3, reference.$3);
  });

  test('engine path still rejects a near-black crop', () async {
    // Gray frame with a BLACK box at the bbox: the crop lands on near-pure
    // black, which plate_crop must reject (null) so callers fall back to the
    // full frame instead of showing a black thumbnail (issue #179 semantics).
    final im = img.Image(width: 640, height: 360);
    img.fill(im, color: img.ColorRgb8(128, 128, 128));
    final x0 = (bbox[0] * 640).round(), y0 = (bbox[1] * 360).round();
    for (var y = y0; y < y0 + (bbox[3] * 360).round(); y++) {
      for (var x = x0; x < x0 + (bbox[2] * 640).round(); x++) {
        im.setPixelRgb(x, y, 0, 0, 0);
      }
    }
    final frame = img.encodeJpg(im, quality: 95);
    expect(await cropPlateToBbox(frame, bbox), isNull);
  });

  test('undecodable bytes fall back and still return null, not a throw',
      () async {
    final garbage = Uint8List.fromList(List.filled(64, 7));
    expect(await cropPlateToBbox(garbage, bbox), isNull);
  });
}
