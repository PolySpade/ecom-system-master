/// Camera Service - thin wrapper around CameraController.
///
/// Behavioral port of ecom-py/camera_handler.py's lifecycle semantics
/// (state flags, guard exceptions, result shape, logging) - NOT its
/// threading implementation. camera_windows' native Media Foundation
/// CaptureEngine owns frame capture/encoding; this class only drives the
/// plugin's start/stop API and manages file placement + bookkeeping.
///
/// CAM-04: a periodic health monitor detects a failed/disconnected camera
/// (controller error state) and reinitializes it with a cooldown and
/// non-reentrant guard, porting _try_reinitialize_camera's behavior
/// (consecutive-failure counter, 5s cooldown, no app restart).
library;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'file_paths.dart';
import 'logger.dart';

/// Maps a configured resolution (settings.json video.resolution_width/
/// height, the ecom-py-compatible representation) onto the camera plugin's
/// [ResolutionPreset] ladder - camera_windows does not accept exact WxH, so
/// the preset closest to (and covering) the requested height is used.
ResolutionPreset resolutionPresetFor(int width, int height) {
  if (height <= 480) return ResolutionPreset.medium;
  if (height <= 720) return ResolutionPreset.high;
  if (height <= 1080) return ResolutionPreset.veryHigh;
  return ResolutionPreset.ultraHigh;
}

/// Result returned by [CameraService.stopRecording].
class StopRecordingResult {
  const StopRecordingResult({
    required this.filename,
    required this.duration,
    required this.fileSizeMb,
    required this.labelFolder,
    required this.videoPath,
    required this.barcode,
    required this.label,
    required this.startTime,
  });

  /// Basename of the saved video file.
  final String filename;

  /// Whole seconds elapsed between start and stop.
  final int duration;

  /// File size in megabytes, rounded to 2 decimal places.
  final double fileSizeMb;

  /// The label folder the video was saved under (e.g. "Normal").
  final String labelFolder;

  /// Full path of the saved video file (input to the post-save watermark
  /// step, and later the Phase-3 compression queue).
  final String videoPath;

  /// Normalized barcode the recording was tagged with.
  final String barcode;

  /// The Video Label the recording was started with.
  final String label;

  /// When the recording started (seeds the watermark's running timestamp).
  final DateTime startTime;
}

/// Thin wrapper around [CameraController]: init, start/stop recording,
/// preview, current-recording-state getters, and auto-reinit (CAM-04).
class CameraService {
  CameraService(this._videoStoragePath, this._logger);

  final String _videoStoragePath;
  final Logger _logger;

  CameraController? _controller;
  DateTime? _recordingStartTime;
  String? _currentFilename;
  String? _currentLabel;
  String? _currentLabelFolder;
  String? _currentBarcode;
  String? _targetVideoPath;

  // CAM-04 auto-reinit state (ports camera_handler.py's counters).
  int _cameraIndex = 0;
  ResolutionPreset _resolutionPreset = ResolutionPreset.high;
  int? _fps;
  int? _videoBitrate;
  int _consecutiveFailures = 0;
  DateTime? _lastReinitTime;
  bool _reinitInProgress = false;
  Timer? _healthTimer;
  bool _disposed = false;

  /// Cooldown between reinitialization attempts (matches ecom-py's 5.0s).
  static const Duration reinitCooldown = Duration(seconds: 5);

  /// Health-check polling interval.
  static const Duration _healthCheckInterval = Duration(seconds: 2);

  /// Invoked whenever camera availability changes (reinit started/finished)
  /// so the UI can rebuild the preview/status.
  void Function()? onCameraStateChanged;

  /// Invoked when an in-progress recording had to be force-stopped because
  /// the camera failed; carries the salvage result (the video file was
  /// saved) so the UI can complete the DB transaction.
  void Function(StopRecordingResult result)? onRecordingSalvaged;

  /// Basename of the in-progress recording; null when idle. Single source
  /// of truth for the RECORDING overlay.
  String? get currentFilename => _currentFilename;

  /// Label of the in-progress recording; null when idle.
  String? get currentLabel => _currentLabel;

  /// Barcode of the in-progress recording; null when idle.
  String? get currentBarcode => _currentBarcode;

  /// Start time of the in-progress recording; null when idle. Drives the
  /// main window's MM:SS duration ticker (UI-01).
  DateTime? get recordingStartTime => _recordingStartTime;

  /// Whether a recording is currently in progress.
  bool get isRecording => _controller?.value.isRecordingVideo ?? false;

