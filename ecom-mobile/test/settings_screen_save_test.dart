/// Repro test for "settings do not apply immediately after Save & Apply".
///
/// Drives the real SettingsScreen: changes capture-affecting settings,
/// taps Save & Apply, then asserts (1) the changed values are persisted to
/// settings.json and (2) CameraService.reinitialize() is invoked with the
/// new values (SET-08).
library;

import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'package:ecom_mobile/core/camera_service.dart';
import 'package:ecom_mobile/core/database.dart';
import 'package:ecom_mobile/core/logger.dart';
import 'package:ecom_mobile/core/settings_manager.dart';
import 'package:ecom_mobile/ui/settings_screen.dart';

class _FakeCameraService extends CameraService {
  _FakeCameraService(super.videoStoragePath, super.logger);

  int reinitCalls = 0;
  int? lastCameraIndex;
  ResolutionPreset? lastPreset;
  int? lastFps;
  int? lastVideoBitrate;

  @override
  Future<void> reinitialize(
    int cameraIndex, {
    ResolutionPreset resolutionPreset = ResolutionPreset.high,
    int? fps,
    int? videoBitrate,
  }) async {
    reinitCalls++;
    lastCameraIndex = cameraIndex;
    lastPreset = resolutionPreset;
    lastFps = fps;
    lastVideoBitrate = videoBitrate;
  }
}

void main() {
  late Directory tempDir;
  late Logger logger;
  late SettingsManager settingsManager;
  late _FakeCameraService cameraService;
  late AppDatabase database;

  setUpAll(() {
    ffi.sqfliteFfiInit();
    databaseFactory = ffi.databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('settings_screen_test_');
    logger = Logger('test', '${tempDir.path}/logs/app.log');
    settingsManager =
        SettingsManager(p.join(tempDir.path, 'settings.json'), logger: logger);
    cameraService = _FakeCameraService(tempDir.path, logger);
    database = await AppDatabase.open('${tempDir.path}/database.db', logger);
  });

  tearDown(() async {
    await database.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        settingsManager: settingsManager,
        cameraService: cameraService,
        database: database,
      ),
    ));
    // Let _refreshCameras / FfmpegLocator futures resolve.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
      'Save & Apply persists changed FPS and reinitializes the camera',
      (tester) async {
    await pumpSettings(tester);

    // Change FPS 30 -> 60 on the Video tab (scroll it into view first -
    // the quick-presets block above pushes it below the test viewport).
    await tester.ensureVisible(find.text('60 FPS'));
    await tester.pump();
    await tester.tap(find.text('60 FPS'));
    await tester.pump();

    // Save & Apply.
    await tester.tap(find.text('Save & Apply'));
    await tester.pump(); // starts _saveSettings
    await tester.pump(const Duration(milliseconds: 50)); // progress dialog
    await tester.pump(const Duration(milliseconds: 50)); // reinit completes

    // The settings file must contain the new FPS.
    final file = File(p.join(tempDir.path, 'settings.json'));
    expect(file.existsSync(), isTrue,
        reason: 'settings.json should be written by Save & Apply');
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect((saved['video'] as Map)['fps'], 60,
        reason: 'changed FPS must be persisted');

    // Capture-affecting change -> camera reinitialized with new fps.
    expect(cameraService.reinitCalls, 1,
        reason: 'camera must be reinitialized after capture-affecting save');
    expect(cameraService.lastFps, 60);

    // Confirmation dialog appears; dismiss it and the screen pops.
    expect(find.text('Settings Saved'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'Save & Apply with only non-capture settings does not reinitialize',
      (tester) async {
    await pumpSettings(tester);

    // Toggle watermark off on the Watermark tab.
    await tester.tap(find.text('Watermark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Burn watermark into videos'));
    await tester.pump();

    await tester.tap(find.text('Save & Apply'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final file = File(p.join(tempDir.path, 'settings.json'));
    expect(file.existsSync(), isTrue);
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect((saved['video'] as Map)['watermark_enabled'], false);

    expect(cameraService.reinitCalls, 0,
        reason: 'no capture-affecting change -> no camera restart');

    expect(find.text('Settings Saved'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'Low-end PC quick preset fills the form and persists via Save & Apply',
      (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text('Low-end PC'));
    await tester.pump();

    // The affected dropdowns must visibly reflect the preset.
    expect(find.text('4 Mbit/s'), findsOneWidget);

    await tester.tap(find.text('Save & Apply'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // progress dialog
    await tester.pump(const Duration(milliseconds: 50)); // reinit completes

    final file = File(p.join(tempDir.path, 'settings.json'));
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final video = saved['video'] as Map;
    expect(video['resolution_width'], 1280);
    expect(video['resolution_height'], 720);
    expect(video['fps'], 30);
    expect(video['recording_bitrate_kbps'], 4000);

    // Bitrate changed from the 6000 default -> capture-affecting -> reinit
    // with the preset's bitrate.
    expect(cameraService.reinitCalls, 1);
    expect(cameraService.lastVideoBitrate, 4000 * 1000);

    expect(find.text('Settings Saved'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'edits made on one tab survive switching tabs before Save & Apply',
      (tester) async {
    await pumpSettings(tester);

    // Change FPS on Video tab, then visit Camera tab and come back.
    // Bounded pumps instead of pumpAndSettle: the Camera tab keeps an
    // animation alive in the test environment.
    await tester.ensureVisible(find.text('60 FPS'));
    await tester.pump();
    await tester.tap(find.text('60 FPS'));
    await tester.pump();
    await tester.tap(find.text('Camera'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Video'));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Save & Apply'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final file = File(p.join(tempDir.path, 'settings.json'));
    final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect((saved['video'] as Map)['fps'], 60,
        reason: 'tab switch must not lose pending edits');
  });
}
