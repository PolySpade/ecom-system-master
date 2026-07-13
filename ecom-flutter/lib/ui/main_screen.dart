/// Main Screen - preview + Video Label selection + barcode entry + Stop
/// button + live status panel + recent-recordings list + status bar.
///
/// Ports the main-window orchestration from ecom-py/app_gui.py: the
/// stop-then-start sequential ordering for stopAndStart (via a serialized
/// ScanQueue so scans arriving during a save are queued, REC-04), the
/// non-dismissible "Saving Recording..." dialog, label routing (REC-06),
/// the disk-space guard before recording start (STO-02), the System Status
/// panel with a 1s refresh (UI-01/DB-03), the last-10 recordings list with
/// Open File / Show in Folder (UI-02/STO-03), the 5s auto-clearing status
/// bar (UI-03), and the exit confirmation that stops-and-saves (REC-07).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/barcode_handler.dart';
import '../core/barcode_listener.dart';
import '../core/camera_service.dart';
import '../core/config.dart';
import '../core/database.dart';
import '../core/disk_space.dart';
import '../core/file_paths.dart';
import '../core/scan_queue.dart';
import '../core/watermark_service.dart';
import '../models/transaction.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

/// ecom-py identity colors (UI-04).
const Color _kSuccessColor = Color(0xFF10B981);
const Color _kDangerColor = Color(0xFFDC2626);

