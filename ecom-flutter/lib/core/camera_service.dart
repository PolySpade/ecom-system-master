/// Camera Service - thin wrapper around CameraController.
///
/// Behavioral port of ecom-py/camera_handler.py's lifecycle semantics
/// (state flags, guard exceptions, result shape, logging) - NOT its
/// threading implementation. camera_windows' native Media Foundation
/// CaptureEngine owns frame capture/encoding; this class only drives the
/// plugin's start/stop API and manages file placement + bookkeeping.
library;

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import 'file_paths.dart';
import 'logger.dart';

/// Result returned by [CameraService.stopRecording].
class StopRecordingResult {
  const StopRecordingResult({
    required this.filename,
    required this.duration,
    required this.fileSizeMb,
    required this.labelFolder,
  });

  /// Basename of the saved video file.
  final String filename;

  /// Whole seconds elapsed between start and stop.
  final int duration;

  /// File size in megabytes, rounded to 2 decimal places.
  final double fileSizeMb;

  /// The label folder the video was saved under (e.g. "Normal").
  final String labelFolder;
}

/// Thin wrapper around [CameraController]: init, start/stop recording,
/// preview, and current-recording-state getters.
class CameraService {
  CameraService(this._videoStoragePath, this._logger);

  final String _videoStoragePath;
  final Logger _logger;

  CameraController? _controller;
  DateTime? _recordingStartTime;
  String? _currentFilename;
  String? _currentLabel;
  String? _currentLabelFolder;
  String? _targetVideoPath;

  /// Basename of the in-progress recording; null when idle. Single source
  /// of truth for the RECORDING overlay (consumed by Plan 02 Task 2).
  String? get currentFilename => _currentFilename;

  /// Label of the in-progress recording; null when idle.
  String? get currentLabel => _currentLabel;

  /// Whether a recording is currently in progress.
  bool get isRecording => _controller?.value.isRecordingVideo ?? false;

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
  /// [buildPreview] or [startRecording].
  Future<void> init(int cameraIndex) async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available');
    }
    final index = cameraIndex < cameras.length ? cameraIndex : 0;
    final description = cameras[index];

    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await controller.initialize();
    _controller = controller;
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

      _currentFilename = videoPath.split(Platform.pathSeparator).last;
      _currentLabel = label;
      _currentLabelFolder = labelFolder;
      _targetVideoPath = videoPath;
      _recordingStartTime = DateTime.now();

      _logger.info(
        'Started recording: $_currentFilename (Label: $label)',
      );
      return videoPath;
    } catch (e) {
      _currentFilename = null;
      _currentLabel = null;
      _currentLabelFolder = null;
      _targetVideoPath = null;
      _recordingStartTime = null;
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
      final targetPath = _targetVideoPath!;
      final startTime = _recordingStartTime!;

      // Move/rename the plugin's output file to the target path if it
      // wrote elsewhere.
      if (xfile.path != targetPath) {
        final sourceFile = File(xfile.path);
        if (await sourceFile.exists()) {
          await sourceFile.copy(targetPath);
          await sourceFile.delete();
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

      _currentFilename = null;
      _currentLabel = null;
      _currentLabelFolder = null;
      _targetVideoPath = null;
      _recordingStartTime = null;

      return StopRecordingResult(
        filename: filename,
        duration: duration,
        fileSizeMb: fileSizeMb,
        labelFolder: labelFolder,
      );
    } catch (e) {
      _logger.error('Error stopping recording: $e');
      rethrow;
    }
  }

  /// Releases the camera controller.
  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
  }
}
