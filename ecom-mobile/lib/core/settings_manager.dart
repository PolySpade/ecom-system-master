/// Settings Manager - application configuration with JSON persistence.
///
/// Behavioral port of ecom-py/settings_manager.py: a class-level
/// DEFAULT_SETTINGS map organized by category (video/camera/storage/app/
/// compression), recursively deep-merged with any on-disk `settings.json`
/// on load, saved back as human-editable indented JSON, with typed
/// convenience getters/setters mirroring the reference naming
/// (getVideoFps, getCameraIndex, ...). SET-07/SET-08.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'logger.dart';

/// Manages application settings with JSON file persistence.
class SettingsManager {
  /// Loads settings immediately from [settingsFilePath] (deep-merged over
  /// defaults). [logger] is optional because the settings file is read
  /// before the log path is known (matching ecom-py, where settings_manager
  /// logs via a module logger configured later).
  SettingsManager(this.settingsFilePath, {Logger? logger}) : _logger = logger {
    _settings = loadSettings();
  }

  /// Full defaults, mirroring ecom-py SettingsManager.DEFAULT_SETTINGS
  /// key-for-key so a settings.json written by either app parses in both.
  static const Map<String, Map<String, Object?>> defaultSettings = {
    'video': {
      'resolution_width': 1280,
      'resolution_height': 720,
      'fps': 30,
      'codec': 'mp4v',
      // Recording bitrate cap (kbit/s) applied to the camera's Media
      // Foundation encoder. Without it the webcam writes ~15-19 Mbit/s.
      // New key for the port (ecom-py records via OpenCV, no bitrate knob).
      'recording_bitrate_kbps': 6000,
      // Burn the timestamp/label/barcode watermark into saved videos. New
      // key for the port (ecom-py always watermarks); off skips the
      // drawtext part of the post-save pass.
      'watermark_enabled': true,
    },
    'camera': {
      'index': 0,
      'auto_exposure': true,
      'exposure': -4,
      'gain': 0,
      'brightness': 128,
    },
    'storage': {
      // Public Movies collection: gallery-visible, USB-copyable, survives
      // app uninstall. main.dart write-probes this at startup and falls
      // back to the app-private 'videos' dir when it isn't writable.
      'video_path': '/storage/emulated/0/Movies/EcomTracker',
      'database_path': 'database.db',
      'log_path': 'logs',
      // Free-space floor (GB) checked before each recording start (STO-02).
      // ecom-py has no free-space guard, so this key is new to the port.
      'min_free_space_gb': 1.0,
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
      'delete_original': true, // delete original after successful compression
      'priority': 'below_normal', // 'low', 'below_normal', or 'normal'
    },
  };

  /// Full path of the settings.json file this manager reads/writes.
  final String settingsFilePath;

  final Logger? _logger;

  late Map<String, dynamic> _settings;

