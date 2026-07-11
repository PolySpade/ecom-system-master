/// App entry point / composition root.
///
/// Mirrors ecom-py's single-process singleton construction order:
/// config -> db -> camera -> handler, matching app_gui.py's logging setup
/// and instance construction (both entry points build their own handler
/// instances at startup).
library;

import 'package:flutter/material.dart';

import 'core/barcode_handler.dart';
import 'core/barcode_listener.dart';
import 'core/camera_service.dart';
import 'core/config.dart';
import 'core/database.dart';
import 'core/logger.dart';
import 'ui/main_screen.dart';

/// Toggle between the two candidate global-keyboard-capture mechanisms for
/// BAR-01 (RESEARCH.md Pitfall 2 / Flutter issue #160786 - focus-independence
/// of `HardwareKeyboard.instance.addHandler` is unverified on the installed
/// Flutter 3.41.6). Plan 03's hardware checkpoint decides which one actually
/// works on real scanner hardware; do NOT assume either outcome here.
///
/// - true  (default/primary): rely solely on [GlobalBarcodeListener]'s
///   top-level `HardwareKeyboard` handler.
/// - false (fallback): rely on the root `Focus` widget's `onKeyEvent`
///   instead, wrapping the same [GlobalBarcodeListener] buffering/debounce
///   logic via `_handleRootFocusKeyEvent`.
const bool useHardwareKeyboardBarcodeListener = true;

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
  final barcodeListener = GlobalBarcodeListener();

  runApp(
    EcomVideoTrackerApp(
      cameraService: cameraService,
      database: database,
      barcodeHandler: barcodeHandler,
      barcodeListener: barcodeListener,
    ),
  );
}

class EcomVideoTrackerApp extends StatefulWidget {
  const EcomVideoTrackerApp({
    super.key,
    required this.cameraService,
    required this.database,
    required this.barcodeHandler,
    required this.barcodeListener,
  });

  final CameraService cameraService;
  final AppDatabase database;
  final BarcodeHandler barcodeHandler;
  final GlobalBarcodeListener barcodeListener;

  @override
  State<EcomVideoTrackerApp> createState() => _EcomVideoTrackerAppState();
}

class _EcomVideoTrackerAppState extends State<EcomVideoTrackerApp> {
  /// Root focus node for the `Focus`-wrapper fallback (used only when
  /// [useHardwareKeyboardBarcodeListener] is false). Kept alive for the
  /// lifetime of the app so focus can be reclaimed after a dialog closes.
  final FocusNode _rootFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (useHardwareKeyboardBarcodeListener) {
      // Primary mechanism: top-level HardwareKeyboard handler, installed
      // once after the UI is built so it captures keystrokes regardless of
      // which widget (if any) currently has focus.
      widget.barcodeListener.install();
    }
  }

  @override
  void dispose() {
    if (useHardwareKeyboardBarcodeListener) {
      widget.barcodeListener.dispose();
    }
    _rootFocusNode.dispose();
    super.dispose();
  }

  /// Fallback path: routes a root-level key event through the SAME
  /// [GlobalBarcodeListener] buffering/debounce logic used by the primary
  /// `HardwareKeyboard` mechanism, so switching mechanisms never duplicates
  /// the buffer/flush behavior.
  KeyEventResult _handleRootFocusKeyEvent(FocusNode node, KeyEvent event) {
    final consumed = widget.barcodeListener.handleKeyEvent(event);
    return consumed ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: 'Ecom Video Tracker',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: MainScreen(
        cameraService: widget.cameraService,
        database: widget.database,
        barcodeHandler: widget.barcodeHandler,
        barcodeListener: widget.barcodeListener,
        rootFocusNode: useHardwareKeyboardBarcodeListener ? null : _rootFocusNode,
      ),
    );

    if (useHardwareKeyboardBarcodeListener) {
      return app;
    }

    // Fallback: wrap the app root in an autofocused Focus widget so keys
    // are captured here whenever nothing more specific has focus, and so
    // MainScreen can reclaim root focus after a dialog closes via
    // `rootFocusNode.requestFocus()`.
    return Focus(
      focusNode: _rootFocusNode,
      autofocus: true,
      onKeyEvent: _handleRootFocusKeyEvent,
      child: app,
    );
  }
}
