// Image-tile "choose file" helper: pick an image file, downscale it, and
// return a `data:image/png;base64,...` URI to store in an `ImageSpec`. Port
// of vsDownscaleImage (apps/desktop/src/app.js ~854), reimplemented on
// `dart:ui` (no extra image-codec package needed) since Flutter's
// `instantiateImageCodec` already does the decode+resize we need; the source
// file's format doesn't matter, only the decoded/re-encoded PNG bytes do.
//
// PLATFORM DEPENDENCY: file selection needs a picker plugin — this file is
// written against `file_selector` (https://pub.dev/packages/file_selector),
// the well-known cross-platform Flutter plugin recommended for desktop file
// dialogs (no custom Rust/FFI). It is NOT yet in pubspec.yaml — see this
// feature's integration notes for the exact dependency line to add.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

import 'package:crumb_desktop/ui/fullscreen/native_picker_guard.dart';

/// Open a native "choose image" dialog, downscale the result so the longest
/// side is at most [maxDim] px (matches vsDownscaleImage's `maxDim=1280`
/// default used by the view-item config panel), and return a PNG `data:` URI
/// sized for storage in a saved view's jsonb `slots` column. Returns null if
/// the user cancelled or the file couldn't be decoded as an image.
Future<String?> pickAndDownscaleImage({int maxDim = 1280}) async {
  const typeGroup = XTypeGroup(
    label: 'images',
    extensions: ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'],
  );
  // Fullscreen-safe: the native open dialog can otherwise freeze the app
  // behind a borderless fullscreen window (see runNativePicker).
  final file = await runNativePicker(
    () => openFile(acceptedTypeGroups: const [typeGroup]),
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return downscaleImageBytes(bytes, maxDim: maxDim);
}

/// Decode arbitrary image [bytes], downscale so the longest side is at most
/// [maxDim] px (no upscaling), and re-encode as a PNG `data:` URI. Returns
/// null if the bytes can't be decoded as an image.
Future<String?> downscaleImageBytes(Uint8List bytes, {required int maxDim}) async {
  ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
  } catch (_) {
    return null;
  }
  final frame = await codec.getNextFrame();
  final src = frame.image;
  final scale = (maxDim / (src.width > src.height ? src.width : src.height)).clamp(0.0, 1.0);
  final targetW = (src.width * scale).round().clamp(1, src.width);
  final targetH = (src.height * scale).round().clamp(1, src.height);

  ui.Image outImage = src;
  if (scale < 1.0) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final srcRect = ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble());
    final dstRect = ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble());
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
    canvas.drawImageRect(src, srcRect, dstRect, paint);
    final picture = recorder.endRecording();
    outImage = await picture.toImage(targetW, targetH);
  }

  final byteData = await outImage.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) return null;
  final pngBytes = byteData.buffer.asUint8List();
  return 'data:image/png;base64,${base64Encode(pngBytes)}';
}