  /// Loads settings from the JSON file, deep-merged over defaults; returns
  /// a fresh copy of the defaults when the file is missing or malformed
  /// (malformed settings.json must never crash startup).
  Map<String, dynamic> loadSettings() {
    final file = File(settingsFilePath);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          final settings = _copyDefaults();
          deepMerge(settings, decoded);
          _logger?.info('Settings loaded from $settingsFilePath');
          return settings;
        }
        _logger?.error('Error loading settings: not a JSON object, '
            'using defaults');
        return _copyDefaults();
      } catch (e) {
        _logger?.error('Error loading settings: $e, using defaults');
        return _copyDefaults();
      }
    }
    _logger?.info('Settings file not found, using defaults');
    return _copyDefaults();
  }

  /// Saves current settings to the JSON file as human-editable indented
  /// JSON (matching ecom-py's json.dump(..., indent=4)). Returns false on
  /// failure instead of throwing.
  bool saveSettings() {
    try {
      const encoder = JsonEncoder.withIndent('    ');
      File(settingsFilePath).writeAsStringSync(encoder.convert(_settings));
      _logger?.info('Settings saved to $settingsFilePath');
      return true;
    } catch (e) {
      _logger?.error('Error saving settings: $e');
      return false;
    }
  }

  /// Gets a specific setting value.
  Object? get(String category, String key, [Object? defaultValue]) {
    final cat = _settings[category];
    if (cat is Map) {
      return cat.containsKey(key) ? cat[key] : defaultValue;
    }
    return defaultValue;
  }

  /// Sets a specific setting value.
  void set(String category, String key, Object? value) {
    final cat = _settings.putIfAbsent(category, () => <String, dynamic>{});
    (cat as Map)[key] = value;
  }

  /// Returns a copy of all settings.
  Map<String, dynamic> getAll() => _deepCopy(_settings);

  /// Updates an entire category of settings (merging over existing keys).
  void updateCategory(String category, Map<String, Object?> data) {
    final existing = _settings[category];
    if (existing is Map) {
      existing.addAll(data);
    } else {
      _settings[category] = Map<String, Object?>.from(data);
    }
  }

  /// Resets all settings to defaults (in-memory only, matching ecom-py's
  /// reset_to_defaults - callers decide whether to save afterwards).
  void resetToDefaults() {
    _settings = _copyDefaults();
    _logger?.info('Settings reset to defaults');
  }

  /// Recursively merges [updates] into [base]: nested maps merge key-wise,
  /// scalar values in [updates] overwrite (exact port of ecom-py's
  /// _deep_merge).
  static void deepMerge(Map<String, dynamic> base, Map<String, dynamic> updates) {
    for (final entry in updates.entries) {
      final existing = base[entry.key];
      final value = entry.value;
      if (existing is Map<String, dynamic> && value is Map<String, dynamic>) {
        deepMerge(existing, value);
      } else if (existing is Map && value is Map) {
        final target = Map<String, dynamic>.from(existing);
        deepMerge(target, Map<String, dynamic>.from(value));
        base[entry.key] = target;
      } else {
        base[entry.key] = value;
      }
    }
  }

  static Map<String, dynamic> _copyDefaults() => _deepCopy(defaultSettings);

  static Map<String, dynamic> _deepCopy(Map source) {
    final copy = <String, dynamic>{};
    for (final entry in source.entries) {
      final value = entry.value;
      copy[entry.key as String] = value is Map ? _deepCopy(value) : value;
    }
    return copy;
  }

  // Convenience methods for specific settings (naming mirrors ecom-py's
  // get_video_fps/get_camera_index/... pattern).

  /// Gets video resolution as (width, height).
  (int, int) getVideoResolution() {
    return (
      (get('video', 'resolution_width', 1280) as num).toInt(),
      (get('video', 'resolution_height', 720) as num).toInt(),
    );
  }

  /// Sets video resolution.
  void setVideoResolution(int width, int height) {
    set('video', 'resolution_width', width);
    set('video', 'resolution_height', height);
  }

  /// Gets video FPS.
  int getVideoFps() => (get('video', 'fps', 30) as num).toInt();

  /// Gets video codec.
  String getVideoCodec() => get('video', 'codec', 'mp4v') as String;

  /// Gets camera index.
  int getCameraIndex() => (get('camera', 'index', 0) as num).toInt();

  /// Gets camera auto exposure setting.
  bool getCameraAutoExposure() =>
      get('camera', 'auto_exposure', true) as bool;

  /// Gets camera manual exposure value (-13 to -1).
  int getCameraExposure() => (get('camera', 'exposure', -4) as num).toInt();

  /// Gets camera gain value (0 to 255).
  int getCameraGain() => (get('camera', 'gain', 0) as num).toInt();

  /// Gets camera brightness value (0 to 255).
  int getCameraBrightness() =>
      (get('camera', 'brightness', 128) as num).toInt();

  /// Gets video storage path (normalized for OS, possibly relative).
  String getVideoStoragePath() {
    final path = get('storage', 'video_path', 'videos') as String?;
    return (path == null || path.isEmpty) ? 'videos' : p.normalize(path);
  }

  /// Gets database path (normalized for OS, possibly relative).
  String getDatabasePath() {
    final path = get('storage', 'database_path', 'database.db') as String?;
    return (path == null || path.isEmpty) ? 'database.db' : p.normalize(path);
  }

  /// Gets log path (normalized for OS, possibly relative).
  String getLogPath() {
    final path = get('storage', 'log_path', 'logs') as String?;
    return (path == null || path.isEmpty) ? 'logs' : p.normalize(path);
  }
}
