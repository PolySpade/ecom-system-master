/// Watermark Service - post-save FFmpeg drawtext watermarking.
///
/// Behavioral port of ecom-py/camera_handler.py's _add_timestamp_watermark
/// layout (timestamp top-left, label top-right on the #667eea brand box,
/// "Barcode: X" bottom-left, white text on dark boxes) - implemented as a
/// post-save re-encode because camera_windows does not expose per-frame
/// access. The running timestamp uses drawtext's `pts:localtime` expansion
/// seeded with the recording's start epoch, so it advances during playback
/// exactly like the reference's per-frame stamps.
///
/// Jobs run on a serialized queue (one FFmpeg process at a time - same
/// discipline as ecom-py's compression worker thread). The Phase-3
/// compression queue chains onto a job by awaiting the Future returned from
/// [WatermarkService.enqueue] and then queueing compression for the same
/// path.
///
/// Failure policy (never lose the video): when FFmpeg or a usable font is
/// missing, or the re-encode fails, the original saved file is left intact
/// and a warning is logged - the recording is simply unwatermarked.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg_locator.dart';
import 'logger.dart';

/// Outcome of a watermark job.
enum WatermarkOutcome { completed, skippedNoFfmpeg, skippedNoFont, failed }

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

/// Font candidates checked in order under the Windows fonts directory.
const List<String> _fontCandidates = ['arial.ttf', 'segoeui.ttf', 'calibri.ttf'];

/// Returns the first available Windows font file usable by drawtext, or
/// null when none exists. [fontsDir] is overridable for tests.
String? findWindowsFontFile({String fontsDir = r'C:\Windows\Fonts'}) {
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
/// quoted section, and `:`/`,` are backslash-escaped. The bundled FFmpeg
/// (2026 git master) applies backslash escaping INSIDE single quotes at the
/// filtergraph level and treats a bare `:` there as an option separator -
/// verified empirically against ffmpeg-2026-07-09; quoting alone is NOT
/// sufficient on this build.
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
/// drive colon escaped (quoted sections still require the colon escape on
/// some ffmpeg builds, so escape defensively).
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
  final timestamp = "drawtext=fontfile='$font'"
      ":text='%{pts\\:localtime\\:$startEpochSeconds}'"
      ':$common:boxcolor=black@0.7:x=10:y=10';

  // Label top-right on the #667eea brand box (ecom-py's intended identity
  // color - see key-decisions in the plan summary).
  final labelText = escapeDrawtextText(label);
  final labelFilter = "drawtext=fontfile='$font':expansion=none"
      ":text='$labelText'"
      ':$common:boxcolor=0x667eea@1.0:x=w-tw-10:y=10';

  // Barcode bottom-left.
  final barcodeText = escapeDrawtextText('Barcode: $barcode');
  final barcodeFilter = "drawtext=fontfile='$font':expansion=none"
      ":text='$barcodeText'"
      ':$common:boxcolor=black@0.7:x=10:y=h-th-10';

  return '$timestamp,$labelFilter,$barcodeFilter';
}

/// Builds the complete post-save -vf chain for a recording: a downscale to
/// [targetHeight] followed by the three-part watermark.
///
/// The downscale exists because camera_windows opens its RECORD stream at
/// the camera's maximum resolution regardless of ResolutionPreset (the
/// preset caps only the preview - see capture_controller.cpp's
/// FindBaseMediaTypesForSource), so a "4K" webcam always records 4K. The
/// scale normalizes output to the configured resolution; min(h, ih) never
/// upscales smaller sources.
///
/// Falls back gracefully: no usable font -> scale-only; targetHeight <= 0
/// -> watermark-only; neither -> null (caller queues a plain compression).
String? buildRecordingPostFilter({
  required String barcode,
  required String label,
  required DateTime? startTime,
  required int targetHeight,
  String? fontFile,
}) {
  final scale =
      targetHeight > 0 ? 'scale=-2:min($targetHeight\\,ih)' : null;

  final font = fontFile ?? findWindowsFontFile();
  String? watermark;
  if (font != null && startTime != null) {
    watermark = buildWatermarkFilter(
      fontFile: font,
      barcode: barcode,
      label: label,
      startEpochSeconds: startTime.millisecondsSinceEpoch ~/ 1000,
    );
  }

  if (scale != null && watermark != null) return '$scale,$watermark';
  return watermark ?? scale;
}

/// Builds the ffmpeg argument list (no shell involved - args are passed
/// directly to the process). High-quality re-encode: the Phase-3
/// compression pass owns the real size reduction.
List<String> buildFfmpegArgs({
  required String inputPath,
  required String outputPath,
  required String filter,
}) {
  return [
    '-y',
    '-hide_banner',
    '-loglevel', 'error',
    '-i', inputPath,
    '-vf', filter,
    '-c:v', 'libx264',
    '-preset', 'veryfast',
    '-crf', '18',
    '-c:a', 'copy',
    outputPath,
  ];
}

/// Serialized post-save watermark worker.
class WatermarkService {
  WatermarkService(
    this._logger, {
    Future<String?> Function()? findFfmpeg,
    Future<ProcessResult> Function(String executable, List<String> args)?
        runProcess,
    String? Function()? findFont,
  })  : _findFfmpeg = findFfmpeg ?? FfmpegLocator.findFfmpeg,
        _runProcess =
            runProcess ?? ((exe, args) => Process.run(exe, args)),
        _findFont = findFont ?? findWindowsFontFile;

  final Logger _logger;
  final Future<String?> Function() _findFfmpeg;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final String? Function() _findFont;

  Future<void> _tail = Future<void>.value();
  int _pendingCount = 0;
  bool _processing = false;

  /// Jobs queued or in flight.
  int get pendingCount => _pendingCount;

  /// Whether a job is currently being processed.
  bool get isProcessing => _processing;

  /// Invoked whenever the queue state changes (UI status hook).
  void Function()? onQueueChanged;

  /// Enqueues [job] on the serialized worker. The returned Future completes
  /// with the job's outcome once it has run (Phase-3 compression chains
  /// here). Errors are captured into [WatermarkOutcome.failed] - the Future
  /// never throws.
  Future<WatermarkOutcome> enqueue(WatermarkJob job) {
    _pendingCount++;
    onQueueChanged?.call();

    final result = _tail.then((_) async {
      _processing = true;
      onQueueChanged?.call();
      try {
        return await _process(job);
      } catch (e) {
        _logger.error('Error watermarking ${job.videoPath}: $e');
        return WatermarkOutcome.failed;
      } finally {
        _processing = false;
        _pendingCount--;
        onQueueChanged?.call();
      }
    });

    // Chain the tail regardless of individual job outcome.
    _tail = result.then((_) {});
    return result;
  }

  Future<WatermarkOutcome> _process(WatermarkJob job) async {
    final input = File(job.videoPath);
    if (!input.existsSync()) {
      _logger.warning(
        'Watermark skipped - file not found: ${job.videoPath}',
      );
      return WatermarkOutcome.failed;
    }

    final ffmpegPath = await _findFfmpeg();
    if (ffmpegPath == null) {
      _logger.warning(
        'FFmpeg not found - skipping watermark for '
        '${p.basename(job.videoPath)} (video saved unwatermarked)',
      );
      return WatermarkOutcome.skippedNoFfmpeg;
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
      final result = await _runProcess(
        ffmpegPath,
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
          '(exit ${result.exitCode}): ${result.stderr} '
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
