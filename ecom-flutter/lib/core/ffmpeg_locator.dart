/// FFmpeg Locator - discovers ffmpeg/ffprobe binaries at runtime (COMP-02).
///
/// Behavioral port of the discovery logic in
/// ecom-py/video_compressor.py's check_ffmpeg_installed(): bundled
/// locations beside the executable are checked first, then common Windows
/// install paths, then every directory on PATH. Unlike ecom-py this class
/// verifies discovery by file existence rather than spawning
/// `ffmpeg -version` - callers get a concrete path or null, never a hung
/// child process.
///
/// NOTE: this file's public contract (`findFfmpeg`/`findFfprobe`) is shared
/// with the Phase-2 worktree's watermarking work - do not change the two
/// static method signatures.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// Static discovery of FFmpeg-family executables: bundled dir beside the
/// executable, common install paths, then PATH. Results are cached per
/// executable name for the process lifetime (mirrors ecom-py's
/// `_ffmpeg_available` cache).
class FfmpegLocator {
  FfmpegLocator._();

  /// Cached lookups keyed by base executable name ('ffmpeg', 'ffprobe').
  /// A key being present with a null value means "searched, not found".
  static final Map<String, String?> _cache = {};

  /// Test seam: overrides the directory treated as "beside the executable".
  @visibleForTesting
  static String? debugBaseDirOverride;

  /// Test seam: overrides the common-install-path candidates.
  @visibleForTesting
  static List<String>? debugCommonPathsOverride;

  /// Test seam: overrides [Platform.environment] (for PATH scanning).
  @visibleForTesting
  static Map<String, String>? debugEnvironmentOverride;

  /// Clears the per-process discovery cache (test use).
  @visibleForTesting
  static void resetCache() => _cache.clear();

  /// Returns the full path to `ffmpeg` (`ffmpeg.exe` on Windows), or null
  /// when it cannot be found in the bundled dir, common install paths, or
  /// PATH.
  static Future<String?> findFfmpeg() async => _find('ffmpeg');

  /// Returns the full path to `ffprobe` (`ffprobe.exe` on Windows), or null
  /// when it cannot be found in the bundled dir, common install paths, or
  /// PATH.
  static Future<String?> findFfprobe() async => _find('ffprobe');

  static String? _find(String name) {
    if (_cache.containsKey(name)) {
      return _cache[name];
    }
    final found = _search(name);
    _cache[name] = found;
    return found;
  }

  static String? _search(String name) {
    final exeName = Platform.isWindows ? '$name.exe' : name;

    for (final candidate in _candidatePaths(exeName)) {
      if (File(candidate).existsSync()) {
        return p.normalize(candidate);
      }
    }
    return null;
  }

  /// Ordered candidate file paths: (1) bundled beside the executable,
  /// (2) common install locations, (3) each directory on PATH. Mirrors
  /// ecom-py/video_compressor.py's `common_paths` ordering.
  static Iterable<String> _candidatePaths(String exeName) sync* {
    final baseDir =
        debugBaseDirOverride ?? p.dirname(Platform.resolvedExecutable);

    // (1) Bundled beside the executable - the install-controlled location
    // checked first, matching ecom-py's script_dir candidates.
    yield p.join(baseDir, exeName);
    yield p.join(baseDir, 'ffmpeg', exeName);
    yield p.join(baseDir, 'ffmpeg', 'bin', exeName);

    // (2) Common install paths (Windows-only in ecom-py; harmless no-ops
    // elsewhere since the files simply won't exist).
    final environment = debugEnvironmentOverride ?? Platform.environment;
    final commonDirs = debugCommonPathsOverride ??
        (Platform.isWindows
            ? [
                r'C:\ffmpeg\bin',
                r'C:\Program Files\ffmpeg\bin',
                r'C:\Program Files (x86)\ffmpeg\bin',
                if (environment['USERPROFILE'] != null)
                  p.join(environment['USERPROFILE']!, 'ffmpeg', 'bin'),
              ]
            : const <String>[]);
    for (final dir in commonDirs) {
      yield p.join(dir, exeName);
    }

    // (3) PATH scan.
    final pathValue = environment['PATH'] ?? environment['Path'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    for (final dir in pathValue.split(separator)) {
      if (dir.trim().isEmpty) continue;
      yield p.join(dir.trim(), exeName);
    }
  }
}
