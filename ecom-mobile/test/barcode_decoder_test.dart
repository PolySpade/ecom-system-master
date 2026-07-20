import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zxing_lib/zxing.dart';

import 'package:ecom_mobile/core/barcode_decoder.dart';

/// Renders a zxing BitMatrix (a real encoded barcode) into a BGRA frame the
/// way the native frame tap delivers preview frames: black modules on a
/// white background.
Uint8List bitMatrixToBgra(dynamic matrix) {
  final width = matrix.width as int;
  final height = matrix.height as int;
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = (matrix.get(x, y) as bool) ? 0 : 255;
      final o = (y * width + x) * 4;
      bytes[o] = v; // B
      bytes[o + 1] = v; // G
      bytes[o + 2] = v; // R
      bytes[o + 3] = 255; // A
    }
  }
  return bytes;
}

/// Rotates a BGRA frame 90 degrees clockwise.
(Uint8List, int, int) rotateBgra90(Uint8List src, int width, int height) {
  final dst = Uint8List(src.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final so = (y * width + x) * 4;
      final dx = height - 1 - y;
      final dy = x;
      final dstOffset = (dy * height + dx) * 4;
      dst.setRange(dstOffset, dstOffset + 4, src, so);
    }
  }
  return (dst, height, width);
}

void main() {
  group('decodeBgraFrame', () {
    test('decodes a horizontal Code 128 barcode from a BGRA frame', () {
      final matrix = MultiFormatWriter()
          .encode('ECOM-12345', BarcodeFormat.code128, 400, 120);
      final bgra = bitMatrixToBgra(matrix);

      final decoded = decodeBgraFrame(bgra, matrix.width, matrix.height);

      expect(decoded, 'ECOM-12345');
    });

    test('decodes a vertically-held (90-degree rotated) barcode', () {
      final matrix = MultiFormatWriter()
          .encode('ROT-777', BarcodeFormat.code128, 400, 120);
      final bgra = bitMatrixToBgra(matrix);
      final (rotated, w, h) = rotateBgra90(bgra, matrix.width, matrix.height);

      final decoded = decodeBgraFrame(rotated, w, h);

      expect(decoded, 'ROT-777');
    });

    test('decodes a QR code', () {
      final matrix = MultiFormatWriter()
          .encode('https://example.com/qr', BarcodeFormat.qrCode, 200, 200);
      final bgra = bitMatrixToBgra(matrix);

      final decoded = decodeBgraFrame(bgra, matrix.width, matrix.height);

      expect(decoded, 'https://example.com/qr');
    });

    test('returns null for a frame with no barcode', () {
      const width = 320;
      const height = 240;
      final random = Random(42);
      final noise = Uint8List.fromList(List<int>.generate(
        width * height * 4,
        (i) => (i + 1) % 4 == 0 ? 255 : random.nextInt(256),
      ));

      expect(decodeBgraFrame(noise, width, height), isNull);
    });
  });
}
