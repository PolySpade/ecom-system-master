import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_flutter/core/camera_barcode_scanner.dart';
import 'package:ecom_flutter/core/camera_frame_tap.dart';
import 'package:ecom_flutter/core/logger.dart';

GrabbedFrame testFrame() =>
    GrabbedFrame(bytes: Uint8List(16), width: 2, height: 2);

Future<void> waitUntil(
  bool Function() condition, {
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Logger logger;

  setUp(() {
    final tempDir = 'camera_scanner_test';
    logger = Logger('test', p.join(tempDir, 'app.log'));
  });

  test('fires onBarcode once when a frame decodes, then disarms', () async {
    var decodeCalls = 0;
    final scanned = <String>[];
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async => testFrame(),
      decoder: (frame) async {
        decodeCalls++;
        return decodeCalls >= 2 ? 'CODE-99' : null;
      },
      scanWindow: const Duration(seconds: 3),
      pollInterval: const Duration(milliseconds: 10),
    )..onBarcode = scanned.add;

    scanner.arm();
    expect(scanner.state.value.armed, isTrue);

    await waitUntil(() => scanned.isNotEmpty, reason: 'barcode hit');
    // Give any (incorrect) extra loop iterations a chance to run.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(scanned, ['CODE-99']);
    expect(decodeCalls, 2);
    expect(scanner.state.value.armed, isFalse);
  });

  test('times out when nothing decodes and reports it', () async {
    var timedOut = false;
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async => testFrame(),
      decoder: (_) async => null,
      scanWindow: const Duration(milliseconds: 100),
      pollInterval: const Duration(milliseconds: 10),
    )..onTimeout = () => timedOut = true;

    scanner.arm();
    await waitUntil(() => timedOut, reason: 'timeout');
    expect(scanner.state.value.armed, isFalse);
  });

  test('null frames (no preview yet) keep polling until the window ends',
      () async {
    var grabs = 0;
    var timedOut = false;
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async {
        grabs++;
        return null;
      },
      decoder: (_) async => fail('decoder must not run without a frame'),
      scanWindow: const Duration(milliseconds: 80),
      pollInterval: const Duration(milliseconds: 10),
    )..onTimeout = () => timedOut = true;

    scanner.arm();
    await waitUntil(() => timedOut, reason: 'timeout');
    expect(grabs, greaterThan(1));
  });

  test('arm() while already armed extends the window without a second loop',
      () async {
    var decodeCalls = 0;
    final scanned = <String>[];
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async => testFrame(),
      decoder: (_) async {
        decodeCalls++;
        return decodeCalls >= 4 ? 'ONE' : null;
      },
      scanWindow: const Duration(seconds: 3),
      pollInterval: const Duration(milliseconds: 10),
    )..onBarcode = scanned.add;

    scanner.arm();
    scanner.arm(); // must not start a concurrent poll loop
    await waitUntil(() => scanned.isNotEmpty, reason: 'barcode hit');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // A second concurrent loop would have decoded a second 'ONE'.
    expect(scanned, ['ONE']);
  });

  test('decoder errors do not kill the poll loop', () async {
    var decodeCalls = 0;
    final scanned = <String>[];
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async => testFrame(),
      decoder: (_) async {
        decodeCalls++;
        if (decodeCalls == 1) throw StateError('bad frame');
        return 'RECOVERED';
      },
      scanWindow: const Duration(seconds: 3),
      pollInterval: const Duration(milliseconds: 10),
    )..onBarcode = scanned.add;

    scanner.arm();
    await waitUntil(() => scanned.isNotEmpty, reason: 'recovery');
    expect(scanned, ['RECOVERED']);
  });
}
