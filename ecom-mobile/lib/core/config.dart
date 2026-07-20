/// Config - thin projection of [SettingsManager] onto typed, path-resolved
/// getters.
///
/// Mobile port of the desktop config: the base dir is the app's documents
/// directory (Android app-private storage) instead of "beside the exe" -
/// `Platform.resolvedExecutable` points into the read-only APK install on
/// Android. Relative storage paths resolve against the base dir while
/// absolute paths pass through unchanged. All setting values are read live
/// from the shared [SettingsManager] (backed by settings.json, deep-merged
/// over defaults), so changes made through the Settings screen propagate to
/// these getters without a restart.
library;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  /// Base directory: the app's documents directory (app-private storage).
  String get baseDir => _baseDir;

  /// Loads config from `settings.json` in the app documents directory,
  /// deep-merging over full defaults. Tolerates a missing/invalid file by
  /// falling back to defaults entirely (T-01-03 mitigation).
  static Future<Config> load() async {
    final dir = await getApplicationDocumentsDirectory();
    return loadFrom(dir.path);
  }

  /// Same as [load] but with an explicit base directory, so the
  /// settings.json merge behavior is unit-testable without depending on
  /// [Platform.resolvedExecutable].
  static Config loadFrom(String baseDir) {
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

  /// Free-space floor (GB) checked before each recording start (STO-02).
  /// ecom-py has no free-space guard, so this key is new to the port.
  double get minFreeSpaceGb =>
      (settingsManager.get('storage', 'min_free_space_gb', 1.0)! as num)
          .toDouble();

  int get resolutionWidth => settingsManager.getVideoResolution().$1;

  int get resolutionHeight => settingsManager.getVideoResolution().$2;

  int get fps => settingsManager.getVideoFps();

  String get codec => settingsManager.getVideoCodec();

  /// Recording bitrate cap in kbit/s (0 = camera default). New key for the
  /// port - caps the Media Foundation encoder so originals are small enough
  /// that post-compression is optional.
  int get recordingBitrateKbps =>
      (settingsManager.get('video', 'recording_bitrate_kbps', 6000)! as num)
          .toInt();

  /// Whether the timestamp/label/barcode watermark is burned into saved
  /// videos (REC-06). New key for the port; ecom-py always watermarks.
  bool get watermarkEnabled =>
      settingsManager.get('video', 'watermark_enabled', true)! as bool;

  // Compression settings (COMP-04/SET-06) - keys/defaults mirror
  // ecom-py/settings_manager.py's 'compression' category exactly.

  bool get compressionEnabled =>
      settingsManager.get('compression', 'enabled', true)! as bool;

  /// 'h264' or 'h265'.
  String get compressionCodec =>
      settingsManager.get('compression', 'codec', 'h264')! as String;

  /// Constant Rate Factor, 18-35 (lower = better quality).
  int get compressionCrf =>
      (settingsManager.get('compression', 'crf', 23)! as num).toInt();

  /// FFmpeg preset: ultrafast/fast/medium/slow.
  String get compressionPreset =>
      settingsManager.get('compression', 'preset', 'medium')! as String;

  /// Whether the original file is replaced by the compressed one.
  bool get compressionDeleteOriginal =>
      settingsManager.get('compression', 'delete_original', true)! as bool;

  /// FFmpeg process priority: 'low', 'below_normal', or 'normal'.
  String get compressionPriority =>
      settingsManager.get('compression', 'priority', 'below_normal')!
          as String;
}