  /// Whether the camera is initialized and error-free.
  bool get isCameraHealthy =>
      _controller != null &&
      _controller!.value.isInitialized &&
      !_controller!.value.hasError;

  /// The initialized preview's aspect ratio (width / height), used by
  /// main_screen.dart to keep the preview's proportions correct while it
  /// scales with window resizing (CAM-02). Falls back to a common 4:3
  /// webcam ratio if the controller isn't initialized yet.
  double get aspectRatio => _controller?.value.isInitialized == true
      ? _controller!.value.aspectRatio
      : 4 / 3;

  /// Returns the list of cameras available on this machine.
  static Future<List<CameraDescription>> listCameras() {
    return availableCameras();
  }

  /// Initializes the camera at [cameraIndex]. Must be called before
  /// [buildPreview] or [startRecording]. [resolutionPreset] maps the
  /// configured resolution onto the plugin's preset ladder (see
  /// [resolutionPresetFor]); [fps] and [videoBitrate] (bits/second) cap the
  /// capture rate and the Media Foundation encoder's bitrate - without an
  /// explicit bitrate the camera encodes at ~15-19 Mbit/s. All values are
  /// remembered so the CAM-04 auto-reinit path restores the same
  /// configuration.
  Future<void> init(
    int cameraIndex, {
    ResolutionPreset resolutionPreset = ResolutionPreset.high,
    int? fps,
    int? videoBitrate,
  }) async {
    _cameraIndex = cameraIndex;
    _resolutionPreset = resolutionPreset;
    _fps = fps;
    _videoBitrate = videoBitrate;
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available');
    }
    final index = cameraIndex < cameras.length ? cameraIndex : 0;
    final description = cameras[index];

