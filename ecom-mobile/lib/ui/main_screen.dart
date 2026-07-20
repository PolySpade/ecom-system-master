/// Main Screen - full-screen camera preview with a toggleable floating
/// control panel (Video Label selection + barcode entry + Stop/Scan
/// buttons + condensed status) over it.
///
/// Ports the main-window orchestration from ecom-py/app_gui.py: the
/// stop-then-start sequential ordering for stopAndStart (via a serialized
/// ScanQueue so scans arriving during a save are queued, REC-04), the
/// non-dismissible "Saving Recording..." dialog, label routing (REC-06),
/// the disk-space guard before recording start (STO-02), a condensed
/// System Status readout with a 1s refresh (UI-01/DB-03), and the 5s
/// auto-clearing status toast (UI-03). Unlike the desktop app, the
/// recordings list lives only in the Search screen - the main screen is
/// the camera feed.
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
import '../core/watermark_service.dart';
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

  /// Whether the floating control panel is shown over the camera feed.
  /// Toggled by the FAB in [_buildControlsToggle] so the operator can get
  /// an unobstructed view of the full-screen preview on demand.
  bool _controlsExpanded = true;

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
    _refreshWatermarkBacklog();

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
    if (mounted) _refreshWatermarkBacklog();
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
    await _refreshWatermarkBacklog();
  }

  // ---------------------------------------------------------------------
  // Data refresh
  // ---------------------------------------------------------------------

  Future<void> _refreshWatermarkBacklog() async {
    final pending = await widget.database.getPendingCompressions();
    if (!mounted) return;
    setState(() {
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
    await _refreshWatermarkBacklog();
  }

  /// Marks a recording's post-save pass as done. 'skipped' keeps the
  /// desktop DB schema semantics honest: no compression ran on mobile.
  Future<void> _markPostProcessDone(int transactionId) async {
    await widget.database.updateCompressionStatus(transactionId, 'skipped');
    if (mounted) await _refreshWatermarkBacklog();
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
  ///
  /// Deliberately does NOT refocus the barcode field afterwards - the
  /// wedge scanner feeds barcodes via [GlobalBarcodeListener]'s top-level
  /// hardware-key handler, which works regardless of Flutter focus, so
  /// refocusing here would only pop the soft keyboard open again after
  /// every single scan.
  void _submitBarcode() {
    final raw = _barcodeController.text;
    _barcodeController.clear();

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

      await _refreshWatermarkBacklog();
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
        await _refreshWatermarkBacklog();
        if (mounted) setState(() {});
      } catch (e) {
        await _showErrorDialog('Error', 'Failed to stop recording: $e');
      }
    });
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
      // Sits below the floating top bar (title + Search/Settings), which
      // occupies this same top-right corner - stacking on top of it would
      // otherwise visually collide with this chip during recording.
      top: MediaQuery.paddingOf(context).top + 64,
      right: 8,
      child: ConstrainedBox(
        // Capped so a long filename/label can't stretch this into a wide
        // block across the top of the feed - it ellipsizes instead.
        constraints: const BoxConstraints(maxWidth: 260),
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
              Flexible(
                child: Text(
                  'RECORDING: $filename [$label]',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
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
        // The RESOLVED root recordings are actually written to (may have
        // fallen back to app-private storage, see storage_root.dart) - not
        // widget.config.videoStoragePath, the originally configured path,
        // which is where Search would otherwise look for files that were
        // actually saved elsewhere.
        database: widget.database,
        videoStoragePath: widget.videoStoragePath,
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

  /// Full-screen camera feed (CAM-01/CAM-02): fills the entire available
  /// space, cropping (never distorting) the feed to cover it - the camera
  /// plugin only exposes a "contain" box (an [AspectRatio]-sized child), so
  /// an oversized child sized to the correct aspect ratio is clipped via
  /// [OverflowBox] to get "cover" behavior instead of letterboxing or
  /// stretching. Shows a reconnecting placeholder while the camera is
  /// unavailable (CAM-04).
  Widget _buildPreviewArea() {
    if (!widget.cameraService.isCameraHealthy) {
      return ColoredBox(
        color: Colors.black,
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

    // The camera plugin reports width/height in the sensor's native
    // (landscape) orientation regardless of how the phone is held, so it
    // must be inverted for this portrait-locked app or the box is sized
    // wrong. (The camera_android_camerax/CameraX implementation had a
    // native bug where the live preview rendered rotated specifically while
    // actively recording - matching upstream flutter/flutter#163857 - fixed
    // by switching to the legacy Camera2-based camera_android
    // implementation in pubspec.yaml; see CameraService.init's
    // lockCaptureOrientation call for the still-relevant orientation-
    // determinism piece of that investigation.)
    final rawAspectRatio = widget.cameraService.aspectRatio;
    final previewAspectRatio = rawAspectRatio > 1
        ? 1 / rawAspectRatio
        : rawAspectRatio;

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final screenAspectRatio = size.width / size.height;
          // Whichever dimension the preview is "narrower" on relative to
          // the screen is stretched to fill it; the other overflows and is
          // clipped below - cropping the feed instead of squishing it.
          final matchWidth = screenAspectRatio > previewAspectRatio;
          final childWidth = matchWidth
              ? size.width
              : size.height * previewAspectRatio;
          final childHeight = matchWidth
              ? size.width / previewAspectRatio
              : size.height;

          return ClipRect(
            child: OverflowBox(
              maxWidth: childWidth,
              maxHeight: childHeight,
              child: SizedBox(
                width: childWidth,
                height: childHeight,
                child: widget.cameraService.buildPreview(),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Floating top bar (title + Search/Settings) over a dark scrim so the
  /// icons stay legible against a bright feed - there is no opaque AppBar
  /// in the whole-screen-preview design to anchor them to.
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.paddingOf(context).top + 8,
          12,
          32,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black54, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Ecom Video Tracker',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _overlayIconButton(Icons.search, 'Search Recordings', _openSearch),
            const SizedBox(width: 4),
            _overlayIconButton(Icons.settings, 'Settings', _openSettings),
          ],
        ),
      ),
    );
  }

  Widget _overlayIconButton(
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  /// Transient status toast (UI-03): floats over the feed and auto-clears
  /// via [_setStatusBar]'s existing 5s timer - there is no fixed bottom bar
  /// left to anchor it to in the whole-screen-preview design.
  Widget? _buildStatusToast() {
    if (_statusBarText == 'Ready') return null;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 56,
      left: 12,
      right: 12,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            _statusBarText,
            style: const TextStyle(color: Colors.white),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  /// FAB that shows/hides [_buildControlPanel], so the operator can get an
  /// unobstructed view of the full-screen feed on demand.
  Widget _buildControlsToggle() {
    return Positioned(
      right: 16,
      // Rises above the soft keyboard (viewInsets.bottom) instead of being
      // covered by it - the Scaffold itself doesn't resize
      // (resizeToAvoidBottomInset: false keeps the feed full-screen), so
      // only this floating overlay needs to react to the keyboard.
      bottom:
          16 +
          MediaQuery.paddingOf(context).bottom +
          MediaQuery.viewInsetsOf(context).bottom,
      child: FloatingActionButton(
        heroTag: 'controlsToggle',
        tooltip: _controlsExpanded ? 'Hide controls' : 'Show controls',
        onPressed: () => setState(() => _controlsExpanded = !_controlsExpanded),
        child: Icon(_controlsExpanded ? Icons.expand_more : Icons.tune),
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

  /// Floating control panel: Video Label + barcode entry + Stop/Scan
  /// buttons, plus a condensed status line (recording state, MM:SS
  /// duration, storage used (DB-03), and the live watermark queue via
  /// [WatermarkStatusIndicator]) - the recording overlay on the preview
  /// already shows the filename/label, so this only adds duration/storage.
  /// Toggled by [_buildControlsToggle].
  Widget _buildControlPanel() {
    final isRecording = widget.cameraService.isRecording;
    final filename = widget.cameraService.currentFilename;
    final scheme = Theme.of(context).colorScheme;

    return Positioned(
      left: 0,
      right: 0,
      // Rises above the soft keyboard instead of being covered by it - see
      // the matching comment on _buildControlsToggle.
      bottom: MediaQuery.viewInsetsOf(context).bottom,
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 16,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Collapse handle - tapping it hides the panel, same as
                // the toggle FAB.
                Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _controlsExpanded = false),
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      isRecording
                          ? Icons.fiber_manual_record
                          : Icons.check_circle,
                      size: 14,
                      color: isRecording ? _kDangerColor : _kSuccessColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        isRecording
                            ? '${filename ?? 'Recording'} · ${_formatDuration()}'
                            : 'Idle',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isRecording ? _kDangerColor : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_storageUsedMb.toStringAsFixed(0)} MB',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                WatermarkStatusIndicator(
                  watermarkService: widget.watermarkService,
                ),
                // Backlog tracker: older recordings whose post-save
                // watermark pass never ran (app killed mid-pass, watermark
                // disabled, ...).
                if (_pendingWatermarkCount > 0) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$_pendingWatermarkCount recording(s) not watermarked',
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
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
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _selectedLabel,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Video Label',
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _barcodeController,
                        focusNode: _focusNode,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                          hintText: 'Scan or enter barcode',
                        ),
                        onSubmitted: (_) => _submitBarcode(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _submitBarcode,
                      tooltip: 'Submit Barcode',
                      icon: const Icon(Icons.check),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // Camera scan (button-armed): shows a countdown while
                    // the scan window is open. F2 is the keyboard
                    // equivalent.
                    Expanded(
                      child: ValueListenableBuilder<CameraScanState>(
                        valueListenable: widget.cameraScanner.state,
                        builder: (context, scan, _) {
                          return FilledButton.tonalIcon(
                            icon: Icon(
                              scan.armed
                                  ? Icons.stop_circle
                                  : Icons.photo_camera,
                            ),
                            onPressed: scan.armed
                                ? _disarmCameraScan
                                : _armCameraScan,
                            style: scan.armed
                                ? FilledButton.styleFrom(
                                    backgroundColor: _kDangerColor.withValues(
                                      alpha: 0.1,
                                    ),
                                    foregroundColor: _kDangerColor,
                                  )
                                : null,
                            label: Text(scan.armed ? 'Scanning...' : 'Scan'),
                          );
                        },
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
                        child: const Text('Stop'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        // Scanner-first workflow: barcodes arrive from a Bluetooth HID gun
        // or the camera scan, so the soft keyboard is rare - keep the feed
        // stable instead of resizing under it.
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildPreviewArea(),
            ?_buildRecordingOverlay(),
            _buildTopBar(),
            ?_buildStatusToast(),
            if (_controlsExpanded) _buildControlPanel(),
            _buildControlsToggle(),
          ],
        ),
      ),
    );
  }
}
