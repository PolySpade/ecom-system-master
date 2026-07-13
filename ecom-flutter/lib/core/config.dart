/// Config - thin projection of [SettingsManager] onto typed, path-resolved
/// getters.
///
/// Behavioral port of ecom-py/config.py: base dir resolves beside the
/// executable (matching PyInstaller frozen-exe behavior), relative storage
/// paths resolve against the base dir while absolute paths pass through
/// unchanged. All setting values are read live from the shared
/// [SettingsManager] (backed by settings.json, deep-merged over defaults),
/// so changes made through the Settings screen propagate to these getters
/// without a restart - the Dart equivalent of config.reload_config().
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings_manager.dart';

/// Exposes typed getters over the live [SettingsManager], resolving
/// relative storage paths against the executable's directory.
class Config {
  /// Wraps an existing [SettingsManager] with paths resolved against
  /// [baseDir]. Prefer [Config.load] in production; this constructor exists
  /// for tests.
  Config(this._baseDir, this.settingsManager);

  final String _baseDir;

  /// The live settings store backing this config. The Settings screen
  /// mutates and saves through this same instance, so getter values here
  /// update immediately after Save & Apply.
  final SettingsManager settingsManager;

  /// Base directory: the directory containing the running executable,
  /// matching ecom-py's `sys.frozen` "beside the executable" behavior.
  String get baseDir => _baseDir;

  /// Loads config from `settings.json` beside [Platform.resolvedExecutable],
  /// deep-merging over full defaults. Tolerates a missing/invalid file by
  /// falling back to defaults entirely (T-01-03 mitigation).
  static Config load() {
    final baseDir = p.dirname(Platform.resolvedExecutable);
    final settingsManager = SettingsManager(p.join(baseDir, 'settings.json'));
    return Config(baseDir, settingsManager);
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

  int get cameraIndex => settingsManager.getCameraIndex();

  String get videoStoragePath =>
      _resolvePath(settingsManager.getVideoStoragePath());

  String get databasePath => _resolvePath(settingsManager.getDatabasePath());

  String get logPath => _resolvePath(settingsManager.getLogPath());

  int get resolutionWidth => settingsManager.getVideoResolution().$1;

  int get resolutionHeight => settingsManager.getVideoResolution().$2;

  int get fps => settingsManager.getVideoFps();

  String get codec => settingsManager.getVideoCodec();
}
