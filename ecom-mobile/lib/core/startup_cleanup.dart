/// Startup cleanup - removes stale post-processing temp files left behind
/// when the app was killed mid-FFmpeg (the atomic-swap design guarantees
/// the originals survive; only the temps are junk).
library;

import 'dart:io';

import 'logger.dart';

/// Deletes stale temp files under [videoRoot]:
/// - `*.wm_tmp.mp4` / `*.wm_bak` (legacy separate watermark pass)
/// - zero-byte `*_compressed.mp4` (FFmpeg killed before writing anything)
/// - non-empty `*_compressed.mp4` whose original still exists, when
///   [deleteOriginalMode] is true - after a successful swap the temp name
///   never coexists with the original, so such a pair is an interrupted
///   job. When delete-original is off, side-by-side compressed copies are
///   legitimate output and are left alone.
Future<int> cleanStaleTempFiles(
  String videoRoot, {
  required bool deleteOriginalMode,
  required Logger logger,
}) async {
  final root = Directory(videoRoot);
  if (!root.existsSync()) return 0;

  var removed = 0;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path;

    var stale = path.endsWith('.wm_tmp.mp4') || path.endsWith('.wm_bak');
    if (!stale && path.endsWith('_compressed.mp4')) {
      if (entity.lengthSync() == 0) {
        stale = true;
      } else if (deleteOriginalMode) {
        final original =
            '${path.substring(0, path.length - '_compressed.mp4'.length)}.mp4';
        stale = File(original).existsSync();
      }
    }

    if (stale) {
      try {
        entity.deleteSync();
        removed++;
        logger.info('Removed stale temp file: $path');
      } catch (e) {
        logger.warning('Could not remove stale temp file $path: $e');
      }
    }
  }
  return removed;
}
