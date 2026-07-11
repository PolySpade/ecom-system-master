/// Global keyboard-wedge barcode listener.
///
/// Installs a single top-level `HardwareKeyboard` handler (per RESEARCH.md
/// Pattern 2) that buffers character keystrokes and flushes on Enter,
/// mirroring the machine-speed timing of a USB barcode scanner acting as a
/// keyboard wedge. This handler is registered ONCE at app root (see
/// main.dart), not per-widget, so scans are captured regardless of which
/// widget currently has focus (BAR-01).
///
/// Focus-independence of `HardwareKeyboard.instance.addHandler` itself is
/// contested (Flutter issue #160786 reports the handler stops firing after
/// a TextField has been focused/edited on some 3.27/3.28 builds; status on
/// the project's installed 3.41.6 is unverified). This file implements the
/// primary mechanism only - the `Focus`-wrapper fallback lives in
/// main.dart, toggled by [useHardwareKeyboardBarcodeListener], so Plan 03's
/// hardware checkpoint can pick whichever mechanism actually works without
/// a code rewrite.
library;

import 'package:flutter/services.dart';

/// A callback invoked with the fully-scanned (and un-normalized) barcode
/// string once an Enter flush occurs with a non-empty buffer.
typedef BarcodeScannedCallback = void Function(String barcode);

/// Buffers keystrokes from [HardwareKeyboard] and flushes a full barcode on
/// Enter, discarding stale partial input if the inter-key gap exceeds
/// [interKeyTimeout].
///
/// Both scanner input (fast keystrokes + Enter) and any other source of
/// synthetic key events funnel through the same [_handleKey] path; the
/// resulting barcode is handed to [onBarcodeScanned], which callers wire
/// into the SAME `processBarcode` method manual entry already uses (BAR-02)
/// - this class does not duplicate any start/stop/DB orchestration.
class GlobalBarcodeListener {
  GlobalBarcodeListener({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Inter-key timeout: a gap larger than this between two keystrokes means
  /// the in-progress buffer is a stale partial scan and must be discarded
  /// before the new keystroke is appended (T-01-06 mitigation).
  static const Duration interKeyTimeout = Duration(milliseconds: 100);

  /// Injectable clock so the debounce/flush logic is unit-testable without
  /// real delays (defaults to [DateTime.now]).
  final DateTime Function() _clock;

  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyTime;

  BarcodeScannedCallback _onBarcodeScanned = (_) {};

  /// Sets the callback fired with the flushed barcode string whenever a
  /// non-empty buffer is flushed by Enter.
  set onBarcodeScanned(BarcodeScannedCallback callback) {
    _onBarcodeScanned = callback;
  }

  /// Registers [_handleKey] as a top-level `HardwareKeyboard` handler. Call
  /// once at app root, after the UI is built.
  void install() {
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  /// Removes the handler. Call on app teardown.
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
  }

  /// Handles a single hardware key event.
  ///
  /// - Only [KeyDownEvent]s are processed; [KeyUpEvent]/repeat events are
  ///   ignored entirely (returns false, does not touch the buffer/timer).
  /// - If the gap since the last processed keystroke exceeds
  ///   [interKeyTimeout], the buffer is cleared before the new character is
  ///   appended (stale partial scan discarded).
  /// - On [LogicalKeyboardKey.enter]: flushes the buffer (fires
  ///   [onBarcodeScanned] only if non-empty), clears it, and returns true to
  ///   consume the event so a focused TextField doesn't also submit
  ///   (T-01-05 mitigation).
  /// - On any other key: appends [KeyEvent.character] (when non-null and
  ///   non-empty) and returns false so normal typing still works.
  ///
  /// Public entry point to this same buffering/debounce/flush logic. Used
  /// both by unit tests and by the `Focus`-wrapper fallback path in
  /// main.dart (see [useHardwareKeyboardBarcodeListener]) so switching
  /// mechanisms never duplicates the buffer/flush behavior.
  bool handleKeyEvent(KeyEvent event) => _handleKey(event);

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    final now = _clock();
    if (_lastKeyTime != null && now.difference(_lastKeyTime!) > interKeyTimeout) {
      _buffer.clear();
    }
    _lastKeyTime = now;

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      final scanned = _buffer.toString();
      _buffer.clear();
      if (scanned.isNotEmpty) {
        _onBarcodeScanned(scanned);
      }
      return true;
    }

    final char = event.character;
    if (char != null && char.isNotEmpty) {
      _buffer.write(char);
    }
    return false;
  }
}
