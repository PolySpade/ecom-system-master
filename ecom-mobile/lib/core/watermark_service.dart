/// Watermark Service - post-save FFmpeg drawtext watermarking.
///
/// Mobile port of the desktop watermark pass: timestamp top-left, label
/// top-right on the #667eea brand box, "Barcode: X" bottom-left, white text
/// on dark boxes. The running timestamp uses drawtext's `pts:localtime`
/// expansion seeded with the recording's start epoch, so it advances during
/// playback exactly like the reference's per-frame stamps.
///
/// On Android FFmpeg runs in-process through ffmpeg_kit_flutter_new (the
/// bundled build includes libx264), and the font comes from the system
/// fonts directory (/system/fonts) instead of C:\Windows\Fonts. This is the
/// ONLY re-encode on mobile - recordings are already hardware-encoded at
/// the configured bitrate, so there is no separate compression pass; the
/// desktop compressor's role collapses into this single watermark encode.
///
/// Jobs run on a serialized queue (one FFmpeg session at a time). Failure
/// policy (never lose the video): when a usable font is missing or the
/// re-encode fails, the original saved file is left intact and a warning is
/// logged - the recording is simply unwatermarked.
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;

import 'logger.dart';

/// Outcome of a watermark job.
enum WatermarkOutcome { completed, skippedNoFont, failed }

/// One saved recording to watermark.
class WatermarkJob {
  const WatermarkJob({
    required this.videoPath,
    required this.barcode,
    required this.label,
    required this.recordingStart,
  });

  /// Full path of the saved (final-location) video file.
  final String videoPath;

  /// Normalized barcode (bottom-left watermark text).
  final String barcode;

  /// Video Label (top-right watermark text), e.g. "Normal (Standard)".
  final String label;

  /// Recording start time - seeds the running timestamp (top-left).
  final DateTime recordingStart;
}

/// Live queue state for the UI status indicator.
class WatermarkQueueStatus {
  const WatermarkQueueStatus({
    required this.pendingCount,
    required this.isProcessing,
  });

  final int pendingCount;
  final bool isProcessing;

  @override
  bool operator ==(Object other) =>
      other is WatermarkQueueStatus &&
      other.pendingCount == pendingCount &&
      other.isProcessing == isProcessing;

  @override
  int get hashCode => Object.hash(pendingCount, isProcessing);
}

/// Font candidates checked in order under the Android system fonts
/// directory. Roboto ships on every stock Android; the rest cover common
/// OEM variations.
const List<String> _fontCandidates = [
  'Roboto-Regular.ttf',
  'NotoSans-Regular.ttf',
  'DroidSans.ttf',
  'NotoSerif-Regular.ttf',
];

