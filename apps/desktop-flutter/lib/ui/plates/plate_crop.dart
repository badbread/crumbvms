// Shared license-plate crop helper: crop a detection snapshot down to the
// plate's normalized bbox, off the UI isolate, with a small result cache.
//
// Used by the PDF report (plate_report_dialog.dart) and the Plates UI
// gallery/detail crop (plates_screen.dart) so all three share ONE crop
// implementation + cache rather than each re-deriving (and re-decoding) the
// same plate region.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Crop [fullBytes] to the normalized `[x, y, w, h]` [bbox] (fractions 0..1 of
/// the snapshot). Returns a `(jpegBytes, width, height)` record — the re-encoded
/// crop plus its true pixel dimensions — or null if the image can't be decoded
/// (callers then fall back to the full frame).
///
/// The width/height are the crop's ACTUAL pixels (`bbox.w · frameW` by
/// `bbox.h · frameH`), so `width / height` is the crop's real display aspect.
/// This is the authoritative aspect: the bbox fractions alone can't give it
/// without the snapshot's real dimensions (which vary by camera — never assume
/// 16:9), and callers must not re-derive it from a hard-coded frame aspect.
///
/// The decode/crop/encode (all `package:image`, which is isolate-safe) runs on
/// a background isolate via [Isolate.run] so a full-frame JPEG doesn't freeze
/// the UI isolate. The closure captures only sendable data (the byte list + the
/// bbox doubles) and calls a top-level function.
Future<(Uint8List, int, int)?> cropPlateToBbox(
  Uint8List fullBytes,
  List<double> bbox,
) {
  return Isolate.run(() => cropPlateToBboxSync(fullBytes, bbox));
}

/// The synchronous crop, safe to run inside a background isolate. The rect is
/// clamped into the image so an out-of-range or degenerate box still yields a
/// crop. Returns `(jpegBytes, width, height)` — see [cropPlateToBbox].
(Uint8List, int, int)? cropPlateToBboxSync(
  Uint8List fullBytes,
  List<double> bbox,
) {
  final decoded = img.decodeImage(fullBytes);
  if (decoded == null) return null;
  final w = decoded.width;
  final h = decoded.height;
  final cx = (bbox[0] * w).round().clamp(0, w - 1);
  final cy = (bbox[1] * h).round().clamp(0, h - 1);
  final cw = (bbox[2] * w).round().clamp(1, w - cx);
  final ch = (bbox[3] * h).round().clamp(1, h - cy);
  final cropped = img.copyCrop(decoded, x: cx, y: cy, width: cw, height: ch);
  // Defense-in-depth (issue #179): if the box landed on a near-black region
  // (a frame-mismatched box that points off the actual plate), treat it as a
  // failed crop so the caller falls back to the full frame instead of showing
  // a black thumbnail. The server-side fix (frame-consistent box) is the
  // primary guard; this catches any residual bad box. Non-destructive — the
  // full frame still contains the plate somewhere.
  if (_isNearlyBlack(cropped)) return null;
  return (img.encodeJpg(cropped, quality: 90), cropped.width, cropped.height);
}

/// True when [im] is almost entirely black — the signature of a crop box that
/// landed off the plate (on void/sky) rather than on the plate itself. Samples
/// a coarse grid (plate crops are small) and averages luminance; the threshold
/// is deliberately low so a legitimately dark night-time plate (which still has
/// IR/plate contrast) is not hidden.
bool _isNearlyBlack(img.Image im) {
  const step = 4;
  var sum = 0.0;
  var n = 0;
  for (var y = 0; y < im.height; y += step) {
    for (var x = 0; x < im.width; x += step) {
      final p = im.getPixel(x, y);
      sum += (p.r + p.g + p.b) / 3.0;
      n++;
    }
  }
  if (n == 0) return false;
  return (sum / n) < 10.0; // ~4% of 255 — only near-pure-black regions
}

// ─── result cache ──────────────────────────────────────────────────────────

/// Small process-wide cache of computed plate crops, keyed by a caller-supplied
/// string (a read id). Crops are the plate region only (small), so a modest
/// entry-count LRU is plenty; the point is to keep the decode/crop off the
/// widget rebuild path so a crop is computed once, not on every rebuild.
final Map<String, Uint8List> _plateCropCache = {};
final List<String> _plateCropOrder = []; // oldest first
const _plateCropCacheMax = 256;

/// The crop's true display aspect (`width / height`), keyed by the same read id
/// as [_plateCropCache] and evicted in lockstep with it. Populated by
/// [cachedPlateCrop] from the crop's real pixel dimensions so display code can
/// size the crop's slot to its OWN aspect without guessing the frame aspect.
final Map<String, double> _plateCropAspect = {};

/// Sentinel cached against a key when a crop was attempted but failed (bad
/// bytes / undecodable), so a doomed decode isn't retried on every rebuild.
/// Distinct from "not computed yet" (absent from the map).
final Uint8List _cropFailed = Uint8List(0);

/// Return the cached crop for [key], or compute it once from [fullBytes]+[bbox]
/// (off the UI isolate) and cache the result. Returns null when the crop failed
/// (the caller falls back to the full frame). Never does any network I/O.
Future<Uint8List?> cachedPlateCrop(
  String key,
  Uint8List fullBytes,
  List<double> bbox,
) async {
  final hit = _plateCropCache[key];
  if (hit != null) return identical(hit, _cropFailed) ? null : hit;
  final result = await cropPlateToBbox(fullBytes, bbox);
  if (result == null) {
    _cachePut(key, _cropFailed);
    return null;
  }
  final (bytes, cw, ch) = result;
  _cachePut(key, bytes);
  if (ch > 0) _plateCropAspect[key] = cw / ch;
  return bytes;
}

/// Read a previously computed crop synchronously, without computing one.
/// Returns null when absent or when a prior attempt failed.
Uint8List? peekPlateCrop(String key) {
  final hit = _plateCropCache[key];
  if (hit == null || identical(hit, _cropFailed)) return null;
  return hit;
}

/// The crop's real display aspect (`width / height`) for [key], or null if the
/// crop hasn't been computed yet or failed. Frame-aspect-independent — derived
/// from the crop's own pixels, so it is correct for any camera resolution.
double? peekPlateCropAspect(String key) => _plateCropAspect[key];

void _cachePut(String key, Uint8List bytes) {
  if (_plateCropCache.containsKey(key)) {
    _plateCropOrder.remove(key);
  }
  _plateCropCache[key] = bytes;
  _plateCropOrder.add(key);
  while (_plateCropOrder.length > _plateCropCacheMax) {
    final evicted = _plateCropOrder.removeAt(0);
    _plateCropCache.remove(evicted);
    _plateCropAspect.remove(evicted);
  }
}
