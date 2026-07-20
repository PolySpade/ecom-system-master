/// Barcode Decoder - zxing_lib decode of raw BGRA preview frames.
///
/// Pure functions so the heavy work can run in a background isolate via
/// [decodeGrabbedFrame]. All common formats are enabled (Code 128/39,
/// EAN/UPC, QR, DataMatrix, ...) per the camera-scan design; a 90-degree
/// rotated retry handles vertically-held 1D codes, which zxing's tryHarder
/// does not cover for row-scanning readers.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:zxing_lib/common.dart';
import 'package:zxing_lib/zxing.dart';

import 'camera_frame_tap.dart';

/// Frames wider than this are 2x-downsampled before decoding - a 4K frame
/// is ~8M pixels and zxing's cost is linear in pixels, while barcode
/// modules at packing-station distance are comfortably larger than 2px.
const int _kDownscaleThresholdWidth = 1600;

/// Decodes the first barcode found in a raw BGRA frame; null when none.
///
/// Synchronous and isolate-friendly (no platform channels, no Flutter
/// bindings) - production callers should prefer [decodeGrabbedFrame].
String? decodeBgraFrame(Uint8List bgra, int width, int height) {
  var luminance = _bgraToLuminance(bgra, width, height);
  var w = width;
  var h = height;

  while (w > _kDownscaleThresholdWidth) {
    (luminance, w, h) = _downscale2x(luminance, w, h);
  }

  final direct = _decodeLuminance(luminance, w, h);
  if (direct != null) {
    return direct;
  }

  // Retry rotated 90 degrees for vertically-held 1D barcodes.
  final (rotated, rw, rh) = _rotate90(luminance, w, h);
  return _decodeLuminance(rotated, rw, rh);
}

/// Isolate wrapper around [decodeBgraFrame] so decoding a full preview
/// frame never janks the UI or the recording pipeline.
Future<String?> decodeGrabbedFrame(GrabbedFrame frame) {
  final bytes = frame.bytes;
  final width = frame.width;
  final height = frame.height;
  return Isolate.run(() => decodeBgraFrame(bytes, width, height));
}

String? _decodeLuminance(Uint8List luminance, int width, int height) {
  final source = RGBLuminanceSource.orig(width, height, luminance);
  final bitmap = BinaryBitmap(HybridBinarizer(source));
  try {
    final result = MultiFormatReader().decode(
      bitmap,
      const DecodeHint(tryHarder: true),
    );
    final text = result.text;
    return text.isEmpty ? null : text;
  } on ReaderException {
    return null;
  }
}

/// BGRA -> luminance using zxing's own green-favouring weights.
Uint8List _bgraToLuminance(Uint8List bgra, int width, int height) {
  final pixels = width * height;
  final luminance = Uint8List(pixels);
  for (var i = 0; i < pixels; i++) {
    final o = i * 4;
    final b = bgra[o];
    final g = bgra[o + 1];
    final r = bgra[o + 2];
    luminance[i] = (r + (g << 1) + b) ~/ 4;
  }
  return luminance;
}

(Uint8List, int, int) _downscale2x(Uint8List src, int width, int height) {
  final w = width ~/ 2;
  final h = height ~/ 2;
  final dst = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row0 = (y * 2) * width;
    final row1 = row0 + width;
    for (var x = 0; x < w; x++) {
      final x0 = x * 2;
      dst[y * w + x] =
          (src[row0 + x0] + src[row0 + x0 + 1] + src[row1 + x0] +
                  src[row1 + x0 + 1]) >>
              2;
    }
  }
  return (dst, w, h);
}

(Uint8List, int, int) _rotate90(Uint8List src, int width, int height) {
  final dst = Uint8List(src.length);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    final dx = height - 1 - y;
    for (var x = 0; x < width; x++) {
      dst[x * height + dx] = src[row + x];
    }
  }
  return (dst, height, width);
}
