/// Camera Frame Tap - Dart side of the vendored camera_windows
/// "ECOM PATCH(frame-tap)" channel.
///
/// The upstream Windows camera plugin exposes no image stream, so the
/// vendored plugin registers a private MethodChannel that serves the most
/// recent preview frame (raw BGRA) on demand. Preview keeps running during
/// recording, which is what lets the barcode scanner work mid-recording
/// (full wedge parity).
library;

import 'package:flutter/services.dart';

/// One grabbed preview frame: raw BGRA bytes (MFVideoFormat_RGB32 order,
/// unmirrored) plus pixel dimensions.
class GrabbedFrame {
  const GrabbedFrame({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// Grabs preview frames from the native frame tap. A returned null means
/// "no frame available right now" (camera not initialized, preview not
/// started yet, or plugin missing) - callers just try again.
class CameraFrameTap {
  CameraFrameTap({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ecom/camera_frame_tap');

  final MethodChannel _channel;

  /// Fetches the latest preview frame for [cameraId], or null when none is
  /// available. Never throws.
  Future<GrabbedFrame?> grabFrame(int cameraId) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabFrame',
        <String, Object?>{'cameraId': cameraId},
      );
      if (result == null) {
        return null;
      }
      final bytes = result['bytes'];
      final width = result['width'];
      final height = result['height'];
      if (bytes is! Uint8List || width is! int || height is! int) {
        return null;
      }
      if (width <= 0 || height <= 0 || bytes.length < width * height * 4) {
        return null;
      }
      return GrabbedFrame(bytes: bytes, width: width, height: height);
    } on PlatformException {
      // no_frame / no_camera / plugin absent - all mean "nothing to decode".
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