/// Returns the first available system font file usable by drawtext, or
/// null when none exists. [fontsDir] is overridable for tests.
String? findSystemFontFile({String fontsDir = '/system/fonts'}) {
  for (final name in _fontCandidates) {
    final path = p.join(fontsDir, name);
    if (File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

/// Escapes [text] for use inside a single-quoted drawtext `text='...'`
/// value: backslashes are doubled, embedded single quotes close/reopen the
/// quoted section, and `:`/`,` are backslash-escaped (FFmpeg applies
/// backslash escaping INSIDE single quotes at the filtergraph level and
/// treats a bare `:` there as an option separator).
String escapeDrawtextText(String text) {
  return text
      .replaceAll('\\', '\\\\')
      .replaceAll("'", r"'\''")
      .replaceAll(':', r'\:')
      .replaceAll(',', r'\,')
      .replaceAll('\n', ' ')
      .replaceAll('\r', ' ');
}

/// Normalizes a font path for embedding in a filtergraph: forward slashes,
/// any colon escaped (harmless on Android paths, required on Windows-style
/// test paths).
String _filterFontPath(String fontFile) {
  return fontFile.replaceAll('\\', '/').replaceAll(':', r'\:');
}

/// Builds the full -vf filtergraph: three drawtext overlays matching the
/// ecom-py layout. [startEpochSeconds] seeds the running timestamp.
String buildWatermarkFilter({
  required String fontFile,
  required String barcode,
  required String label,
  required int startEpochSeconds,
}) {
  final font = _filterFontPath(fontFile);
  final common = 'fontsize=24:fontcolor=white:boxborderw=6:box=1';

  // Timestamp top-left: running clock, default localtime format
  // '%Y-%m-%d %H:%M:%S' matches ecom-py's strftime format exactly.
  final timestamp =
      "drawtext=fontfile='$font'"
      ":text='%{pts\\:localtime\\:$startEpochSeconds}'"
      ':$common:boxcolor=black@0.7:x=10:y=10';

  // Label top-right on the #667eea brand box.
  final labelText = escapeDrawtextText(label);
  final labelFilter =
      "drawtext=fontfile='$font':expansion=none"
      ":text='$labelText'"
      ':$common:boxcolor=0x667eea@1.0:x=w-tw-10:y=10';

  // Barcode bottom-left.
  final barcodeText = escapeDrawtextText('Barcode: $barcode');
  final barcodeFilter =
      "drawtext=fontfile='$font':expansion=none"
      ":text='$barcodeText'"
      ':$common:boxcolor=black@0.7:x=10:y=h-th-10';

  return '$timestamp,$labelFilter,$barcodeFilter';
}

/// Builds the complete post-save -vf chain for a recording: an optional
/// downscale to [targetHeight] (safety net in case the CameraX preset
/// recorded above the configured resolution; min(h, ih) never upscales),
/// followed by the three-part watermark. Returns an empty string when
/// nothing applies (callers skip the encode entirely then).
String buildRecordingPostFilter({
  required String barcode,
  required String label,
  required DateTime? startTime,
  required int targetHeight,
  String? fontFile,
}) {
  final parts = <String>[];

  if (targetHeight > 0) {
    parts.add('scale=-2:min($targetHeight\\,ih)');
  }

  final font = fontFile ?? findSystemFontFile();
  if (font != null && startTime != null) {
    parts.add(
      buildWatermarkFilter(
        fontFile: font,
        barcode: barcode,
        label: label,
        startEpochSeconds: startTime.millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  return parts.join(',');
}

/// Builds the ffmpeg argument list for the watermark re-encode. veryfast +
/// CRF 20 keeps quality high while staying light enough for phone CPUs;
/// audio is absent from recordings (enableAudio: false) so no audio args
/// are needed, but `-an` makes that explicit.
List<String> buildFfmpegArgs({
  required String inputPath,
  required String outputPath,
  required String filter,
}) {
  return [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    inputPath,
    '-vf',
    filter,
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-an',
    outputPath,
  ];
}

/// Result of one FFmpeg invocation (seam for tests).
class FfmpegRunResult {
  const FfmpegRunResult(this.exitCode, [this.output = '']);

  final int exitCode;
  final String output;
}

/// Seam for executing FFmpeg (fake-able in tests). Defaults to an
/// in-process ffmpeg_kit session.
typedef FfmpegRunner = Future<FfmpegRunResult> Function(List<String> args);

/// Default [FfmpegRunner]: runs the args through ffmpeg_kit and maps the
/// session's return code (null = crashed session -> -1).
Future<FfmpegRunResult> runFfmpegKit(List<String> args) async {
  final session = await FFmpegKit.executeWithArguments(args);
  final returnCode = await session.getReturnCode();
  final logs = await session.getAllLogsAsString() ?? '';
  if (ReturnCode.isSuccess(returnCode)) {
    return FfmpegRunResult(0, logs);
  }
  return FfmpegRunResult(returnCode?.getValue() ?? -1, logs);
}

/// Serialized post-save watermark worker.
class WatermarkService {
  WatermarkService(
    this._logger, {
    FfmpegRunner? runFfmpeg,
    String? Function()? findFont,
  }) : _runFfmpeg = runFfmpeg ?? runFfmpegKit,
       _findFont = findFont ?? findSystemFontFile;

  final Logger _logger;
  final FfmpegRunner _runFfmpeg;
  final String? Function() _findFont;

  Future<void> _tail = Future<void>.value();
  int _pendingCount = 0;
  bool _processing = false;

  /// Jobs queued or in flight.
  int get pendingCount => _pendingCount;

  /// Whether a job is currently being processed.
  bool get isProcessing => _processing;

  /// Live queue state for the UI (status bar indicator).
  final ValueNotifier<WatermarkQueueStatus> queueStatus =
      ValueNotifier<WatermarkQueueStatus>(
    const WatermarkQueueStatus(pendingCount: 0, isProcessing: false),
  );

  void _notifyStatus() {
    queueStatus.value = WatermarkQueueStatus(
      pendingCount: _pendingCount,
      isProcessing: _processing,
    );
  }

  /// Enqueues [job] on the serialized worker. The returned Future completes
  /// with the job's outcome once it has run. Errors are captured into
  /// [WatermarkOutcome.failed] - the Future never throws.
  Future<WatermarkOutcome> enqueue(WatermarkJob job) {
    _pendingCount++;
    _notifyStatus();

    final result = _tail.then((_) async {
      _processing = true;
      _notifyStatus();
      try {
        return await _process(job);
      } catch (e) {
        _logger.error('Error watermarking ${job.videoPath}: $e');
        return WatermarkOutcome.failed;
      } finally {
        _processing = false;
        _pendingCount--;
        _notifyStatus();
      }
    });

    // Chain the tail regardless of individual job outcome.
    _tail = result.then((_) {});
    return result;
  }

  Future<WatermarkOutcome> _process(WatermarkJob job) async {
    final input = File(job.videoPath);
    if (!input.existsSync()) {
      _logger.warning('Watermark skipped - file not found: ${job.videoPath}');
      return WatermarkOutcome.failed;
    }

    final fontFile = _findFont();
    if (fontFile == null) {
      _logger.warning(
        'No usable font found - skipping watermark for '
        '${p.basename(job.videoPath)} (video saved unwatermarked)',
      );
      return WatermarkOutcome.skippedNoFont;
    }

    final filter = buildWatermarkFilter(
      fontFile: fontFile,
      barcode: job.barcode,
      label: job.label,
      startEpochSeconds: job.recordingStart.millisecondsSinceEpoch ~/ 1000,
    );

    final dir = p.dirname(job.videoPath);
    final base = p.basenameWithoutExtension(job.videoPath);
    final tmpPath = p.join(dir, '$base.wm_tmp.mp4');
    final bakPath = p.join(dir, '$base.wm_bak.mp4');
    final tmpFile = File(tmpPath);

    try {
      final result = await _runFfmpeg(
        buildFfmpegArgs(
          inputPath: job.videoPath,
          outputPath: tmpPath,
          filter: filter,
        ),
      );

      if (result.exitCode != 0 ||
          !tmpFile.existsSync() ||
          tmpFile.lengthSync() == 0) {
        _logger.warning(
          'Watermark failed for ${p.basename(job.videoPath)} '
          '(exit ${result.exitCode}): ${result.output} '
          '- keeping unwatermarked original',
        );
        _deleteQuietly(tmpFile);
        return WatermarkOutcome.failed;
      }

      // Backup-swap so the original can never be lost: original -> .bak,
      // tmp -> original, delete .bak. Any failure restores the backup.
      final bakFile = File(bakPath);
      await input.rename(bakPath);
      try {
        await tmpFile.rename(job.videoPath);
      } catch (e) {
        await bakFile.rename(job.videoPath);
        _deleteQuietly(tmpFile);
        _logger.error(
          'Error swapping watermarked file for ${job.videoPath}: $e '
          '- original restored',
        );
        return WatermarkOutcome.failed;
      }
      _deleteQuietly(bakFile);

      _logger.info('Watermark applied: ${p.basename(job.videoPath)}');
      return WatermarkOutcome.completed;
    } catch (e) {
      _deleteQuietly(tmpFile);
      _logger.error('Error watermarking ${job.videoPath}: $e');
      return WatermarkOutcome.failed;
    }
  }

  void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // Cleanup failures are non-fatal.
    }
  }
}
