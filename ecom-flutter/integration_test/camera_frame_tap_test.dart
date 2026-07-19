/// On-device verification of the ECOM PATCH(frame-tap): grabs real preview
/// frames from the vendored camera_windows plugin, both idle and DURING an
/// active recording (the full-parity requirement of the camera barcode
/// scan design), and runs one frame through the zxing decode pipeline to
/// prove the BGRA plumbing end-to-end (no barcode in view -> null, no
/// crash).
///
/// Run with a camera attached:
///   flutter test integration_test/camera_frame_tap_test.dart -d windows
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ecom_flutter/core/barcode_decoder.dart';
import 'package:ecom_flutter/core/camera_frame_tap.dart';
import 'package:ecom_flutter/core/camera_service.dart';
import 'package:ecom_flutter/core/logger.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Logger logger;
  late CameraService service;
  final tap = CameraFrameTap();

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('frame_tap_hw_test_');
    logger = Logger('hw_test', '${tempDir.path}/logs/app.log');
    service = CameraService(tempDir.path, logger);
    await service.init(0);
    // Let the preview pump a few frames before grabbing.
    await Future<void>.delayed(const Duration(seconds: 2));
  });

  tearDownAll(() async {
    await service.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('grabs a preview frame while idle', () async {
    final id = service.cameraId;
    expect(id, isNotNull, reason: 'camera failed to initialize');

    final frame = await tap.grabFrame(id!);
    expect(frame, isNotNull, reason: 'frame tap returned no frame');
    expect(frame!.width, greaterThan(0));
    expect(frame.height, greaterThan(0));
    expect(frame.bytes.length, frame.width * frame.height * 4);
    // ignore: avoid_print
    print('idle frame: ${frame.width}x${frame.height}');
  });

  test('grabs a preview frame DURING recording (full parity)', () async {
    await service.startRecording('PARITY', label: 'Normal (Standard)');
    await Future<void>.delayed(const Duration(seconds: 1));

    final frame = await tap.grabFrame(service.cameraId!);

    expect(frame, isNotNull,
        reason: 'frame tap must keep serving frames mid-recording');
    expect(frame!.width, greaterThan(0));
    // ignore: avoid_print
    print('mid-recording frame: ${frame.width}x${frame.height}');

    final stop = await service.stopRecording(stopMethod: 'manual');
    expect(File(stop.videoPath).existsSync(), isTrue);
  });

  test('a grabbed frame runs through the zxing decode pipeline', () async {
    final frame = await tap.grabFrame(service.cameraId!);
    expect(frame, isNotNull);

    // No barcode is expected in view; the point is that a REAL camera
    // frame flows through BGRA->luminance->zxing without throwing. If a
    // barcode happens to be in view, decoding it is also a pass.
    final decoded = await decodeGrabbedFrame(frame!);
    // ignore: avoid_print
    print('decode result on live frame: ${decoded ?? '(none, as expected)'}');
  });
}
