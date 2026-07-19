/// Video Compressor - Background compression worker using FFmpeg.
///
/// Behavioral port of ecom-py/video_compressor.py's queue.Queue +
/// daemon-thread design onto Dart's single-threaded event loop: a FIFO
/// queue drained by a strictly-serialized async pump (one job in flight at
/// a time), with completion delivered through an injected callback rather
/// than a return value - the caller never blocks (COMP-01).
///
/// One deliberate divergence from ecom-py (COMP-03): when replacing the
/// original, the swap goes original -> .bak, temp -> original, delete
/// .bak, so every crash point leaves at least one intact copy of the
/// video on disk (ecom-py deletes the original before renaming).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;

import 'config.dart';
import 'ffmpeg_locator.dart';
import 'logger.dart';
import 'process_priority.dart';

/// Status of compression jobs. [value] strings are what's persisted to the
/// transactions table - identical to ecom-py's CompressionStatus enum.
enum CompressionStatus {
  pending('pending'),
  processing('processing'),
  completed('completed'),
  failed('failed'),
  skipped('skipped');

  const CompressionStatus(this.value);

  /// The database/string form of the status (matches ecom-py rows).
  final String value;
}

/// Compression parameters for a single job - mirrors the settings dict
/// ecom-py passes into queue_compression().
class CompressionSettings {
  const CompressionSettings({
    this.enabled = true,
    this.codec = 'h264',
    this.crf = 23,
    this.preset = 'medium',
    this.deleteOriginal = true,
    this.priority = 'below_normal',
  });

  /// Builds settings from the app [Config]'s `compression` category.
  factory CompressionSettings.fromConfig(Config config) {
    return CompressionSettings(
      enabled: config.compressionEnabled,
      codec: config.compressionCodec,
      crf: config.compressionCrf,
      preset: config.compressionPreset,
      deleteOriginal: config.compressionDeleteOriginal,
      priority: config.compressionPriority,
    );
  }

  /// Master enable toggle; disabled jobs are skipped with a callback.
  final bool enabled;

  /// 'h264' (libx264) or 'h265' (libx265).
  final String codec;

  /// Constant Rate Factor; clamped to 18-35 at command construction.
  final int crf;

  /// FFmpeg preset (ultrafast/fast/medium/slow).
  final String preset;

  /// Replace the original with the compressed file (true, ecom-py
  /// default) or keep both files side by side (false).
  final bool deleteOriginal;

  /// Windows process priority: 'low', 'below_normal', or 'normal'.
  final String priority;
}

/// Represents a compression job in the queue (ecom-py CompressionJob).
class CompressionJob {
  CompressionJob({
    required this.videoPath,
    required this.transactionId,
    required this.settings,
    this.videoFilter,
  });

  final String videoPath;
  final int transactionId;
  final CompressionSettings settings;

  /// Optional -vf filtergraph applied during the encode (the watermark
  /// burn-in). Merging the watermark into the compression pass means every
  /// recording is re-encoded exactly once.
  final String? videoFilter;
  String? outputPath;
}

/// Snapshot of the compressor's queue state, published via
/// [VideoCompressor.queueStatus] - field-for-field ecom-py's
/// get_queue_status() dict.
class CompressionQueueStatus {
  const CompressionQueueStatus({
    required this.queueSize,
    required this.isProcessing,
    this.currentTransactionId,
    required this.workerRunning,
  });

  final int queueSize;
  final bool isProcessing;
  final int? currentTransactionId;
  final bool workerRunning;

  @override
  bool operator ==(Object other) {
    return other is CompressionQueueStatus &&
        other.queueSize == queueSize &&
        other.isProcessing == isProcessing &&
        other.currentTransactionId == currentTransactionId &&
        other.workerRunning == workerRunning;
  }

  @override
  int get hashCode =>
      Object.hash(queueSize, isProcessing, currentTransactionId, workerRunning);

