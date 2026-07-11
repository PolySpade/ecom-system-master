/// App entry point / composition root.
///
/// Mirrors ecom-py's single-process singleton construction order:
/// config -> db -> camera -> handler, matching app_gui.py's logging setup
/// and instance construction (both entry points build their own handler
/// instances at startup).
library;

import 'package:flutter/material.dart';

import 'core/barcode_handler.dart';
import 'core/camera_service.dart';
import 'core/config.dart';
import 'core/database.dart';
import 'core/logger.dart';
import 'ui/main_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = Config.load();

  final logger = Logger('ecom_flutter', '${config.logPath}/app.log');
  logger.info('Application starting');

  final database = await AppDatabase.open(config.databasePath, logger);

  final cameraService = CameraService(config.videoStoragePath, logger);
  try {
    await cameraService.init(config.cameraIndex);
  } catch (e) {
    logger.error('Error initializing camera: $e');
  }

  final barcodeHandler = BarcodeHandler();

  runApp(
    EcomVideoTrackerApp(
      cameraService: cameraService,
      database: database,
      barcodeHandler: barcodeHandler,
    ),
  );
}

class EcomVideoTrackerApp extends StatelessWidget {
  const EcomVideoTrackerApp({
    super.key,
    required this.cameraService,
    required this.database,
    required this.barcodeHandler,
  });

  final CameraService cameraService;
  final AppDatabase database;
  final BarcodeHandler barcodeHandler;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ecom Video Tracker',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: MainScreen(
        cameraService: cameraService,
        database: database,
        barcodeHandler: barcodeHandler,
      ),
    );
  }
}
