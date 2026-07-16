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
/// the snapshot). Returns re-encoded JPEG bytes, or null if the image can't be
/// decoded (callers then fall back to the full frame).
///
/// The decode/crop/encode (all `package:image`, which is isolate-safe) runs on
/// a background isolate via [Isolate.run] so a full-frame JPEG doesn't freeze
/// the UI isolate. The closure captures only sendable data (the byte list + the
/// bbox doubles) and calls a top-level function.
Future<Uint8List?> cropPlateToBbox(Uint8List fullBytes, List<double> bbox) {
  return Isolate.run(() => cropPlateToBboxSync(fullBytes, bbox));
}

/// The synchronous crop, safe to run inside a background isolate. The rect is
/// clamped into the image so an out-of-range or degenerate box still yields a
/// crop.
Uint8List? cropPlateToBboxSync(Uint8List fullBytes, List<double> bbox) {
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
  return img.encodeJpg(cropped, quality: 90);
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
  final cropped = await cropPlateToBbox(fullBytes, bbox);
  _cachePut(key, cropped ?? _cropFailed);
  return cropped;
}

/// Read a previously computed crop synchronously, without computing one.
/// Returns null when absent or when a prior attempt failed.
Uint8List? peekPlateCrop(String key) {
  final hit = _plateCropCache[key];
  if (hit == null || identical(hit, _cropFailed)) return null;
  return hit;
}

void _cachePut(String key, Uint8List bytes) {
  if (_plateCropCache.containsKey(key)) {
    _plateCropOrder.remove(key);
  }
  _plateCropCache[key] = bytes;
  _plateCropOrder.add(key);
  while (_plateCropOrder.length > _plateCropCacheMax) {
    final evicted = _plateCropOrder.removeAt(0);
    _plateCropCache.remove(evicted);
  }
}
