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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/barcode_handler.dart';
import '../core/barcode_listener.dart';
import '../core/camera_barcode_scanner.dart';
import '../core/camera_service.dart';
import '../core/config.dart';
import '../core/database.dart';
import '../core/disk_space.dart';
import '../core/file_paths.dart';
import '../core/scan_queue.dart';
import '../core/video_actions.dart';
import '../core/watermark_service.dart';
import '../models/transaction.dart';
import 'watermark_status_indicator.dart';
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
    required this.cameraScanner,
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

  /// Button-armed camera barcode scanner (design 2026-07-19): the Scan
  /// button / F2 arm a bounded scan window over the recording camera's
  /// preview; a decoded barcode enters the SAME [_handleScannedBarcode]
  /// path as the USB wedge - full parity, including mid-recording.
  final CameraBarcodeScanner cameraScanner;

  /// Serialized background FFmpeg worker. Each recording gets ONE post-save
  /// job that burns the watermark (REC-06) - the only re-encode on mobile.
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

class _MainScreenState extends State<MainScreen> {
  final _barcodeController = TextEditingController();
  final _focusNode = FocusNode();

  late final ScanQueue _scanQueue;

  int? _currentTransactionId;
  String _selectedLabel = 'Normal (Standard)';
  List<Transaction> _recentTransactions = [];

  /// Completed recordings still awaiting their post-save watermark pass
  /// that have NOT been queued this session (the operator-triggered
  /// backlog tracker; rows keep compression_status='pending' until the
  /// pass runs).
  int _pendingWatermarkCount = 0;

  /// Transaction ids already handed to the watermark worker this session,
  /// by either the post-save chain or the backlog button - prevents
  /// double-queuing the same file.
  final Set<int> _sessionQueuedWatermarkIds = {};

  String _statusBarText = 'Ready';
  Timer? _statusBarTimer;
  Timer? _ticker;
  double _storageUsedMb = 0;

  bool _savingDialogVisible = false;

