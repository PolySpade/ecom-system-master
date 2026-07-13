/// FFmpeg Locator - finds the ffmpeg/ffprobe binaries on this machine.
///
/// Behavioral port of ecom-py/video_compressor.py's check_ffmpeg_installed()
/// search order: (1) bundled `ffmpeg/bin/` (and `ffmpeg/`, and the exe's own
/// directory) beside the executable, (2) common Windows install paths,
/// (3) the system PATH. Results are cached for the process lifetime.
///
/// This contract is shared by the watermark step (Phase 2) and the
/// compression pipeline (Phase 3) - keep it minimal and generic.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Locates FFmpeg tooling. Both lookups return the full path to the binary,
/// or null when it cannot be found anywhere.
class FfmpegLocator {
  FfmpegLocator._();

  static String? _cachedFfmpeg;
  static bool _searchedFfmpeg = false;

  static String? _cachedFfprobe;
  static bool _searchedFfprobe = false;

  /// Returns the full path to `ffmpeg`, or null if not found.
  static Future<String?> findFfmpeg() async {
    if (!_searchedFfmpeg) {
      _cachedFfmpeg = await _find('ffmpeg');
      _searchedFfmpeg = true;
    }
    return _cachedFfmpeg;
  }

  /// Returns the full path to `ffprobe`, or null if not found.
  static Future<String?> findFfprobe() async {
    if (!_searchedFfprobe) {
      _cachedFfprobe = await _find('ffprobe');
      _searchedFfprobe = true;
    }
    return _cachedFfprobe;
  }

  /// Clears the cached lookup results (used by tests, and by a future
  /// Settings "Refresh" action after the user installs FFmpeg).
  static void resetCache() {
    _cachedFfmpeg = null;
    _searchedFfmpeg = false;
    _cachedFfprobe = null;
    _searchedFfprobe = false;
  }

  static Future<String?> _find(String toolName) async {
    final exeName = Platform.isWindows ? '$toolName.exe' : toolName;
    final exeDir = p.dirname(Platform.resolvedExecutable);

    final candidates = <String>[
      // (1) Bundled beside the executable (preferred deployment layout).
      p.join(exeDir, 'ffmpeg', 'bin', exeName),
      p.join(exeDir, 'ffmpeg', exeName),
      p.join(exeDir, exeName),
      // (2) Common Windows install paths (matches ecom-py's lookup list).
      if (Platform.isWindows) ...[
        p.join(r'C:\ffmpeg\bin', exeName),
        p.join(r'C:\Program Files\ffmpeg\bin', exeName),
        p.join(r'C:\Program Files (x86)\ffmpeg\bin', exeName),
        if (Platform.environment['USERPROFILE'] != null)
          p.join(Platform.environment['USERPROFILE']!, 'ffmpeg', 'bin',
              exeName),
      ],
    ];

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    // (3) System PATH.
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [toolName],
      );
      if (result.exitCode == 0) {
        final firstLine = (result.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty, orElse: () => '');
        if (firstLine.isNotEmpty && File(firstLine).existsSync()) {
          return firstLine;
        }
      }
    } catch (_) {
      // `where`/`which` unavailable - treat as not found.
    }

    return null;
  }
}
