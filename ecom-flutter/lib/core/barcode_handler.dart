/// Barcode Handler - Validates barcode strings and decides the recording
/// action to take (start / stop-and-start / invalid).
///
/// Direct behavioral port of ecom-py/barcode_handler.py. Only three actions
/// exist: start, stopAndStart, invalid. There is NO standalone "stop" action
/// here - manual stop is a completely separate code path handled by the UI
/// layer (camera_service.dart / main_screen.dart), not routed through this
/// state machine.
library;

/// The action BarcodeHandler.processBarcode decided to take.
enum BarcodeAction { start, stopAndStart, invalid }

/// Result of processing a barcode submission.
class BarcodeResult {
  const BarcodeResult({required this.action, required this.barcode});

  final BarcodeAction action;
  final String barcode;
}

/// Validates barcode strings and decides start/stopAndStart/invalid actions.
class BarcodeHandler {
  /// The last barcode successfully processed (normalized), or null if none.
  String? lastBarcode;

  /// Returns true when [barcode] is non-null and non-empty after trimming.
  /// No format/checksum validation is performed (matches REC-05).
  bool validateBarcode(String? barcode) {
    if (barcode == null) return false;
    final trimmed = barcode.trim();
    if (trimmed.isEmpty) return false;
    return true;
  }

  /// Processes a raw barcode submission and returns the action to take.
  ///
  /// Normalization order: (1) validate, (2) trim + uppercase, (3) return
  /// action. Normalization happens only after validation passes.
  BarcodeResult processBarcode(String barcode, {required bool isRecording}) {
    if (!validateBarcode(barcode)) {
      return BarcodeResult(action: BarcodeAction.invalid, barcode: barcode);
    }

    final normalized = barcode.trim().toUpperCase();
    lastBarcode = normalized;

    if (isRecording) {
      return BarcodeResult(
        action: BarcodeAction.stopAndStart,
        barcode: normalized,
      );
    }

    return BarcodeResult(action: BarcodeAction.start, barcode: normalized);
  }

  /// Returns the last successfully processed barcode, or null if none.
  String? getLastBarcode() => lastBarcode;
}
