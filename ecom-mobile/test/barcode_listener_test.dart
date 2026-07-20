import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_mobile/core/barcode_listener.dart';

/// Builds a synthetic [KeyDownEvent] for [key], optionally with a
/// [character] (as a real scanner keystroke would produce).
KeyDownEvent _keyDown(LogicalKeyboardKey key, {String? character}) {
  return KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    character: character,
    timeStamp: Duration.zero,
  );
}

KeyUpEvent _keyUp(LogicalKeyboardKey key) {
  return KeyUpEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    timeStamp: Duration.zero,
  );
}

KeyRepeatEvent _keyRepeat(LogicalKeyboardKey key, {String? character}) {
  return KeyRepeatEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    character: character,
    timeStamp: Duration.zero,
  );
}

LogicalKeyboardKey _charKey(String c) =>
    LogicalKeyboardKey(c.codeUnitAt(0));

void main() {
  group('GlobalBarcodeListener', () {
    late DateTime now;
    late GlobalBarcodeListener listener;
    late List<String> scanned;

    DateTime clock() => now;

    void advance(Duration d) => now = now.add(d);

    setUp(() {
      now = DateTime(2026, 1, 1, 12, 0, 0);
      listener = GlobalBarcodeListener(clock: clock);
      scanned = [];
      listener.onBarcodeScanned = scanned.add;
    });

    test('A, B, C then Enter fires onBarcodeScanned exactly once with "ABC"', () {
      listener.handleKeyEvent(_keyDown(_charKey('A'), character: 'A'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(_charKey('B'), character: 'B'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(_charKey('C'), character: 'C'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(LogicalKeyboardKey.enter));

      expect(scanned, ['ABC']);
    });

    test('after Enter the buffer is empty: subsequent X + Enter yields "X"', () {
      listener.handleKeyEvent(_keyDown(_charKey('A'), character: 'A'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(_charKey('B'), character: 'B'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(_charKey('C'), character: 'C'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(LogicalKeyboardKey.enter));

      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(_charKey('X'), character: 'X'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(LogicalKeyboardKey.enter));

      expect(scanned, ['ABC', 'X']);
    });

    test('gap exceeding 100ms resets the buffer before appending the new char', () {
      listener.handleKeyEvent(_keyDown(_charKey('A'), character: 'A'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(_charKey('B'), character: 'B'));

      // Stale gap - simulates a paused/interrupted scan.
      advance(const Duration(milliseconds: 150));
      listener.handleKeyEvent(_keyDown(_charKey('C'), character: 'C'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(LogicalKeyboardKey.enter));

      // Buffer should have been reset before 'C' was appended, so only "C"
      // is flushed - not "ABC".
      expect(scanned, ['C']);
    });

    test('Enter with an empty buffer does NOT fire the callback', () {
      listener.handleKeyEvent(_keyDown(LogicalKeyboardKey.enter));
      expect(scanned, isEmpty);
    });

    test('_handleKey returns true for the flushing Enter, false for character keys', () {
      final charResult = listener.handleKeyEvent(
        _keyDown(_charKey('A'), character: 'A'),
      );
      expect(charResult, isFalse);

      advance(const Duration(milliseconds: 10));
      final enterResult = listener.handleKeyEvent(
        _keyDown(LogicalKeyboardKey.enter),
      );
      expect(enterResult, isTrue);
    });

    test('only KeyDownEvent is processed - KeyUp is ignored', () {
      listener.handleKeyEvent(_keyDown(_charKey('A'), character: 'A'));
      advance(const Duration(milliseconds: 10));
      // A KeyUp for the same char must not be appended to the buffer nor
      // reset timing state in a way that breaks the subsequent flush.
      final upResult = listener.handleKeyEvent(_keyUp(_charKey('A')));
      expect(upResult, isFalse);

      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(_charKey('B'), character: 'B'));
      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(LogicalKeyboardKey.enter));

      expect(scanned, ['AB']);
    });

    test('only KeyDownEvent is processed - KeyRepeat is ignored', () {
      listener.handleKeyEvent(_keyDown(_charKey('A'), character: 'A'));
      advance(const Duration(milliseconds: 10));
      final repeatResult = listener.handleKeyEvent(
        _keyRepeat(_charKey('A'), character: 'A'),
      );
      expect(repeatResult, isFalse);

      advance(const Duration(milliseconds: 10));
      listener.handleKeyEvent(_keyDown(LogicalKeyboardKey.enter));

      // Repeat must not have been appended - only the single 'A' from the
      // initial KeyDownEvent should be in the flushed barcode.
      expect(scanned, ['A']);
    });
  });
}