    final controller = CameraController(
      description,
      resolutionPreset,
      enableAudio: false,
      fps: fps,
      videoBitrate: videoBitrate,
    );
    await controller.initialize();
    _controller = controller;
    _consecutiveFailures = 0;
    // A settings-driven reinitialize() goes through dispose(); clear the
    // flag so the health monitor resumes watching the new controller.
    _disposed = false;
    onCameraStateChanged?.call();
  }

  /// Starts the periodic camera health monitor (CAM-04). Safe to call more
  /// than once.
  void startHealthMonitor() {
    _healthTimer ??= Timer.periodic(
      _healthCheckInterval,
      (_) => _checkCameraHealth(),
    );
  }

  /// Stops the health monitor.
  void stopHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  Future<void> _checkCameraHealth() async {
    if (_disposed || _reinitInProgress) return;

    if (isCameraHealthy) {
      _consecutiveFailures = 0;
      return;
    }

    _consecutiveFailures++;
    final last = _lastReinitTime;
    if (last != null && DateTime.now().difference(last) < reinitCooldown) {
      return; // Cooldown between reinit attempts (matches ecom-py).
    }
    _logger.warning(
      'Camera unhealthy ($_consecutiveFailures consecutive checks), '
      'attempting reinit...',
    );
    await _tryReinitializeCamera();
  }

  /// Attempts to reinitialize the camera after failures. Non-reentrant with
  /// a cooldown, porting ecom-py's _try_reinitialize_camera.
  Future<void> _tryReinitializeCamera() async {
    if (_reinitInProgress) return; // Another reinit in progress.
    _reinitInProgress = true;

    try {
      _lastReinitTime = DateTime.now();
      _logger.info('Attempting camera reinitialization...');

      // Salvage an in-progress recording if any - never lose the video.
      if (isRecording) {
        _logger.warning(
          'Camera failed while recording - attempting to salvage '
          'in-progress video',
        );
        try {
          final result = await stopRecording(stopMethod: 'camera_failure');
          onRecordingSalvaged?.call(result);
        } catch (e) {
          _logger.error('Could not salvage in-progress recording: $e');
          _clearRecordingState();
        }
      }

      // Release the existing controller.
      final old = _controller;
      _controller = null;
      onCameraStateChanged?.call();
      if (old != null) {
        try {
          await old.dispose();
        } catch (_) {
          // Disposal failures on a dead device are expected.
        }
      }

      await init(
        _cameraIndex,
        resolutionPreset: _resolutionPreset,
        fps: _fps,
        videoBitrate: _videoBitrate,
      );
      _logger.info('Camera reinitialized successfully');
    } catch (e) {
      _logger.warning(
        'Camera reinitialization failed - device may be disconnected: $e',
      );
    } finally {
      _reinitInProgress = false;
      onCameraStateChanged?.call();
    }
  }

  /// Releases the current controller and re-runs [init] - the async camera
  /// restart used after capture-affecting settings change (SET-08),
  /// mirroring ecom-py CameraHandler.reinitialize(). Throws a [StateError]
  /// if called while recording.
  Future<void> reinitialize(
    int cameraIndex, {
    ResolutionPreset resolutionPreset = ResolutionPreset.high,
    int? fps,
    int? videoBitrate,
  }) async {
    if (isRecording) {
      throw StateError('Cannot reinitialize while recording');
    }
    _logger.info('Reinitializing camera (index $cameraIndex)');
    final monitorWasRunning = _healthTimer != null;
    await dispose();
    await init(
      cameraIndex,
      resolutionPreset: resolutionPreset,
      fps: fps,
      videoBitrate: videoBitrate,
    );
    if (monitorWasRunning) {
      startHealthMonitor();
    }
    _logger.info('Camera reinitialized');
  }

  /// Returns the live camera preview widget. [init] must have completed.
  Widget buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(controller);
  }

  /// Starts recording, tagging the resulting file with [barcode] and
  /// [label]. Throws a [StateError] if already recording (matches
  /// ecom-py's "Already recording" guard). Returns the full video path.
  Future<String> startRecording(
    String barcode, {
    String label = 'Normal (Standard)',
  }) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Camera not initialized');
    }
    if (isRecording) {
      throw StateError('Already recording');
    }

    final labelFolder = labelFolderName(label);
    final videoPath = buildVideoPath(_videoStoragePath, barcode, labelFolder);

    try {
      await controller.startVideoRecording();

      _currentFilename = p.basename(videoPath);
      _currentLabel = label;
      _currentLabelFolder = labelFolder;
      _currentBarcode = barcode;
      _targetVideoPath = videoPath;
      _recordingStartTime = DateTime.now();

      _logger.info(
        'Started recording: $_currentFilename (Label: $label)',
      );
      return videoPath;
    } catch (e) {
      _clearRecordingState();
      _logger.error('Error starting recording: $e');
      rethrow;
    }
  }

  /// Stops the in-progress recording, moving the plugin's output file to
  /// the target `videos/YYYY-MM-DD/<Label>/...mp4` path if needed. Throws
  /// a [StateError] if not currently recording. Clears
  /// [currentFilename]/[currentLabel].
  Future<StopRecordingResult> stopRecording({
    required String stopMethod,
  }) async {
    final controller = _controller;
    if (controller == null || !isRecording) {
      throw StateError('Not currently recording');
    }

    try {
      final xfile = await controller.stopVideoRecording();

      final filename = _currentFilename!;
      final labelFolder = _currentLabelFolder ?? 'Normal';
      final label = _currentLabel ?? 'Normal (Standard)';
      final barcode = _currentBarcode ?? '';
      final targetPath = _targetVideoPath!;
      final startTime = _recordingStartTime!;

      // Move the plugin's output file to the target path if it wrote
      // elsewhere. Rename first (instant on the same volume - keeps the
      // save non-blocking, REC-04); fall back to copy+delete across
      // volumes.
      if (xfile.path != targetPath) {
        final sourceFile = File(xfile.path);
        if (await sourceFile.exists()) {
          try {
            await sourceFile.rename(targetPath);
          } on FileSystemException {
            await sourceFile.copy(targetPath);
            await sourceFile.delete();
          }
        }
      }

      final duration = DateTime.now().difference(startTime).inSeconds;
      final savedFile = File(targetPath);
      final sizeBytes = savedFile.existsSync() ? savedFile.lengthSync() : 0;
      final fileSizeMb =
          double.parse((sizeBytes / (1024 * 1024)).toStringAsFixed(2));

      _logger.info(
        'Stopped recording: $filename (${duration}s, '
        '${fileSizeMb.toStringAsFixed(2)}MB) in $labelFolder',
      );

      _clearRecordingState();

      return StopRecordingResult(
        filename: filename,
        duration: duration,
        fileSizeMb: fileSizeMb,
        labelFolder: labelFolder,
        videoPath: targetPath,
        barcode: barcode,
        label: label,
        startTime: startTime,
      );
    } catch (e) {
      _logger.error('Error stopping recording: $e');
      rethrow;
    }
  }

  void _clearRecordingState() {
    _currentFilename = null;
    _currentLabel = null;
    _currentLabelFolder = null;
    _currentBarcode = null;
    _targetVideoPath = null;
    _recordingStartTime = null;
  }

  /// Releases the camera controller and stops the health monitor.
  Future<void> dispose() async {
    _disposed = true;
    stopHealthMonitor();
    await _controller?.dispose();
    _controller = null;
  }
}
