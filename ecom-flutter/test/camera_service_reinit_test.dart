/// Tests for CameraService.reinitialize robustness (SET-08).
///
/// The Windows Media Foundation device can stay "busy" for a few seconds
/// after the old controller is released, so the settings-driven restart
/// must (1) retry init instead of failing on the first attempt and
/// (2) leave the health monitor running even when every attempt fails, so
/// the camera recovers without an app restart.
library;

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_flutter/core/camera_service.dart';
import 'package:ecom_flutter/core/logger.dart';

/// CameraService whose [init] can be scripted to fail N times before
/// succeeding, without touching the real camera plugin.
class _FlakyInitCameraService extends CameraService {
  _FlakyInitCameraService(super.videoStoragePath, super.logger,
      {required this.failuresBeforeSuccess});

  /// How many init calls throw before one succeeds. Use a huge number to
  /// simulate a permanently failing device.
  int failuresBeforeSuccess;

  int initCalls = 0;

  @override
  Future<void> init(
    int cameraIndex, {
    ResolutionPreset resolutionPreset = ResolutionPreset.high,
    int? fps,
    int? videoBitrate,
  }) async {
    initCalls++;
    if (initCalls <= failuresBeforeSuccess) {
      throw CameraException(
        'camera_error',
        'Hardware MFT failed to start streaming due to lack of hardware '
            'resources.',
      );
    }
  }
}

void main() {
  late Directory tempDir;
  late Logger logger;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('camera_reinit_test_');
    logger = Logger('test', '${tempDir.path}/logs/app.log');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('reinitialize retries init and succeeds on a later attempt', () async {
    final service = _FlakyInitCameraService(tempDir.path, logger,
        failuresBeforeSuccess: 2);
    service.startHealthMonitor();

    await service.reinitialize(0);

    expect(service.initCalls, 3,
        reason: 'first two MFT-busy failures must be retried');
    expect(service.healthMonitorRunning, isTrue);
    service.stopHealthMonitor();
  });

  test(
      'reinitialize rethrows after all attempts but leaves the health '
      'monitor running so the camera can recover without an app restart',
      () async {
    final service = _FlakyInitCameraService(tempDir.path, logger,
        failuresBeforeSuccess: 1 << 30);
    service.startHealthMonitor();

    await expectLater(service.reinitialize(0), throwsA(isA<CameraException>()));

    expect(service.healthMonitorRunning, isTrue,
        reason: 'a failed settings reinit must not kill auto-recovery');
    service.stopHealthMonitor();
  });

  test('reinitialize succeeds first try and keeps the monitor running',
      () async {
    final service = _FlakyInitCameraService(tempDir.path, logger,
        failuresBeforeSuccess: 0);
    service.startHealthMonitor();

    await service.reinitialize(0);

    expect(service.initCalls, 1);
    expect(service.healthMonitorRunning, isTrue);
    service.stopHealthMonitor();
  });

  test('reinitialize does not start the monitor if it was not running',
      () async {
    final service = _FlakyInitCameraService(tempDir.path, logger,
        failuresBeforeSuccess: 0);

    await service.reinitialize(0);

    expect(service.healthMonitorRunning, isFalse);
  });
}
