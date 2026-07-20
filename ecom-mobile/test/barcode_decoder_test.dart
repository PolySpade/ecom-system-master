import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zxing_lib/zxing.dart';

import 'package:ecom_mobile/core/barcode_decoder.dart';

/// Renders a zxing BitMatrix (a real encoded barcode) into a luminance
/// frame the way the Android image stream delivers Y planes: black modules
/// on a white background, optionally with row-stride padding.
Uint8List bitMatrixToLuminance(dynamic matrix, {int stridePadding = 0}) {
  final width = matrix.width as int;
  final height = matrix.height as int;
  final rowStride = width + stridePadding;
  final bytes = Uint8List(rowStride * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      bytes[y * rowStride + x] = (matrix.get(x, y) as bool) ? 0 : 255;
    }
  }
  return bytes;
}

/// Rotates a luminance frame 90 degrees clockwise.
(Uint8List, int, int) rotateLuminance90(Uint8List src, int width, int height) {
  final dst = Uint8List(src.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = height - 1 - y;
      dst[x * height + dx] = src[y * width + x];
    }
  }
  return (dst, height, width);
}

void main() {
  group('decodeLuminanceFrame', () {
    test('decodes a horizontal Code 128 barcode from a Y plane', () {
      final matrix = MultiFormatWriter()
          .encode('ECOM-12345', BarcodeFormat.code128, 400, 120);
      final luminance = bitMatrixToLuminance(matrix);

      final decoded =
          decodeLuminanceFrame(luminance, matrix.width, matrix.height);

      expect(decoded, 'ECOM-12345');
    });

    test('decodes a Y plane with row-stride padding', () {
      final matrix = MultiFormatWriter()
          .encode('STRIDE-42', BarcodeFormat.code128, 400, 120);
      final padded = bitMatrixToLuminance(matrix, stridePadding: 64);

      final decoded = decodeLuminanceFrame(
        padded,
        matrix.width,
        matrix.height,
        rowStride: matrix.width + 64,
      );

      expect(decoded, 'STRIDE-42');
    });

    test('decodes a vertically-held (90-degree rotated) barcode', () {
      final matrix = MultiFormatWriter()
          .encode('ROT-777', BarcodeFormat.code128, 400, 120);
      final luminance = bitMatrixToLuminance(matrix);
      final (rotated, w, h) =
          rotateLuminance90(luminance, matrix.width, matrix.height);

      final decoded = decodeLuminanceFrame(rotated, w, h);

      expect(decoded, 'ROT-777');
    });

    test('decodes a QR code', () {
      final matrix = MultiFormatWriter()
          .encode('https://example.com/qr', BarcodeFormat.qrCode, 200, 200);
      final luminance = bitMatrixToLuminance(matrix);

      final decoded =
          decodeLuminanceFrame(luminance, matrix.width, matrix.height);

      expect(decoded, 'https://example.com/qr');
    });

    test('returns null for a frame with no barcode', () {
      const width = 320;
      const height = 240;
      final random = Random(42);
      final noise = Uint8List.fromList(List<int>.generate(
        width * height,
        (_) => random.nextInt(256),
      ));

      expect(decodeLuminanceFrame(noise, width, height), isNull);
    });
  });
}
