import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_mobile/core/camera_barcode_scanner.dart';
import 'package:ecom_mobile/core/grabbed_frame.dart';
import 'package:ecom_mobile/core/logger.dart';

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

  test('scans continuously until disarm() cancels the loop', () async {
    var decodeCalls = 0;
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async => testFrame(),
      decoder: (_) async {
        decodeCalls++;
        return null; // never decodes - loop must keep going
      },
      pollInterval: const Duration(milliseconds: 10),
    );

    scanner.arm();
    await waitUntil(() => decodeCalls >= 5, reason: 'continuous polling');
    expect(scanner.state.value.armed, isTrue);

    scanner.disarm();
    expect(scanner.state.value.armed, isFalse);
    final callsAtDisarm = decodeCalls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // At most the in-flight iteration finishes after disarm.
    expect(decodeCalls, lessThanOrEqualTo(callsAtDisarm + 1));
  });

  test('null frames (no preview yet) keep polling without decoding',
      () async {
    var grabs = 0;
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async {
        grabs++;
        return null;
      },
      decoder: (_) async => fail('decoder must not run without a frame'),
      pollInterval: const Duration(milliseconds: 10),
    );

    scanner.arm();
    await waitUntil(() => grabs > 3, reason: 'repeated grabs');
    scanner.disarm();
    expect(scanner.state.value.armed, isFalse);
  });

  test('arm() while already armed does not start a second loop', () async {
    var decodeCalls = 0;
    final scanned = <String>[];
    final scanner = CameraBarcodeScanner(
      logger,
      grabber: () async => testFrame(),
      decoder: (_) async {
        decodeCalls++;
        return decodeCalls >= 4 ? 'ONE' : null;
      },
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
      pollInterval: const Duration(milliseconds: 10),
    )..onBarcode = scanned.add;

    scanner.arm();
    await waitUntil(() => scanned.isNotEmpty, reason: 'recovery');
    expect(scanned, ['RECOVERED']);
  });
}