/// The three Video Label options, in ecom-py's dropdown order (REC-06).
const List<String> _kLabelOptions = [
  'Return and Refund Unboxing',
  'Return Parcel Unboxing',
  'Normal (Standard)',
];

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.cameraService,
    required this.database,
    required this.barcodeHandler,
    required this.barcodeListener,
    required this.watermarkService,
    required this.videoStoragePath,
    required this.minFreeSpaceGb,
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

  /// Post-save watermark worker (REC-06 watermark parity). Phase 3 chains
  /// the compression queue onto its job Futures.
  final WatermarkService watermarkService;

  /// Resolved videos root - used by the disk guard and Open File actions.
  final String videoStoragePath;

  /// Free-space floor (GB) below which recording start is blocked (STO-02).
  final double minFreeSpaceGb;

  /// Non-null only when main.dart's `Focus`-wrapper fallback is active
  /// (see `useHardwareKeyboardBarcodeListener`); used to reclaim root
  /// focus after a dialog closes so scanning keeps working.
  final FocusNode? rootFocusNode;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WindowListener {
  final _barcodeController = TextEditingController();
  final _focusNode = FocusNode();

  late final ScanQueue _scanQueue;

  int? _currentTransactionId;
  String _selectedLabel = 'Normal (Standard)';
  List<Transaction> _recentTransactions = [];

  String _statusBarText = 'Ready';
  Timer? _statusBarTimer;
  Timer? _ticker;
  double _storageUsedMb = 0;

  bool _savingDialogVisible = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _scanQueue = ScanQueue(_processBarcodeInput);
    _refreshRecentTransactions();

    // Route scanner-sourced barcodes into the SAME processBarcode path
    // manual entry uses (BAR-02) - no duplicated orchestration.
    widget.barcodeListener.onBarcodeScanned = _handleScannedBarcode;

    // Camera reinit + salvage hooks (CAM-04).
    widget.cameraService.onCameraStateChanged = _onCameraStateChanged;
    widget.cameraService.onRecordingSalvaged = _onRecordingSalvaged;

    // Watermark queue status hook (feeds the status panel).
    widget.watermarkService.onQueueChanged = _onWatermarkQueueChanged;

    // 1s refresh: duration ticker + storage used (UI-01/DB-03).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshStorageUsed();
      if (mounted) setState(() {});
    });

    // Exit confirmation (REC-07/UI-02): main() enables setPreventClose;
    // onWindowClose below decides whether to stop-and-save first.
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _ticker?.cancel();
    _statusBarTimer?.cancel();
    _barcodeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Window close (REC-07)
  // ---------------------------------------------------------------------

  @override
  void onWindowClose() async {
    if (_exiting) return;

    if (!widget.cameraService.isRecording) {
      _exiting = true;
      await windowManager.destroy();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recording in Progress'),
        content: const Text('A recording is in progress. Stop and exit?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kDangerColor),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop and Exit'),
          ),
        ],
      ),
    );
    _reclaimRootFocus();
    if (confirmed != true) return;

    _exiting = true;
    try {
      // Serialize with any in-flight scan so the stop can't interleave.
      await _scanQueue.submitAction(() async {
        if (!widget.cameraService.isRecording) return;
        final stopResult =
            await widget.cameraService.stopRecording(stopMethod: 'manual');
        if (_currentTransactionId != null) {
          await widget.database.completeTransaction(
            _currentTransactionId!,
            durationSeconds: stopResult.duration,
            fileSizeMb: stopResult.fileSizeMb,
            stopMethod: 'manual',
          );
          _currentTransactionId = null;
        }
        // Watermarking is deliberately skipped on exit: the app is closing
        // and would kill the FFmpeg process mid-write. The video itself is
        // saved (never lose the video).
      });
    } catch (_) {
      // The video file is already on disk at this point; exit regardless.
    }
    await windowManager.destroy();
  }

  // ---------------------------------------------------------------------
  // Service callbacks
  // ---------------------------------------------------------------------

  void _onCameraStateChanged() {
    if (mounted) setState(() {});
  }

  void _onWatermarkQueueChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _onRecordingSalvaged(StopRecordingResult result) async {
    if (_currentTransactionId != null) {
      await widget.database.completeTransaction(
        _currentTransactionId!,
        durationSeconds: result.duration,
        fileSizeMb: result.fileSizeMb,
        stopMethod: 'camera_failure',
      );
      _currentTransactionId = null;
    }
    _enqueueWatermark(result);
    if (!mounted) return;
    _setStatusBar(
      'Camera failure - recording saved (${result.duration}s)',
    );
    await _refreshRecentTransactions();
  }

  // ---------------------------------------------------------------------
  // Data refresh
  // ---------------------------------------------------------------------

  Future<void> _refreshRecentTransactions() async {
    final recent = await widget.database.getRecentTransactions(limit: 10);
    if (!mounted) return;
    setState(() => _recentTransactions = recent);
  }

  Future<void> _refreshStorageUsed() async {
    final mb = await widget.database.getTotalStorageUsed();
    if (!mounted) return;
    _storageUsedMb = mb;
  }

  // ---------------------------------------------------------------------
  // Status bar (UI-03)
  // ---------------------------------------------------------------------

  void _setStatusBar(String message) {
    _statusBarTimer?.cancel();
    setState(() => _statusBarText = message);
    _statusBarTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _statusBarText = 'Ready');
    });
  }

  // ---------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------

  /// Reclaims root focus after a dialog closes, when the `Focus`-wrapper
  /// fallback is active (see main.dart's `useHardwareKeyboardBarcodeListener`).
  /// No-op when the primary HardwareKeyboard mechanism is in use.
  void _reclaimRootFocus() {
    widget.rootFocusNode?.requestFocus();
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

  /// Non-dismissible "Saving Recording..." progress dialog (REC-04).
  void _showSavingDialog() {
    if (_savingDialogVisible || !mounted) return;
    _savingDialogVisible = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('Saving Recording...'),
            ],
          ),
        ),
      ),
    );
  }

  void _closeSavingDialog() {
    if (!_savingDialogVisible || !mounted) return;
    _savingDialogVisible = false;
    Navigator.of(context, rootNavigator: true).pop();
    _reclaimRootFocus();
  }

  // ---------------------------------------------------------------------
  // Disk guard (STO-02)
  // ---------------------------------------------------------------------

  /// Returns true when recording may start. Blocks (dialog) below the
  /// configured floor; warns (status bar) when merely low.
  Future<bool> _checkDiskSpaceForStart() async {
    final freeGb = getFreeSpaceGb(widget.videoStoragePath);
    final status =
        evaluateDiskSpace(freeGb, minFreeGb: widget.minFreeSpaceGb);
    if (status == DiskSpaceStatus.critical) {
      await _showErrorDialog(
        'Low Disk Space',
        'Cannot start recording: only ${freeGb!.toStringAsFixed(2)} GB free '
        '(minimum ${widget.minFreeSpaceGb.toStringAsFixed(1)} GB). '
        'Free up disk space and try again.',
      );
      return false;
    }
    if (status == DiskSpaceStatus.low) {
      _setStatusBar(
        'Warning: low disk space (${freeGb!.toStringAsFixed(1)} GB free)',
      );
    }
    return true;
  }

  // ---------------------------------------------------------------------
  // Recording orchestration
  // ---------------------------------------------------------------------

  /// Entry point for scanner-sourced barcodes (BAR-01). Populates the same
  /// text field the manual path reads from, then submits through the
  /// identical [_submitBarcode] method.
  void _handleScannedBarcode(String barcode) {
    _barcodeController.text = barcode;
    _submitBarcode();
  }

  /// Submits the barcode field through the serialized [ScanQueue]: a scan
  /// arriving while a save is in progress is queued, not dropped (REC-04).
  void _submitBarcode() {
    final raw = _barcodeController.text;
    _barcodeController.clear();
    _focusNode.requestFocus();

    if (raw.trim().isEmpty) {
      _showErrorDialog('Input Required', 'Please enter a barcode');
      return;
    }

    unawaited(_scanQueue.submit(raw));
  }

  /// Processes one barcode end-to-end. Runs on the ScanQueue's serialized
  /// lane - never concurrently with another scan or a manual stop.
  Future<void> _processBarcodeInput(String rawBarcode) async {
    final selectedLabel = _selectedLabel;
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
        if (!await _checkDiskSpaceForStart()) return;
        final videoPath = await widget.cameraService.startRecording(
          result.barcode,
          label: selectedLabel,
        );
        _currentTransactionId = await widget.database.createTransaction(
          result.barcode,
          p.basename(videoPath),
          label: selectedLabel,
        );
        _setStatusBar(
          'Recording started: ${result.barcode} ($selectedLabel)',
        );
      } else if (result.action == BarcodeAction.stopAndStart) {
        // Stop MUST complete before the new start begins (sequential,
        // matching ecom-py's process_barcode orchestration).
        final stopResult = await _stopAndSave('barcode');

        if (!await _checkDiskSpaceForStart()) {
          // The previous recording is safely saved; only the new start is
          // blocked.
          return;
        }
        final newVideoPath = await widget.cameraService.startRecording(
          result.barcode,
          label: selectedLabel,
        );
        _currentTransactionId = await widget.database.createTransaction(
          result.barcode,
          p.basename(newVideoPath),
          label: selectedLabel,
        );
        _setStatusBar(
          'Switched to: ${result.barcode} ($selectedLabel) '
          '(Saved: ${stopResult.duration}s)',
        );
      }

      await _refreshRecentTransactions();
      if (mounted) setState(() {});
    } catch (e) {
      await _showErrorDialog('Error', 'Failed to process barcode: $e');
    }
  }

  /// Stops the active recording behind the non-dismissible saving dialog,
  /// completes the DB row, and enqueues the post-save watermark job
  /// (non-blocking: the next scan does not wait for FFmpeg).
  Future<StopRecordingResult> _stopAndSave(String stopMethod) async {
    _showSavingDialog();
    try {
      final stopResult = await widget.cameraService.stopRecording(
        stopMethod: stopMethod,
      );
      if (_currentTransactionId != null) {
        await widget.database.completeTransaction(
          _currentTransactionId!,
          durationSeconds: stopResult.duration,
          fileSizeMb: stopResult.fileSizeMb,
          stopMethod: stopMethod,
        );
        _currentTransactionId = null;
      }
      _enqueueWatermark(stopResult);
      return stopResult;
    } finally {
      _closeSavingDialog();
    }
  }

  /// Fire-and-forget: watermarking runs on the WatermarkService's own
  /// serialized worker so it never delays the next scan. Phase 3 chains
  /// compression onto this same Future.
  void _enqueueWatermark(StopRecordingResult stopResult) {
    unawaited(
      widget.watermarkService
          .enqueue(
            WatermarkJob(
              videoPath: stopResult.videoPath,
              barcode: stopResult.barcode,
              label: stopResult.label,
              recordingStart: stopResult.startTime,
            ),
          )
          .then((_) {
        if (mounted) _refreshRecentTransactions();
      }),
    );
  }

  Future<void> _manualStop() async {
    if (!widget.cameraService.isRecording) {
      await _showErrorDialog('Not Recording', 'No recording in progress');
      return;
    }

    // Serialize with scans on the same lane so a stop can't interleave
    // with a stop-and-start already in flight.
    await _scanQueue.submitAction(() async {
      if (!widget.cameraService.isRecording) return;
      try {
        final stopResult = await _stopAndSave('manual');
        _setStatusBar(
          'Recording stopped: ${stopResult.duration}s, '
          '${stopResult.fileSizeMb.toStringAsFixed(2)}MB',
        );
        await _refreshRecentTransactions();
        if (mounted) setState(() {});
      } catch (e) {
        await _showErrorDialog('Error', 'Failed to stop recording: $e');
      }
    });
  }

  // ---------------------------------------------------------------------
  // Recording file actions (STO-03)
  // ---------------------------------------------------------------------

  String? _resolveTransactionPath(Transaction t) {
    return resolveVideoPath(
      widget.videoStoragePath,
      startTime: t.startTime,
      label: t.label,
      videoFilename: t.videoFilename,
    );
  }

  Future<void> _openRecordingFile(Transaction t) async {
    final path = _resolveTransactionPath(t);
    if (path == null) {
      await _showErrorDialog(
        'Error',
        'Video file not found:\n${t.videoFilename}',
      );
      return;
    }
    await Process.start('explorer.exe', [path]);
  }

  Future<void> _showRecordingInFolder(Transaction t) async {
    final path = _resolveTransactionPath(t);
    if (path == null) {
      await _showErrorDialog(
        'Error',
        'Video file not found:\n${t.videoFilename}',
      );
      return;
    }
    await Process.start('explorer.exe', ['/select,', path]);
  }

  // ---------------------------------------------------------------------
  // Widgets
  // ---------------------------------------------------------------------

  /// Builds the RECORDING overlay (CAM-03). Conditionally rendered - not
  /// always-present-and-hidden - and absent from the widget tree entirely
  /// while idle. Reads filename/label from the CameraService, the single
  /// source of truth for the in-progress recording.
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
  /// while preserving the camera's aspect ratio. Shows a reconnecting
  /// placeholder while the camera is unavailable (CAM-04).
  Widget _buildPreviewArea() {
    if (!widget.cameraService.isCameraHealthy) {
      return Container(
        color: Colors.black87,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off, color: Colors.white54, size: 48),
              SizedBox(height: 12),
              Text(
                'Camera unavailable - reconnecting...',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

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

  Widget _buildControlCard() {
    final isRecording = widget.cameraService.isRecording;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Video Label:',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _selectedLabel,
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              items: _kLabelOptions
                  .map(
                    (label) => DropdownMenuItem(
                      value: label,
                      child: Text(label),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _selectedLabel = value);
              },
            ),
            const SizedBox(height: 12),
            Text(
              'Scan or Enter Barcode:',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _barcodeController,
              focusNode: _focusNode,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: 'Barcode',
              ),
              onSubmitted: (_) => _submitBarcode(),
            ),
            const SizedBox(height: 6),
            Text(
              'Scan continuously: each barcode stops the previous '
              'recording and starts a new one.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _submitBarcode,
                    child: const Text('Submit Barcode'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _kDangerColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: isRecording ? _manualStop : null,
                    child: const Text('Stop Recording'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String title, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration() {
    final start = widget.cameraService.recordingStartTime;
    if (start == null || !widget.cameraService.isRecording) return '00:00';
    final elapsed = DateTime.now().difference(start).inSeconds;
    final mins = (elapsed ~/ 60).toString().padLeft(2, '0');
    final secs = (elapsed % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  /// System Status panel (UI-01): recording state, current filename, MM:SS
  /// duration, storage used (DB-03), compression queue status (placeholder
  /// until Phase 3 - currently reports watermark queue activity).
  Widget _buildStatusPanel() {
    final isRecording = widget.cameraService.isRecording;
    final filename = widget.cameraService.currentFilename ?? '-';

    final String compressionText;
    if (widget.watermarkService.isProcessing) {
      compressionText = 'Watermarking...';
    } else if (widget.watermarkService.pendingCount > 0) {
      compressionText = 'Queued: ${widget.watermarkService.pendingCount}';
    } else {
      compressionText = 'Ready';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'System Status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            _buildStatusRow(
              'Status:',
              isRecording ? 'Recording' : 'Idle',
              valueColor: isRecording ? _kDangerColor : null,
            ),
            _buildStatusRow(
              'Current File:',
              isRecording ? filename : '-',
              valueColor: isRecording ? _kDangerColor : null,
            ),
            _buildStatusRow('Duration:', _formatDuration()),
            _buildStatusRow(
              'Storage Used:',
              '${_storageUsedMb.toStringAsFixed(2)} MB',
            ),
            _buildStatusRow('Compression:', compressionText),
          ],
        ),
      ),
    );
  }

  String _formatStartTime(String startTimeIso) {
    try {
      final parsed = DateTime.parse(startTimeIso);
      final date = '${parsed.year.toString().padLeft(4, '0')}-'
          '${parsed.month.toString().padLeft(2, '0')}-'
          '${parsed.day.toString().padLeft(2, '0')}';
      final time = '${parsed.hour.toString().padLeft(2, '0')}:'
          '${parsed.minute.toString().padLeft(2, '0')}:'
          '${parsed.second.toString().padLeft(2, '0')}';
      return '$date $time';
    } catch (_) {
      return startTimeIso;
    }
  }

  String _compressionGlyph(Transaction t) {
    switch (t.compressionStatus) {
      case 'completed':
        return t.compressionRatio != null
            ? 'compressed ${t.compressionRatio!.toStringAsFixed(1)}%'
            : 'compressed';
      case 'processing':
        return 'compressing...';
      case 'failed':
        return 'failed';
      case 'skipped':
        return 'skipped';
      default:
        return 'pending';
    }
  }

  /// Recent recordings list (UI-02): last 10, with Open File and Show in
  /// Folder actions (STO-03).
  Widget _buildRecentRecordings() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Recent Recordings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _recentTransactions.isEmpty
                  ? const Center(child: Text('No recordings yet.'))
                  : ListView.builder(
                      itemCount: _recentTransactions.length,
                      itemBuilder: (context, index) {
                        final t = _recentTransactions[index];
                        final duration = t.durationSeconds ?? 0;
                        final size = t.fileSizeMb ?? 0;
                        return ListTile(
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          title: Text(
                            t.barcode,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${t.label}\n'
                            '${_formatStartTime(t.startTime)} | '
                            '${duration}s | ${size.toStringAsFixed(2)}MB | '
                            '${_compressionGlyph(t)}',
                          ),
                          isThreeLine: true,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.play_circle_outline),
                                tooltip: 'Open File',
                                onPressed: () => _openRecordingFile(t),
                              ),
                              IconButton(
                                icon: const Icon(Icons.folder_open),
                                tooltip: 'Show in Folder',
                                onPressed: () => _showRecordingInFolder(t),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Status bar (UI-03): bottom message line, auto-clears to "Ready" 5s
  /// after each message.
  Widget _buildStatusBar() {
    final scheme = Theme.of(context).colorScheme;
    final isReady = _statusBarText == 'Ready';
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 10,
            color: isReady ? _kSuccessColor : scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusBarText,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ecom Video Tracker'),
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
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildPreviewArea()),
            const SizedBox(width: 12),
            SizedBox(
              width: 380,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildControlCard(),
                  const SizedBox(height: 8),
                  _buildStatusPanel(),
                  const SizedBox(height: 8),
                  Expanded(child: _buildRecentRecordings()),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildStatusBar(),
    );
  }
}
