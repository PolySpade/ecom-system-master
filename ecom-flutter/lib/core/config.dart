/// Config - Minimal settings read (camera index, video path, etc.) for
/// Phase 1.
///
/// Behavioral port of ecom-py/config.py + ecom-py/settings_manager.py:
/// base dir resolves beside the executable (matching PyInstaller frozen-exe
/// behavior), settings.json is deep-merged over full defaults, relative
/// storage paths resolve against the base dir while absolute paths pass
/// through unchanged.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Full DEFAULT_SETTINGS map, mirroring
/// ecom-py/settings_manager.py's SettingsManager.DEFAULT_SETTINGS, reduced
/// to the categories/keys Phases 1 and 3 need (the 'compression' category
/// matches ecom-py key-for-key).
const Map<String, Map<String, Object?>> _defaultSettings = {
  'video': {
    'resolution_width': 1280,
    'resolution_height': 720,
    'fps': 30,
    'codec': 'mp4v',
  },
  'camera': {
    'index': 0,
    'auto_exposure': true,
    'exposure': -4,
    'gain': 0,
    'brightness': 128,
  },
  'storage': {
    'video_path': 'videos',
    'database_path': 'database.db',
    'log_path': 'logs',
  },
  'app': {
    'flask_host': '127.0.0.1',
    'flask_port': 5000,
    'debug_mode': false,
  },
  'compression': {
    'enabled': true,
    'codec': 'h264', // 'h264' or 'h265'
    'crf': 23, // 18-35 (lower = better quality)
    'preset': 'medium', // ultrafast/fast/medium/slow
    'delete_original': true, // Delete original after successful compression
    'priority': 'below_normal', // 'low', 'below_normal', or 'normal'
  },
};

/// Loads settings.json (if present) beside the executable, deep-merges it
/// over [_defaultSettings], and exposes typed getters for the values this
/// phase's services need.
class Config {
  Config._(this._baseDir, this._settings);

  final String _baseDir;
  final Map<String, Map<String, Object?>> _settings;

  /// Base directory: the directory containing the running executable,
  /// matching ecom-py's `sys.frozen` "beside the executable" behavior.
  String get baseDir => _baseDir;

  /// Loads config from `settings.json` beside [Platform.resolvedExecutable],
  /// deep-merging over full defaults. Tolerates a missing/invalid file by
  /// falling back to defaults entirely (T-01-03 mitigation).
  static Config load() {
    return loadFrom(p.dirname(Platform.resolvedExecutable));
  }

  /// Same as [load] but with an explicit base directory, so the
  /// settings.json merge behavior is unit-testable without depending on
  /// [Platform.resolvedExecutable].
  static Config loadFrom(String baseDir) {
    final merged = _deepCopyDefaults();

    final settingsFile = File(p.join(baseDir, 'settings.json'));
    if (settingsFile.existsSync()) {
      try {
        final raw = settingsFile.readAsStringSync();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _deepMerge(merged, decoded);
        }
      } catch (_) {
        // Malformed settings.json must not crash startup - fall back to
        // defaults (T-01-03).
      }
    }

    return Config._(baseDir, merged);
  }

  static Map<String, Map<String, Object?>> _deepCopyDefaults() {
    return _defaultSettings.map(
      (key, value) => MapEntry(key, Map<String, Object?>.from(value)),
    );
  }

  static void _deepMerge(
    Map<String, Map<String, Object?>> target,
    Map<String, dynamic> source,
  ) {
    for (final entry in source.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic> && target.containsKey(entry.key)) {
        target[entry.key]!.addAll(value);
      } else if (value is Map<String, dynamic>) {
        target[entry.key] = Map<String, Object?>.from(value);
      }
    }
  }

  Object? _get(String category, String key, Object? fallback) {
    return _settings[category]?[key] ?? fallback;
  }

  /// Resolves a possibly-relative storage path against [baseDir]. Absolute
  /// paths pass through unchanged (matches ecom-py's `os.path.normpath`
  /// behavior in config.py).
  String _resolvePath(String path) {
    if (p.isAbsolute(path)) {
      return p.normalize(path);
    }
    return p.normalize(p.join(_baseDir, path));
  }

  int get cameraIndex => (_get('camera', 'index', 0) as num).toInt();

  String get videoStoragePath =>
      _resolvePath(_get('storage', 'video_path', 'videos') as String);

  String get databasePath =>
      _resolvePath(_get('storage', 'database_path', 'database.db') as String);

  String get logPath =>
      _resolvePath(_get('storage', 'log_path', 'logs') as String);

  int get resolutionWidth =>
      (_get('video', 'resolution_width', 1280) as num).toInt();

  int get resolutionHeight =>
      (_get('video', 'resolution_height', 720) as num).toInt();

  int get fps => (_get('video', 'fps', 30) as num).toInt();

  String get codec => _get('video', 'codec', 'mp4v') as String;

  // Compression settings (COMP-04/SET-06) - keys/defaults mirror
  // ecom-py/settings_manager.py's 'compression' category exactly.

  bool get compressionEnabled =>
      _get('compression', 'enabled', true) as bool;

  /// 'h264' or 'h265'.
  String get compressionCodec =>
      _get('compression', 'codec', 'h264') as String;

  /// Constant Rate Factor, 18-35 (lower = better quality).
  int get compressionCrf =>
      (_get('compression', 'crf', 23) as num).toInt();

  /// FFmpeg preset: ultrafast/fast/medium/slow.
  String get compressionPreset =>
      _get('compression', 'preset', 'medium') as String;

  /// Whether the original file is replaced by the compressed one.
  bool get compressionDeleteOriginal =>
      _get('compression', 'delete_original', true) as bool;

  /// FFmpeg process priority: 'low', 'below_normal', or 'normal'.
  String get compressionPriority =>
      _get('compression', 'priority', 'below_normal') as String;
}
