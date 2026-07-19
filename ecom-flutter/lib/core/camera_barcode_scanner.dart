/// Camera Barcode Scanner - button-armed scan loop over the frame tap.
///
/// arm() opens a bounded scan window and polls grab -> decode until the
/// first barcode hit or the window expires. The decoded value feeds the
/// SAME processBarcode path the USB wedge uses (full parity) - this class
/// does no start/stop/DB orchestration of its own, mirroring how
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

/// Published scan state for the UI (button highlight + countdown).
class CameraScanState {
  const CameraScanState({required this.armed, this.secondsLeft = 0});

  static const idle = CameraScanState(armed: false);

  final bool armed;
  final int secondsLeft;

  @override
  bool operator ==(Object other) =>
      other is CameraScanState &&
      other.armed == armed &&
      other.secondsLeft == secondsLeft;

  @override
  int get hashCode => Object.hash(armed, secondsLeft);
}

/// Button-armed camera barcode scanner.
class CameraBarcodeScanner {
  CameraBarcodeScanner(
    this._logger, {
    required FrameGrabber grabber,
    required FrameDecoder decoder,
    this.scanWindow = const Duration(seconds: 6),
    this.pollInterval = const Duration(milliseconds: 250),
  })  : _grabber = grabber,
        _decoder = decoder;

  final Logger _logger;
  final FrameGrabber _grabber;
  final FrameDecoder _decoder;

  /// How long a single arm() keeps scanning before giving up.
  final Duration scanWindow;

  /// Delay between grab/decode attempts.
  final Duration pollInterval;

  /// Fired with the decoded barcode (exactly once per arm window).
  void Function(String barcode)? onBarcode;

  /// Fired when the scan window expires without a hit.
  void Function()? onTimeout;

  /// Live armed/countdown state for the UI.
  final ValueNotifier<CameraScanState> state =
      ValueNotifier<CameraScanState>(CameraScanState.idle);

  DateTime _deadline = DateTime.fromMillisecondsSinceEpoch(0);
  bool _looping = false;
  bool _disposed = false;

  /// Arms (or re-arms) the scanner: the scan window restarts from now. Only
  /// one poll loop ever runs regardless of how many times this is called.
  void arm() {
    if (_disposed) {
      return;
    }
    _deadline = DateTime.now().add(scanWindow);
    _publish();
    if (_looping) {
      return;
    }
    _looping = true;
    _logger.info('Camera scan armed (${scanWindow.inSeconds}s window)');
    unawaited(_loop());
  }

  Future<void> _loop() async {
    try {
      while (!_disposed && DateTime.now().isBefore(_deadline)) {
        _publish();
        try {
          final frame = await _grabber();
          if (frame != null) {
            final barcode = await _decoder(frame);
            if (barcode != null && barcode.isNotEmpty) {
              _logger.info('Camera scan decoded: $barcode');
              _disarm();
              onBarcode?.call(barcode);
              return;
            }
          }
        } catch (e) {
          // A bad frame/decode must never kill the scan window.
          _logger.warning('Camera scan attempt failed: $e');
        }
        await Future<void>.delayed(pollInterval);
      }
      if (!_disposed) {
        _logger.info('Camera scan window expired without a barcode');
        _disarm();
        onTimeout?.call();
      }
    } finally {
      _looping = false;
    }
  }

  void _disarm() {
    _looping = false;
    _deadline = DateTime.fromMillisecondsSinceEpoch(0);
    if (!_disposed) {
      state.value = CameraScanState.idle;
    }
  }

  void _publish() {
    if (_disposed) {
      return;
    }
    final remaining = _deadline.difference(DateTime.now());
    state.value = CameraScanState(
      armed: remaining > Duration.zero,
      secondsLeft: remaining.isNegative ? 0 : (remaining.inMilliseconds / 1000).ceil(),
    );
  }

  /// Stops any active loop and silences callbacks.
  void dispose() {
    _disposed = true;
    _deadline = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
