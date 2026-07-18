// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression lock for the plate-crop DISPLAY ASPECT.
//
// This has been re-broken repeatedly by deriving the crop's on-screen aspect
// from the read's normalized bbox times a hard-coded frame aspect (16:9):
//
//     aspect = (bbox.w / bbox.h) * (16 / 9)   // WRONG
//
// The bbox is in frame FRACTIONS, so that is only right when the snapshot really
// is 16:9. On a 4:3 or square camera the crop slot is the wrong shape and the
// plate stretches / floats between letterbox bars — the recurring "plate crops
// don't scale right" bug.
//
// The durable rule: the crop's aspect MUST come from the crop image's OWN
// pixels. cropPlateToBboxSync returns the true (width, height); cachedPlateCrop
// caches width/height and exposes it via peekPlateCropAspect. These tests pin
// that invariant on deliberately NON-16:9 frames, so any reintroduced
// frame-aspect guess (16:9 or otherwise) fails here instead of shipping.

import 'dart:typed_data';

import 'package:crumb_desktop/ui/plates/plate_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A solid mid-gray JPEG of [w]x[h] — non-black so the crop isn't rejected by
/// plate_crop's near-black guard, uniform so JPEG re-encode preserves the exact
/// dimensions the aspect math depends on.
Uint8List _solidJpeg(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(180, 180, 180));
  return img.encodeJpg(im, quality: 95);
}

/// The aspect the OLD, buggy code produced from the bbox fractions alone.
double _legacy16x9Guess(double bw, double bh) => (bw / bh) * (16 / 9);

void main() {
  test('crop dims come from real pixels on a square (non-16:9) frame', () {
    final frame = _solidJpeg(400, 400); // 1:1 — nothing like 16:9
    // Plate region: half the frame width, a quarter of its height.
    final res = cropPlateToBboxSync(frame, const [0.25, 0.25, 0.5, 0.25]);
    expect(res, isNotNull);
    final (bytes, w, h) = res!;
    expect(bytes, isNotEmpty);
    expect(w, 200); // 0.5 * 400
    expect(h, 100); // 0.25 * 400
    final realAspect = w / h; // 2.0
    expect(realAspect, closeTo(2.0, 0.001));
    // The regression guard: the legacy 16:9-derived guess would be ~3.56, and
    // would mis-shape the slot. The real pixel aspect must NOT equal it.
    expect(realAspect, isNot(closeTo(_legacy16x9Guess(0.5, 0.25), 0.05)));
  });

  test('crop aspect is frame-correct on a 4:3 frame', () {
    final frame = _solidJpeg(800, 600); // 4:3
    final res = cropPlateToBboxSync(frame, const [0.1, 0.4, 0.4, 0.1]);
    expect(res, isNotNull);
    final (_, w, h) = res!;
    expect(w, 320); // 0.4 * 800
    expect(h, 60); //  0.1 * 600
    expect(w / h, closeTo(320 / 60, 0.001)); // 5.333, the true pixel aspect
    // Legacy guess would be (0.4/0.1)*(16/9) = 7.11 — must NOT match.
    expect(w / h, isNot(closeTo(_legacy16x9Guess(0.4, 0.1), 0.1)));
  });

  test('cachedPlateCrop populates peekPlateCropAspect with the real aspect',
      () async {
    final frame = _solidJpeg(400, 400);
    const key = 'test-read-square';
    expect(peekPlateCropAspect(key), isNull); // nothing computed yet
    final crop = await cachedPlateCrop(key, frame, const [0.25, 0.25, 0.5, 0.25]);
    expect(crop, isNotNull);
    final aspect = peekPlateCropAspect(key);
    expect(aspect, isNotNull);
    // Real pixels (2.0), not the 16:9 guess (~3.56).
    expect(aspect!, closeTo(2.0, 0.001));
  });
}
