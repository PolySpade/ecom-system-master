/// Main Screen - preview + manual barcode entry + Stop button + recordings
/// list.
///
/// Ports the process_barcode orchestration from ecom-py/app_gui.py: the
/// stop-then-start sequential ordering for stopAndStart, the Stop button's
/// disabled-while-idle rule (REC-03), and the live preview independent of
/// recording state (CAM-01).
library;

import 'package:flutter/material.dart';

import '../core/barcode_handler.dart';
import '../core/barcode_listener.dart';
import '../core/camera_service.dart';
import '../core/config.dart';
import '../core/database.dart';
import '../models/transaction.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.cameraService,
    required this.database,
    required this.barcodeHandler,
    required this.barcodeListener,
    required this.config,
    this.rootFocusNode,
  });

  final CameraService cameraService;
  final AppDatabase database;
  final BarcodeHandler barcodeHandler;

  /// Live config (Phase 4): supplies videoStoragePath for the Search
  /// screen's path resolution and the shared SettingsManager for the
  /// Settings screen.
  final Config config;

  /// The global scanner listener (BAR-01). MainScreen wires its
  /// [GlobalBarcodeListener.onBarcodeScanned] callback into the exact same
  /// [_submitBarcode] path manual entry uses (BAR-02) - no duplicated
  /// start/stop/DB orchestration.
  final GlobalBarcodeListener barcodeListener;

  /// Non-null only when main.dart's `Focus`-wrapper fallback is active
  /// (see `useHardwareKeyboardBarcodeListener`); used to reclaim root
  /// focus after a dialog closes so scanning keeps working.
  final FocusNode? rootFocusNode;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _barcodeController = TextEditingController();
  final _focusNode = FocusNode();

  int? _currentTransactionId;
  String? _statusMessage;
  List<Transaction> _recentTransactions = [];

  @override
  void initState() {
    super.initState();
    _refreshRecentTransactions();
    // Route scanner-sourced barcodes into the SAME processBarcode path
    // manual entry uses (BAR-02) - no duplicated orchestration.
    widget.barcodeListener.onBarcodeScanned = _handleScannedBarcode;
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Entry point for scanner-sourced barcodes (BAR-01). Populates the same
  /// text field the manual path reads from, then submits through the
  /// identical [_submitBarcode] method.
  void _handleScannedBarcode(String barcode) {
    _barcodeController.text = barcode;
    _submitBarcode();
  }

  /// Reclaims root focus after a dialog closes, when the `Focus`-wrapper
  /// fallback is active (see main.dart's `useHardwareKeyboardBarcodeListener`).
  /// No-op when the primary HardwareKeyboard mechanism is in use.
  void _reclaimRootFocus() {
    widget.rootFocusNode?.requestFocus();
  }

  Future<void> _refreshRecentTransactions() async {
    final recent = await widget.database.getRecentTransactions(limit: 10);
    if (!mounted) return;
    setState(() => _recentTransactions = recent);
  }

  Future<void> _showErrorDialog(String title, String message) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    // Reclaim root focus after the dialog closes so scanning keeps working
    // under the Focus-wrapper fallback (no-op under the primary mechanism).
    _reclaimRootFocus();
  }

  Future<void> _submitBarcode() async {
    final rawBarcode = _barcodeController.text;
    final result = widget.barcodeHandler.processBarcode(
      rawBarcode,
      isRecording: widget.cameraService.isRecording,
    );

    if (result.action == BarcodeAction.invalid) {
      await _showErrorDialog(
        'Invalid Barcode',
        'The barcode entered is invalid',
      );
      return;
    }

    try {
      if (result.action == BarcodeAction.start) {
        final filename = await widget.cameraService.startRecording(
          result.barcode,
        );
        _currentTransactionId = await widget.database.createTransaction(
          result.barcode,
          filename,
        );
        setState(() {
          _statusMessage = 'Recording started: ${result.barcode}';
        });
      } else if (result.action == BarcodeAction.stopAndStart) {
        // Stop MUST complete before the new start begins (sequential,
        // matching ecom-py's process_barcode orchestration).
        final stopResult = await widget.cameraService.stopRecording(
          stopMethod: 'barcode',
        );
        if (_currentTransactionId != null) {
          await widget.database.completeTransaction(
            _currentTransactionId!,
            durationSeconds: stopResult.duration,
            fileSizeMb: stopResult.fileSizeMb,
            stopMethod: 'barcode',
          );
        }

        final newFilename = await widget.cameraService.startRecording(
          result.barcode,
        );
        _currentTransactionId = await widget.database.createTransaction(
          result.barcode,
          newFilename,
        );
        setState(() {
          _statusMessage =
              'Switched to: ${result.barcode} (Saved: ${stopResult.duration}s)';
        });
      }

      _barcodeController.clear();
      _focusNode.requestFocus();
      await _refreshRecentTransactions();
      setState(() {});
    } catch (e) {
      await _showErrorDialog('Error', 'Failed to process barcode: $e');
    }
  }

  Future<void> _manualStop() async {
    if (!widget.cameraService.isRecording) {
      await _showErrorDialog('Not Recording', 'No recording in progress');
      return;
    }

    try {
      final stopResult = await widget.cameraService.stopRecording(
        stopMethod: 'manual',
      );
      if (_currentTransactionId != null) {
        await widget.database.completeTransaction(
          _currentTransactionId!,
          durationSeconds: stopResult.duration,
          fileSizeMb: stopResult.fileSizeMb,
          stopMethod: 'manual',
        );
        _currentTransactionId = null;
      }
      setState(() {
        _statusMessage = 'Recording stopped (${stopResult.duration}s)';
      });
      await _refreshRecentTransactions();
    } catch (e) {
      await _showErrorDialog('Error', 'Failed to stop recording: $e');
    }
  }

  /// Builds the RECORDING overlay (CAM-03). Conditionally rendered - not
  /// always-present-and-hidden (matches PATTERNS.md's camera panel
  /// convention) - and absent from the widget tree entirely while idle.
  /// Reads filename/label from cameraService.currentFilename/currentLabel,
  /// the single source of truth for the in-progress recording (Plan 01-01
  /// Task 3); MainScreen does not keep its own copy of this state.
  Widget? _buildRecordingOverlay() {
    final isRecording = widget.cameraService.isRecording;
    final filename = widget.cameraService.currentFilename;
    if (!isRecording || filename == null) return null;

    final label = widget.cameraService.currentLabel ?? '';

    return Positioned(
      top: 8,
      right: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 6),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
            Text(
              'RECORDING: $filename [$label]',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens a full-screen child route (Search/Settings) with the global
  /// scanner callback suspended, so a scan on the child screen cannot start
  /// a recording behind it. Restores routing + root focus + rebuilds on
  /// return (the camera may have been reinitialized by Settings).
  Future<void> _openChildScreen(Widget screen) async {
    widget.barcodeListener.onBarcodeScanned = (_) {};
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => screen),
    );
    widget.barcodeListener.onBarcodeScanned = _handleScannedBarcode;
    _reclaimRootFocus();
    if (mounted) setState(() {});
  }

  void _openSearch() {
    _openChildScreen(SearchScreen(
      database: widget.database,
      videoStoragePath: widget.config.videoStoragePath,
    ));
  }

  void _openSettings() {
    _openChildScreen(SettingsScreen(
      settingsManager: widget.config.settingsManager,
      cameraService: widget.cameraService,
    ));
  }

  /// Preview area (CAM-01/CAM-02): scales continuously with window resizes
  /// while preserving the camera's aspect ratio, via AspectRatio inside a
  /// FittedBox/Center within an Expanded region.
  Widget _buildPreviewArea() {
    final overlay = _buildRecordingOverlay();

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: widget.cameraService.aspectRatio,
                child: widget.cameraService.buildPreview(),
              ),
            ),
            ?overlay,
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = widget.cameraService.isRecording;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ecom Video Tracker'),
        // Phase 4 entry points - kept to a minimal, isolated diff because
        // Phase 2 is redesigning this screen.
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search Recordings',
            onPressed: _openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: _buildPreviewArea(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _barcodeController,
                    focusNode: _focusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Barcode',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submitBarcode(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _submitBarcode,
                  child: const Text('Submit'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: isRecording ? _manualStop : null,
                  child: const Text('Stop Recording'),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 8),
              Text(_statusMessage!),
            ],
            const SizedBox(height: 16),
            Expanded(
              flex: 2,
              child: ListView.builder(
                itemCount: _recentTransactions.length,
                itemBuilder: (context, index) {
                  final t = _recentTransactions[index];
                  return ListTile(
                    title: Text(t.barcode),
                    subtitle: Text(t.videoFilename),
                    trailing: Text(t.stopMethod ?? 'in progress'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