  @override
  void initState() {
    super.initState();
    _scanQueue = ScanQueue(_processBarcodeInput);
    _refreshRecentTransactions();

    // Route scanner-sourced barcodes into the SAME processBarcode path
    // manual entry uses (BAR-02) - no duplicated orchestration.
    widget.barcodeListener.onBarcodeScanned = _handleScannedBarcode;

    // Camera scan feeds that identical path; timeout only pings the status
    // bar. F2 arms without touching the wedge listener (F2 emits no
    // character, so it can't corrupt an in-flight wedge scan buffer).
    widget.cameraScanner.onBarcode = (barcode) {
      _setStatusBar('Camera scan: $barcode');
      _handleScannedBarcode(barcode);
    };
    HardwareKeyboard.instance.addHandler(_handleScanHotkey);

    // Camera reinit + salvage hooks (CAM-04).
    widget.cameraService.onCameraStateChanged = _onCameraStateChanged;
    widget.cameraService.onRecordingSalvaged = _onRecordingSalvaged;

    // Refresh the recent list (status glyphs, backlog count) whenever the
    // watermark worker's queue state changes.
    widget.watermarkService.queueStatus.addListener(_onWatermarkQueueChanged);

    // 1s refresh: duration ticker + storage used (UI-01/DB-03).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshStorageUsed();
      if (mounted) setState(() {});
    });

  }

  /// F2 arms the camera scan (button-armed mode). Registered as a
  /// top-level HardwareKeyboard handler alongside the wedge listener.
  bool _handleScanHotkey(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f2) {
      if (widget.cameraScanner.state.value.armed) {
        _disarmCameraScan();
      } else {
        _armCameraScan();
      }
      return true;
    }
    return false;
  }

  void _armCameraScan() {
    if (widget.cameraService.cameraId == null) {
      _setStatusBar('Camera scan unavailable - camera not ready');
      return;
    }
    widget.cameraScanner.arm();
    _setStatusBar('Camera scan armed - point the barcode at the camera');
  }

  void _disarmCameraScan() {
    widget.cameraScanner.disarm();
    _setStatusBar('Camera scan cancelled');
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleScanHotkey);
    widget.cameraScanner.onBarcode = null;
    _ticker?.cancel();
    _statusBarTimer?.cancel();
    widget.watermarkService.queueStatus.removeListener(_onWatermarkQueueChanged);
    _barcodeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Service callbacks
  // ---------------------------------------------------------------------

  void _onCameraStateChanged() {
    if (mounted) setState(() {});
  }

  void _onWatermarkQueueChanged() {
    if (mounted) _refreshRecentTransactions();
  }

  Future<void> _onRecordingSalvaged(StopRecordingResult result) async {
    final transactionId = _currentTransactionId;
    if (transactionId != null) {
      await widget.database.completeTransaction(
        transactionId,
        durationSeconds: result.duration,
        fileSizeMb: result.fileSizeMb,
        stopMethod: 'camera_failure',
      );
      _currentTransactionId = null;
    }
    _enqueuePostProcess(result, transactionId);
    if (!mounted) return;
    _setStatusBar('Camera failure - recording saved (${result.duration}s)');
    await _refreshRecentTransactions();
  }

  // ---------------------------------------------------------------------
  // Data refresh
  // ---------------------------------------------------------------------

  Future<void> _refreshRecentTransactions() async {
    final recent = await widget.database.getRecentTransactions(limit: 10);
    final pending = await widget.database.getPendingCompressions();
    if (!mounted) return;
    setState(() {
      _recentTransactions = recent;
      _pendingWatermarkCount = pending
          .where((t) => !_sessionQueuedWatermarkIds.contains(t.id))
          .length;
    });
  }

  /// Backlog watermarking (operator-triggered): queues every completed
  /// recording still marked compression_status='pending' (e.g. recorded
  /// while watermarking was disabled or the app was killed mid-pass). A
  /// pending row has never been through the post-process pass, so it
  /// cannot be double-watermarked. Rows already queued this session are
  /// skipped so this button and the post-save chain can never double-queue
  /// a file. With watermarking disabled, pending rows are simply marked
  /// done (no encode is needed on mobile - recordings are already at the
  /// configured bitrate).
  Future<void> _watermarkPendingRecordings() async {
    final pending = await widget.database.getPendingCompressions();
    var queued = 0;
    var missing = 0;
    for (final t in pending) {
      if (_sessionQueuedWatermarkIds.contains(t.id)) continue;
      final path = resolveVideoPath(
        widget.videoStoragePath,
        startTime: t.startTime,
        label: t.label,
        videoFilename: t.videoFilename,
      );
      if (path == null) {
        missing++;
        continue;
      }
      _sessionQueuedWatermarkIds.add(t.id);
      final start = DateTime.tryParse(t.startTime);
      if (widget.config.watermarkEnabled && start != null) {
        unawaited(
          widget.watermarkService
              .enqueue(WatermarkJob(
                videoPath: path,
                barcode: t.barcode,
                label: t.label,
                recordingStart: start,
              ))
              .then((_) => _markPostProcessDone(t.id)),
        );
      } else {
        await _markPostProcessDone(t.id);
      }
      queued++;
    }
    if (!mounted) return;
    _setStatusBar(
      missing > 0
          ? 'Queued $queued recording(s) for watermarking '
                '($missing file(s) not found on disk)'
          : 'Queued $queued recording(s) for watermarking',
    );
    await _refreshRecentTransactions();
  }

  /// Marks a recording's post-save pass as done. 'skipped' keeps the
  /// desktop DB schema semantics honest: no compression ran on mobile.
  Future<void> _markPostProcessDone(int transactionId) async {
    await widget.database.updateCompressionStatus(transactionId, 'skipped');
    if (mounted) await _refreshRecentTransactions();
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
    final status = evaluateDiskSpace(freeGb, minFreeGb: widget.minFreeSpaceGb);
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
        _setStatusBar('Recording started: ${result.barcode} ($selectedLabel)');
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
      final transactionId = _currentTransactionId;
      if (transactionId != null) {
        await widget.database.completeTransaction(
          transactionId,
          durationSeconds: stopResult.duration,
          fileSizeMb: stopResult.fileSizeMb,
          stopMethod: stopMethod,
        );
        _currentTransactionId = null;
      }
      _enqueuePostProcess(stopResult, transactionId);
      return stopResult;
    } finally {
      _closeSavingDialog();
    }
  }

  /// Fire-and-forget: queues the single post-save FFmpeg pass that burns
  /// the watermark (never delays the next scan). Unlike the desktop app
  /// there is no mirror flip (the rear camera records unmirrored) and no
  /// compression pass (recordings are already hardware-encoded at the
  /// configured bitrate) - with watermarking off, no encode runs at all
  /// and the row is marked done immediately.
  void _enqueuePostProcess(StopRecordingResult stopResult, int? transactionId) {
    if (transactionId == null) return;

    _sessionQueuedWatermarkIds.add(transactionId);
    if (!widget.config.watermarkEnabled) {
      unawaited(_markPostProcessDone(transactionId));
      return;
    }

    unawaited(
      widget.watermarkService
          .enqueue(WatermarkJob(
            videoPath: stopResult.videoPath,
            barcode: stopResult.barcode,
            label: stopResult.label,
            recordingStart: stopResult.startTime,
          ))
          .then((_) => _markPostProcessDone(transactionId)),
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
    final error = await openVideo(path);
    if (error != null) await _showErrorDialog('Error', error);
  }

  Future<void> _shareRecordingFile(Transaction t) async {
    final path = _resolveTransactionPath(t);
    if (path == null) {
      await _showErrorDialog(
        'Error',
        'Video file not found:\n${t.videoFilename}',
      );
      return;
    }
    final error = await shareVideo(path);
    if (error != null) await _showErrorDialog('Error', error);
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
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (context) => screen));
    widget.barcodeListener.onBarcodeScanned = _handleScannedBarcode;
    _reclaimRootFocus();
    if (mounted) setState(() {});
  }

  void _openSearch() {
    _openChildScreen(
      SearchScreen(
        database: widget.database,
        videoStoragePath: widget.config.videoStoragePath,
      ),
    );
  }

  void _openSettings() {
    _openChildScreen(
      SettingsScreen(
        settingsManager: widget.config.settingsManager,
        cameraService: widget.cameraService,
        database: widget.database,
      ),
    );
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
            Text('Video Label:', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _selectedLabel,
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              items: _kLabelOptions
                  .map(
                    (label) =>
                        DropdownMenuItem(value: label, child: Text(label)),
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
            const SizedBox(height: 8),
            // Camera scan (button-armed): shows a countdown while the scan
            // window is open. F2 is the keyboard equivalent.
            ValueListenableBuilder<CameraScanState>(
              valueListenable: widget.cameraScanner.state,
              builder: (context, scan, _) {
                return FilledButton.tonalIcon(
                  icon: Icon(
                    scan.armed ? Icons.stop_circle : Icons.photo_camera,
                  ),
                  // Toggle between stop and start
                  onPressed: scan.armed ? _disarmCameraScan : _armCameraScan,
                  // Make it look like a cancel button when active
                  style: scan.armed
                      ? FilledButton.styleFrom(
                          backgroundColor: _kDangerColor.withValues(alpha: 0.1),
                          foregroundColor: _kDangerColor,
                        )
                      : null,
                  label: Text(
                    scan.armed
                        ? 'Scanning... (Cancel)'
                        : 'Scan with Camera (F2)',
                  ),
                );
              },
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
  /// duration, storage used (DB-03), and the live watermark queue (via
  /// [WatermarkStatusIndicator]).
  Widget _buildStatusPanel() {
    final isRecording = widget.cameraService.isRecording;
    final filename = widget.cameraService.currentFilename ?? '-';

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
            const SizedBox(height: 4),
            WatermarkStatusIndicator(
              watermarkService: widget.watermarkService,
            ),
            // Backlog tracker: older recordings whose post-save watermark
            // pass never ran (app killed mid-pass, watermark disabled, ...).
            if (_pendingWatermarkCount > 0) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$_pendingWatermarkCount recording(s) not watermarked',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _watermarkPendingRecordings,
                    child: const Text('Watermark All'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatStartTime(String startTimeIso) {
    try {
      final parsed = DateTime.parse(startTimeIso);
      final date =
          '${parsed.year.toString().padLeft(4, '0')}-'
          '${parsed.month.toString().padLeft(2, '0')}-'
          '${parsed.day.toString().padLeft(2, '0')}';
      final time =
          '${parsed.hour.toString().padLeft(2, '0')}:'
          '${parsed.minute.toString().padLeft(2, '0')}:'
          '${parsed.second.toString().padLeft(2, '0')}';
      return '$date $time';
    } catch (_) {
      return startTimeIso;
    }
  }

  /// Post-save status glyph. Mobile rows normally land on 'skipped' (no
  /// compression runs here); 'completed' appears only on rows imported
  /// from a desktop archive.
  String _compressionGlyph(Transaction t) {
    switch (t.compressionStatus) {
      case 'completed':
        return t.compressionRatio != null
            ? 'compressed ${t.compressionRatio!.toStringAsFixed(1)}%'
            : 'compressed';
      case 'processing':
        return 'processing...';
      case 'failed':
        return 'failed';
      case 'skipped':
        return 'saved';
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
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          title: Text(
                            t.barcode,
                            style: const TextStyle(fontWeight: FontWeight.bold),
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
                                icon: const Icon(Icons.share),
                                tooltip: 'Share',
                                onPressed: () => _shareRecordingFile(t),
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
            child: Text(_statusBarText, overflow: TextOverflow.ellipsis),
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
      // Scanner-first workflow: barcodes arrive from a Bluetooth HID gun or
      // the camera scan, so the soft keyboard is rare - keep the layout
      // stable instead of resizing under it.
      resizeToAvoidBottomInset: false,
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Wide (landscape/tablet/desktop): preview beside the controls.
            if (constraints.maxWidth >= 900) {
              return Row(
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
              );
            }
            // Portrait phone: preview on top, controls stacked below,
            // recent recordings take the remaining height.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: constraints.maxHeight * 0.35,
                  child: _buildPreviewArea(),
                ),
                const SizedBox(height: 8),
                _buildControlCard(),
                const SizedBox(height: 8),
                _buildStatusPanel(),
                const SizedBox(height: 8),
                Expanded(child: _buildRecentRecordings()),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: _buildStatusBar(),
    );
  }
}
