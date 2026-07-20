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
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'file_paths.dart';
import 'grabbed_frame.dart';
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

  // Camera-scan frame tap: the latest luminance frame from the image
  // stream, served to the barcode scanner's poll loop.
  GrabbedFrame? _latestFrame;
  DateTime? _latestFrameAt;
  bool _scanStreamRequested = false;

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

  /// Plugin camera id of the initialized camera; null before init or after
  /// dispose. Feeds the native frame tap (camera barcode scan).
  int? get cameraId {
    final id = _controller?.cameraId;
    return (id == null || id < 0) ? null : id;
  }

  /// Whether the periodic health monitor is currently running (CAM-04).
  bool get healthMonitorRunning => _healthTimer != null;

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
      // YUV420 so the image stream's first plane is the luminance channel
      // the barcode decoder consumes directly.
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await controller.initialize();
    } catch (_) {
      // camera_windows keeps the native camera registered even when
      // initialize() fails partway (create succeeded, start failed).
      // Dispose the failed controller to free the device id - otherwise
      // every later attempt fails with "Camera with given device id
      // already exists" until the app is restarted.
      try {
        await controller.dispose();
      } catch (e) {
        _logger.warning('Disposing failed camera controller: $e');
      }
      rethrow;
    }
    _controller = controller;
    _consecutiveFailures = 0;
    // A settings-driven reinitialize() goes through dispose(); clear the
    // flag so the health monitor resumes watching the new controller.
    _disposed = false;

    // Makes the plugin's own rotation bookkeeping (CameraValue.
    // recordingOrientation/deviceOrientation) deterministic instead of
    // depending on a live device-orientation sensor read, since the app is
    // portrait-only anyway (main.dart's SystemChrome.setPreferredOrientations).
    // NOTE: this does NOT fix the known bug where the preview renders the
    // feed rotated ~90° while actively recording on at least one device
    // (Samsung Galaxy Z Fold, camera_android_camerax 0.7.4+1) - confirmed
    // via diagnostic investigation that the plugin's own rotation-decision
    // value is correct (recordingOrientation=portraitUp, i.e. "apply no
    // rotation") for the entire recording where the feed still rendered
    // rotated, and that even the plugin's completely unmodified CameraPreview
    // widget (no customization from this app) reproduces it - the bug is in
    // the plugin's native texture rendering, not fixable from Flutter-side
    // widget code. Kept anyway since it's a correctness improvement on its
    // own merits and doesn't regress anything.
    try {
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (e) {
      _logger.warning('Could not lock capture orientation: $e');
    }

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

  /// Attempts per settings-driven [reinitialize]. Media Foundation can
  /// report the device busy ("Hardware MFT failed to start streaming...")
  /// for a few seconds after the old controller is released; retrying
  /// bridges that window so Save & Apply usually succeeds immediately.
  static const int reinitAttempts = 3;

  /// Delay between [reinitialize] attempts.
  static const Duration reinitRetryDelay = Duration(seconds: 1);

  /// Releases the current controller and re-runs [init] - the async camera
  /// restart used after capture-affecting settings change (SET-08),
  /// mirroring ecom-py CameraHandler.reinitialize(). Throws a [StateError]
  /// if called while recording.
  ///
  /// Init is retried up to [reinitAttempts] times (device-busy bridge), and
  /// the health monitor is restarted even when every attempt fails - [init]
  /// stores the new settings before it can throw, so the monitor's periodic
  /// retry brings the camera back with the NEW configuration as soon as the
  /// device frees up (no app restart required).
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
    try {
      await dispose();
      // Not disposed-for-good: the health monitor must keep watching this
      // service (dispose() set the flag that suspends it).
      _disposed = false;
      for (var attempt = 1; ; attempt++) {
        try {
          await init(
            cameraIndex,
            resolutionPreset: resolutionPreset,
            fps: fps,
            videoBitrate: videoBitrate,
          );
          break;
        } catch (e) {
          if (attempt >= reinitAttempts) rethrow;
          _logger.warning(
            'Camera reinit attempt $attempt/$reinitAttempts failed ($e), '
            'retrying...',
          );
          await Future<void>.delayed(reinitRetryDelay);
        }
      }
      _logger.info('Camera reinitialized');
    } finally {
      if (monitorWasRunning) {
        startHealthMonitor();
      }
    }
  }

  /// Returns the live camera preview widget. [init] must have completed.
  ///
  /// No mirror transform on mobile: the rear camera shows (and records)
  /// the scene as-is, and the plugin already mirrors front-camera previews
  /// natively.
  Widget buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(controller);
  }

  // -----------------------------------------------------------------
  // Camera-scan frame tap
  // -----------------------------------------------------------------

  /// Latest luminance frame from the active image stream, or null when no
  /// frame fresher than [maxAge] is available (stream not running yet /
  /// camera stalled) - the scanner's poll loop just tries again.
  GrabbedFrame? latestFrame({Duration maxAge = const Duration(seconds: 2)}) {
    final at = _latestFrameAt;
    if (at == null || DateTime.now().difference(at) > maxAge) {
      return null;
    }
    return _latestFrame;
  }

  void _onStreamFrame(CameraImage image) {
    if (image.planes.isEmpty) return;
    final plane = image.planes.first;
    // The plugin delivers fresh Dart-owned buffers per frame; storing the
    // reference is safe (no copy needed).
    _latestFrame = GrabbedFrame(
      bytes: plane.bytes,
      width: image.width,
      height: image.height,
      rowStride: plane.bytesPerRow,
    );
    _latestFrameAt = DateTime.now();
  }

  /// Enables/disables the scan frame tap. While idle this starts/stops the
  /// camera image stream; during a recording frames already flow through
  /// [startRecording]'s stream callback, so this only records intent (the
  /// post-stop path re-applies it). Never throws - a failed stream toggle
  /// only degrades camera-scan, not recording.
  Future<void> setScanStreamEnabled(bool enabled) async {
    _scanStreamRequested = enabled;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (isRecording) return;
    try {
      if (enabled && !controller.value.isStreamingImages) {
        await controller.startImageStream(_onStreamFrame);
      } else if (!enabled && controller.value.isStreamingImages) {
        await controller.stopImageStream();
        _latestFrame = null;
        _latestFrameAt = null;
      }
    } catch (e) {
      _logger.warning('Camera scan stream toggle failed: $e');
    }
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
      // An idle-armed image stream must be released before recording; the
      // recording itself re-requests frames via onAvailable below so the
      // barcode scanner keeps working MID-RECORDING (the core continuous
      // loop: scanning the next barcode stops this recording).
      if (controller.value.isStreamingImages) {
        try {
          await controller.stopImageStream();
        } catch (e) {
          _logger.warning('Could not stop idle scan stream: $e');
        }
      }
      await controller.startVideoRecording(onAvailable: _onStreamFrame);

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

      // Restore the idle scan stream if the scanner is still armed.
      if (_scanStreamRequested) {
        unawaited(setScanStreamEnabled(true));
      }

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