  @override
  String toString() =>
      'CompressionQueueStatus(queueSize: $queueSize, isProcessing: '
      '$isProcessing, currentTransactionId: $currentTransactionId, '
      'workerRunning: $workerRunning)';
}

/// Callback invoked when a job finishes (or is skipped/failed before
/// queuing). [resultData] keys match ecom-py's on_complete dict: 'status',
/// 'compressed_file_size_mb', 'compression_ratio', 'compressed_filename',
/// 'message'.
typedef CompressionCompleteCallback = void Function(
  int transactionId,
  bool success,
  Map<String, Object?> resultData,
);

/// Seam for spawning the FFmpeg process (fake-able in tests).
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// Seam for FFmpeg discovery (defaults to [FfmpegLocator.findFfmpeg]).
typedef FfmpegFinder = Future<String?> Function();

/// Seam for probing a video's source bitrate in kbit/s (null when it cannot
/// be determined). Defaults to an ffprobe invocation.
typedef SourceBitrateProber = Future<int?> Function(String videoPath);

/// Seam for applying process priority (defaults to [setProcessPriority]).
typedef PriorityApplier = bool Function(int pid, String priority);

/// Default [SourceBitrateProber]: asks ffprobe for the video stream's
/// bitrate (falling back to the container bitrate). Returns kbit/s, or null
/// when ffprobe is missing or the probe fails - callers then encode without
/// a rate cap, exactly the pre-probe behavior.
Future<int?> probeSourceBitrateKbps(String videoPath) async {
  final ffprobe = await FfmpegLocator.findFfprobe();
  if (ffprobe == null) {
    return null;
  }
  try {
    final result = await Process.run(ffprobe, [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=bit_rate:format=bit_rate',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      videoPath,
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    // Stream bitrate is printed first when known; some containers only
    // report a format-level bitrate ("N/A" lines are skipped).
    for (final line in '${result.stdout}'.split(RegExp(r'\r?\n'))) {
      final bps = int.tryParse(line.trim());
      if (bps != null && bps > 0) {
        return bps ~/ 1000;
      }
    }
  } catch (_) {
    // Probe failures are non-fatal - the encode just runs uncapped.
  }
  return null;
}

/// Background video compression worker using FFmpeg.
class VideoCompressor {
  /// [onComplete] is called for every terminal outcome (completed, failed,
  /// skipped). The remaining parameters are injectable seams so queue
  /// serialization, command construction, atomic swap, timeout, and
  /// graceful-skip behavior are all unit-testable without FFmpeg
  /// installed.
  VideoCompressor(
    this._logger, {
    CompressionCompleteCallback? onComplete,
    ProcessStarter? processStarter,
    FfmpegFinder? ffmpegFinder,
    PriorityApplier? priorityApplier,
    SourceBitrateProber? bitrateProber,
    Duration jobTimeout = const Duration(hours: 1),
  })  : _onComplete = onComplete,
        _processStarter = processStarter ?? _defaultProcessStarter,
        _ffmpegFinder = ffmpegFinder ?? FfmpegLocator.findFfmpeg,
        _priorityApplier = priorityApplier ?? setProcessPriority,
        _bitrateProber = bitrateProber ?? probeSourceBitrateKbps,
        _jobTimeout = jobTimeout;

  final Logger _logger;
  final CompressionCompleteCallback? _onComplete;
  final ProcessStarter _processStarter;
  final FfmpegFinder _ffmpegFinder;
  final PriorityApplier _priorityApplier;
  final SourceBitrateProber _bitrateProber;
  final Duration _jobTimeout;

  final ListQueue<CompressionJob> _queue = ListQueue<CompressionJob>();
  bool _running = false;
  CompressionJob? _currentJob;
  Future<void>? _activeJob;
  String? _ffmpegPath;

  /// Live queue state for the UI (UI-01's compression queue readout).
  /// Phase 2's status panel consumes this via ValueListenableBuilder.
  final ValueNotifier<CompressionQueueStatus> queueStatus =
      ValueNotifier<CompressionQueueStatus>(
    const CompressionQueueStatus(
      queueSize: 0,
      isProcessing: false,
      workerRunning: false,
    ),
  );

  /// Jobs waiting plus the one in flight (0 when idle).
  int get queueLength => _queue.length + (_currentJob == null ? 0 : 1);

  /// Starts the background compression worker.
  void start() {
    if (_running) {
      return;
    }
    _running = true;
    _logger.info('Video compressor worker started');
    _notifyStatus();
    _pump();
  }

  /// Stops the worker gracefully: no new jobs start, and the returned
  /// future completes once the in-flight job (if any) finishes. Queued
  /// jobs remain in the queue.
  Future<void> stop() async {
    _running = false;
    _notifyStatus();
    final active = _activeJob;
    if (active != null) {
      await active;
    }
    _logger.info('Video compressor worker stopped');
  }

  /// Queues a video for compression. Returns true if the job was queued.
  ///
  /// Mirrors ecom-py's queue_compression() short-circuits: when
  /// compression is disabled or FFmpeg is unavailable the job is skipped
  /// gracefully (logged + 'skipped' callback, recording never affected);
  /// a missing input file reports 'failed'.
  ///
  /// [videoFilter] burns the watermark during the same encode. A job with a
  /// filter runs even when compression is disabled - the watermark requires
  /// a re-encode regardless, and encoding once at the configured CRF is
  /// strictly cheaper than a separate watermark pass. The enabled toggle
  /// still governs plain (filter-less) backlog jobs.
  Future<bool> queueCompression(
    String videoPath,
    int transactionId,
    CompressionSettings settings, {
    String? videoFilter,
  }) async {
    if (!settings.enabled && videoFilter == null) {
      _logger.info('Compression disabled, skipping $videoPath');
      _onComplete?.call(transactionId, true, {
        'status': CompressionStatus.skipped.value,
        'message': 'Compression disabled',
      });
      return false;
    }

    final ffmpegPath = await _ffmpegFinder();
    if (ffmpegPath == null) {
      _logger.warning(
        'FFmpeg not available, skipping compression for $videoPath',
      );
      _onComplete?.call(transactionId, false, {
        'status': CompressionStatus.skipped.value,
        'message': 'FFmpeg not installed',
      });
      return false;
    }
    _ffmpegPath = ffmpegPath;

    if (!File(videoPath).existsSync()) {
      _logger.error('Video file not found: $videoPath');
      _onComplete?.call(transactionId, false, {
        'status': CompressionStatus.failed.value,
        'message': 'Video file not found',
      });
      return false;
    }

    _queue.add(CompressionJob(
      videoPath: videoPath,
      transactionId: transactionId,
      settings: settings,
      videoFilter: videoFilter,
    ));
    _logger.info(
      'Queued compression job for transaction $transactionId: $videoPath',
    );
    _notifyStatus();
    _pump();
    return true;
  }

  /// Serialized FIFO pump: starts the next job only when the worker is
  /// running and nothing is in flight. Re-entered from each job's
  /// whenComplete, so jobs can never overlap (COMP-01).
  void _pump() {
    if (!_running || _currentJob != null || _queue.isEmpty) {
      return;
    }
    final job = _queue.removeFirst();
    _currentJob = job;
    _notifyStatus();
    _activeJob = _processJob(job).whenComplete(() {
      _currentJob = null;
      _activeJob = null;
      _notifyStatus();
      _pump();
    });
  }

  void _notifyStatus() {
    queueStatus.value = CompressionQueueStatus(
      queueSize: _queue.length,
      isProcessing: _currentJob != null,
      currentTransactionId: _currentJob?.transactionId,
      workerRunning: _running,
    );
  }

  /// Processes a single compression job (ecom-py _process_job).
  Future<void> _processJob(CompressionJob job) async {
    _logger.info(
      'Processing compression job for transaction ${job.transactionId}',
    );
    try {
      // Temp output lives in the SAME directory as the original so the
      // final rename is an atomic same-volume move (COMP-03).
      final ext = p.extension(job.videoPath);
      final base = job.videoPath.substring(0, job.videoPath.length - ext.length);
      final outputPath = '${base}_compressed$ext';
      job.outputPath = outputPath;

      final originalSize = File(job.videoPath).lengthSync();
      final originalSizeMb = originalSize / (1024 * 1024);

      final (success, message) = await _compressVideo(job);

      final outputFile = File(outputPath);
      final outputSize = outputFile.existsSync() ? outputFile.lengthSync() : 0;

      if (success && outputSize > 0 &&
          job.videoFilter == null && outputSize >= originalSize) {
        // The source was already leaner than what this CRF produces, so the
        // "compressed" file came out no smaller. Nothing but size is at
        // stake on a filter-less job - keep the original.
        try {
          outputFile.deleteSync();
        } catch (_) {
          // Best-effort cleanup.
        }
        _logger.info(
          'Compression not beneficial '
          '(${originalSizeMb.toStringAsFixed(2)}MB -> '
          '${(outputSize / (1024 * 1024)).toStringAsFixed(2)}MB), '
          'keeping original',
        );
        _onComplete?.call(job.transactionId, true, {
          'status': CompressionStatus.completed.value,
          'compressed_file_size_mb': originalSizeMb,
          'compression_ratio': 0.0,
          'compressed_filename': p.basename(job.videoPath),
          'message': 'Compression not beneficial - kept original',
        });
        return;
      }

      if (success && outputSize > 0) {
        final compressedSizeMb = outputSize / (1024 * 1024);
        final compressionRatio =
            originalSize > 0 ? (1 - outputSize / originalSize) * 100 : 0.0;
        _logger.info(
          'Compression complete: ${originalSizeMb.toStringAsFixed(2)}MB -> '
          '${compressedSizeMb.toStringAsFixed(2)}MB '
          '(${compressionRatio.toStringAsFixed(1)}% reduction)',
        );

        var compressedFilename = p.basename(outputPath);
        if (job.settings.deleteOriginal) {
          compressedFilename = _swapInCompressed(job, outputFile) ??
              compressedFilename;
        }
        // deleteOriginal=false keeps BOTH files (ecom-py parity) and
        // records the _compressed basename in the DB.

        _onComplete?.call(job.transactionId, true, {
          'status': CompressionStatus.completed.value,
          'compressed_file_size_mb': compressedSizeMb,
          'compression_ratio': compressionRatio,
          'compressed_filename': compressedFilename,
          'message': 'Compressed successfully '
              '(${compressionRatio.toStringAsFixed(1)}% reduction)',
        });
      } else {
        final failMessage =
            success ? 'FFmpeg produced an empty output file' : message;
        _logger.error('Compression failed: $failMessage');

        // Clean up partial output if it exists - the original is never
        // touched on the failure path.
        if (outputFile.existsSync()) {
          try {
            outputFile.deleteSync();
          } catch (_) {
            // Best-effort cleanup.
          }
        }

        _onComplete?.call(job.transactionId, false, {
          'status': CompressionStatus.failed.value,
          'message': failMessage,
        });
      }
    } catch (e) {
      _logger.error('Error processing compression job: $e');
      _onComplete?.call(job.transactionId, false, {
        'status': CompressionStatus.failed.value,
        'message': '$e',
      });
    }
  }

  /// Atomically replaces the original with the compressed file (COMP-03):
  /// original -> .bak, temp -> original, delete .bak. Every intermediate
  /// crash point leaves at least one intact copy on disk. Returns the
  /// final filename, or null if the swap failed (in which case a
  /// best-effort restore of the original is attempted).
  String? _swapInCompressed(CompressionJob job, File outputFile) {
    final backupPath = '${job.videoPath}.bak';
    try {
      File(job.videoPath).renameSync(backupPath);
      outputFile.renameSync(job.videoPath);
      File(backupPath).deleteSync();
      _logger.info('Replaced original file with compressed version');
      return p.basename(job.videoPath);
    } catch (e) {
      _logger.error('Error replacing original file: $e');
      // Restore the original if the swap left it missing.
      try {
        if (!File(job.videoPath).existsSync() &&
            File(backupPath).existsSync()) {
          File(backupPath).renameSync(job.videoPath);
        }
      } catch (restoreError) {
        _logger.error('Error restoring original file: $restoreError');
      }
      return null;
    }
  }

  /// Executes the FFmpeg command for [job]. Returns (success, message).
  Future<(bool, String)> _compressVideo(CompressionJob job) async {
    final settings = job.settings;
    final videoCodec = settings.codec == 'h265' ? 'libx265' : 'libx264';
    final crf = settings.crf.clamp(18, 35);

    // Cap the encode at the source's bitrate: recordings are already H.264
    // at the configured recording bitrate, and an uncapped CRF encode can
    // exceed it (e.g. CRF 23 at 4K produces ~9 Mbit/s - "compressing" a
    // 6 Mbit/s original into a larger file). null = probe unavailable,
    // encode uncapped as before.
    final sourceKbps = await _bitrateProber(job.videoPath);

    // Same invocation as ecom-py: capped threads so compression can't
    // starve capture/UI, AAC audio passthrough settings, -y to overwrite
    // a stale temp file.
    final args = <String>[
      '-i', job.videoPath,
      if (job.videoFilter != null) ...['-vf', job.videoFilter!],
      '-c:v', videoCodec,
      '-crf', '$crf',
      '-preset', settings.preset,
      if (sourceKbps != null && sourceKbps > 0) ...[
        '-maxrate', '${sourceKbps}k',
        '-bufsize', '${sourceKbps * 2}k',
      ],
      '-threads', '2',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-y',
      job.outputPath!,
    ];

    final executable = _ffmpegPath ?? 'ffmpeg';
    _logger.info(
      'Running FFmpeg command (priority: ${settings.priority}): '
      '$executable ${args.join(' ')}',
    );

    try {
      final process = await _processStarter(executable, args);

      // Lower the child's priority immediately after spawn (SET-06).
      try {
        if (!_priorityApplier(process.pid, settings.priority)) {
          _logger.warning(
            'Could not set FFmpeg process priority (${settings.priority})',
          );
        }
      } catch (e) {
        _logger.warning('Error setting FFmpeg process priority: $e');
      }

      // Drain both pipes so FFmpeg can never block on a full pipe buffer
      // (ecom-py redirects to DEVNULL for the same reason).
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());

      var timedOut = false;
      final exitCode = await process.exitCode.timeout(
        _jobTimeout,
        onTimeout: () {
          timedOut = true;
          process.kill(ProcessSignal.sigkill);
          // Give the kill a bounded window to take effect.
          return process.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () => -1,
          );
        },
      );

      if (timedOut) {
        return (
          false,
          'Compression timed out (exceeded ${_jobTimeout.inSeconds}s)',
        );
      }

      _logger.info('FFmpeg process completed with return code: $exitCode');
      if (exitCode == 0) {
        return (true, 'Compression successful');
      }
      return (false, 'FFmpeg error (return code $exitCode)');
    } catch (e) {
      return (false, 'Error running FFmpeg: $e');
    }
  }

  /// Default starter: argument-list spawn, never through a shell
  /// (T-03-01). Whether a console window flashes on real hardware is a
  /// Phase-5 packaging checkpoint (FFmpeg is not installed on the dev
  /// machine); if it does, swap this seam for an FFI CreateProcess with
  /// CREATE_NO_WINDOW.
  static Future<Process> _defaultProcessStarter(
    String executable,
    List<String> arguments,
  ) {
    return Process.start(executable, arguments, runInShell: false);
  }
}
