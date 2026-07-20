/// Grabbed Frame - one luminance (grayscale) preview frame for barcode
/// decoding.
///
/// On Android the camera image stream delivers YUV420 frames; the Y plane
/// IS the luminance channel, so [bytes] holds it directly (no color
/// conversion needed). [rowStride] is the Y plane's bytes-per-row, which
/// can exceed [width] on devices that pad rows - the decoder strips the
/// padding.
library;

import 'dart:typed_data';

/// One luminance frame plus its geometry.
class GrabbedFrame {
  const GrabbedFrame({
    required this.bytes,
    required this.width,
    required this.height,
    int? rowStride,
  }) : rowStride = rowStride ?? width;

  /// Y-plane (luminance) bytes, [rowStride] bytes per row.
  final Uint8List bytes;

  final int width;
  final int height;

  /// Bytes per row in [bytes]; >= [width].
  final int rowStride;
}
