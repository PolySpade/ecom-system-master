import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_flutter/core/barcode_handler.dart';

void main() {
  group('BarcodeHandler.validateBarcode', () {
    late BarcodeHandler handler;

    setUp(() {
      handler = BarcodeHandler();
    });

    test('returns false for null', () {
      expect(handler.validateBarcode(null), isFalse);
    });

    test('returns false for empty string', () {
      expect(handler.validateBarcode(''), isFalse);
    });

    test('returns false for whitespace-only string', () {
      expect(handler.validateBarcode('   '), isFalse);
    });

    test('returns true for a normal string', () {
      expect(handler.validateBarcode('abc'), isTrue);
    });
  });

  group('BarcodeHandler.processBarcode', () {
    late BarcodeHandler handler;

    setUp(() {
      handler = BarcodeHandler();
    });

    test('start action when not recording, trims and uppercases', () {
      final result = handler.processBarcode('  abc123 ', isRecording: false);
      expect(result.action, BarcodeAction.start);
      expect(result.barcode, 'ABC123');
      expect(handler.lastBarcode, 'ABC123');
    });

    test('stopAndStart action when recording', () {
      final result = handler.processBarcode('abc', isRecording: true);
      expect(result.action, BarcodeAction.stopAndStart);
      expect(result.barcode, 'ABC');
    });

    test('invalid action for empty barcode regardless of recording state', () {
      final result = handler.processBarcode('', isRecording: false);
      expect(result.action, BarcodeAction.invalid);
    });

    test('invalid action does not update lastBarcode', () {
      handler.processBarcode('FIRST', isRecording: false);
      handler.processBarcode('', isRecording: false);
      expect(handler.lastBarcode, 'FIRST');
    });

    test('only three actions exist (no standalone stop)', () {
      // Compile-time guarantee: BarcodeAction has exactly these 3 values.
      expect(BarcodeAction.values, [
        BarcodeAction.start,
        BarcodeAction.stopAndStart,
        BarcodeAction.invalid,
      ]);
    });
  });
}
