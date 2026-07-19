/// Camera Barcode Scanner - button-armed continuous scan loop over the frame tap.
///
/// arm() opens a continuous scan loop and polls grab -> decode until a
/// barcode hit occurs, or the scanner is disarmed/disposed. The decoded value
/// feeds the SAME processBarcode path the USB wedge uses (full parity) - this
/// class does no start/stop/DB orchestration of its own, mirroring how
/// GlobalBarcodeListener is a pure input source.
///
/// Injectable grabber/decoder seams follow the VideoCompressor pattern so
/// the loop is unit-testable without a camera or zxing.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'camera_frame_tap.dart';
import 'logger.dart';

/// Fetches the latest preview frame (null = none available right now).
typedef FrameGrabber = Future<GrabbedFrame?> Function();

/// Decodes a frame to a barcode string (null = no barcode in frame).
typedef FrameDecoder = Future<String?> Function(GrabbedFrame frame);

/// Published scan state for the UI.
class CameraScanState {
  const CameraScanState({required this.armed});

  static const idle = CameraScanState(armed: false);

  final bool armed;

  @override
  bool operator ==(Object other) =>
      other is CameraScanState && other.armed == armed;

  @override
  int get hashCode => armed.hashCode;
}

/// Button-armed camera barcode scanner.
class CameraBarcodeScanner {
  CameraBarcodeScanner(
    this._logger, {
    required FrameGrabber grabber,
    required FrameDecoder decoder,
    this.pollInterval = const Duration(milliseconds: 250),
  }) : _grabber = grabber,
       _decoder = decoder;

  final Logger _logger;
  final FrameGrabber _grabber;
  final FrameDecoder _decoder;

  /// Delay between grab/decode attempts.
  final Duration pollInterval;

  /// Fired with the decoded barcode (exactly once per arm).
  void Function(String barcode)? onBarcode;

  /// Live armed state for the UI.
  final ValueNotifier<CameraScanState> state = ValueNotifier<CameraScanState>(
    CameraScanState.idle,
  );

  bool _looping = false;
  bool _disposed = false;

  /// Arms the scanner: starts the continuous scan loop. Only
  /// one poll loop ever runs regardless of how many times this is called.
  void arm() {
    if (_disposed || _looping) {
      return;
    }
    _looping = true;
    state.value = const CameraScanState(armed: true);
    _logger.info('Camera scan armed (continuous)');
    unawaited(_loop());
  }

  Future<void> _loop() async {
    try {
      while (!_disposed && _looping) {
        try {
          final frame = await _grabber();
          if (frame != null) {
            final barcode = await _decoder(frame);
            if (barcode != null && barcode.isNotEmpty) {
              _logger.info('Camera scan decoded: $barcode');
              disarm();
              onBarcode?.call(barcode);
              return;
            }
          }
        } catch (e) {
          // A bad frame/decode must never kill the scan loop.
          _logger.warning('Camera scan attempt failed: $e');
        }
        await Future<void>.delayed(pollInterval);
      }
    } finally {
      disarm();
    }
  }

  /// Manually stops the active scan loop and resets state to idle.
  void disarm() {
    _looping = false;
    if (!_disposed && state.value.armed) {
      state.value = CameraScanState.idle;
    }
  }

  /// Stops any active loop and silences callbacks.
  void dispose() {
    _disposed = true;
    _looping = false;
  }
}
