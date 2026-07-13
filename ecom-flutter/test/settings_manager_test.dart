import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_flutter/core/config.dart';
import 'package:ecom_flutter/core/settings_manager.dart';

void main() {
  late Directory tempDir;
  late String settingsPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('settings_manager_test_');
    settingsPath = p.join(tempDir.path, 'settings.json');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('loading', () {
    test('missing file falls back to full defaults', () {
      final sm = SettingsManager(settingsPath);

      expect(sm.getVideoResolution(), (1280, 720));
      expect(sm.getVideoFps(), 30);
      expect(sm.getVideoCodec(), 'mp4v');
      expect(sm.getCameraIndex(), 0);
      expect(sm.getCameraAutoExposure(), isTrue);
      expect(sm.getCameraExposure(), -4);
      expect(sm.getCameraGain(), 0);
      expect(sm.getCameraBrightness(), 128);
      expect(sm.getVideoStoragePath(), 'videos');
      expect(sm.getDatabasePath(), 'database.db');
      expect(sm.getLogPath(), 'logs');
      // Compression category present for ecom-py settings.json parity.
      expect(sm.get('compression', 'enabled'), isTrue);
      expect(sm.get('compression', 'codec'), 'h264');
      expect(sm.get('compression', 'crf'), 23);
    });

    test('partial file deep-merges over defaults (untouched keys survive)',
        () {
      File(settingsPath).writeAsStringSync(jsonEncode({
        'video': {'fps': 60},
        'camera': {'index': 2},
      }));
      final sm = SettingsManager(settingsPath);

      expect(sm.getVideoFps(), 60);
      expect(sm.getCameraIndex(), 2);
      // Sibling keys within the overridden categories keep their defaults.
      expect(sm.getVideoResolution(), (1280, 720));
      expect(sm.getCameraBrightness(), 128);
      // Untouched categories keep full defaults.
      expect(sm.getVideoStoragePath(), 'videos');
      expect(sm.get('compression', 'preset'), 'medium');
    });

    test('malformed JSON falls back to defaults without throwing', () {
      File(settingsPath).writeAsStringSync('{not valid json!');
      final sm = SettingsManager(settingsPath);
      expect(sm.getVideoFps(), 30);
    });

    test('non-object JSON falls back to defaults without throwing', () {
      File(settingsPath).writeAsStringSync('[1, 2, 3]');
      final sm = SettingsManager(settingsPath);
      expect(sm.getCameraIndex(), 0);
    });

    test('unknown extra keys in file are preserved (not stripped)', () {
      File(settingsPath).writeAsStringSync(jsonEncode({
        'custom_category': {'foo': 'bar'},
      }));
      final sm = SettingsManager(settingsPath);
      expect(sm.get('custom_category', 'foo'), 'bar');
    });
  });

  group('deepMerge', () {
    test('recursively merges nested maps and overwrites scalars', () {
      final base = <String, dynamic>{
        'a': {'x': 1, 'y': 2},
        'b': 'keep',
      };
      SettingsManager.deepMerge(base, {
        'a': {'y': 99, 'z': 3},
        'c': true,
      });

      expect(base['a'], {'x': 1, 'y': 99, 'z': 3});
      expect(base['b'], 'keep');
      expect(base['c'], isTrue);
    });

    test('scalar in updates replaces a map in base', () {
      final base = <String, dynamic>{
        'a': {'x': 1},
      };
      SettingsManager.deepMerge(base, {'a': 5});
      expect(base['a'], 5);
    });
  });

  group('persistence', () {
    test('saveSettings round-trips values through disk', () {
      final sm = SettingsManager(settingsPath);
      sm.setVideoResolution(1920, 1080);
      sm.set('video', 'fps', 60);
      sm.set('camera', 'index', 1);
      expect(sm.saveSettings(), isTrue);

      final reloaded = SettingsManager(settingsPath);
      expect(reloaded.getVideoResolution(), (1920, 1080));
      expect(reloaded.getVideoFps(), 60);
      expect(reloaded.getCameraIndex(), 1);
    });

    test('saved file is human-editable indented JSON with all categories',
        () {
      final sm = SettingsManager(settingsPath);
      expect(sm.saveSettings(), isTrue);

      final raw = File(settingsPath).readAsStringSync();
      // Indented (multi-line), not a single-line blob.
      expect(raw.split('\n').length, greaterThan(5));

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(
        decoded.keys.toSet(),
        {'video', 'camera', 'storage', 'app', 'compression'},
      );
    });

    test('saveSettings returns false when the path is unwritable', () {
      // A directory at the settings path makes the file write fail.
      final dirAsFile = p.join(tempDir.path, 'blocked');
      Directory(dirAsFile).createSync();
      final sm = SettingsManager(dirAsFile);
      expect(sm.saveSettings(), isFalse);
    });
  });

  group('mutation', () {
    test('updateCategory merges over existing category keys', () {
      final sm = SettingsManager(settingsPath);
      sm.updateCategory('video', {'fps': 24, 'codec': 'avc1'});

      expect(sm.getVideoFps(), 24);
      expect(sm.getVideoCodec(), 'avc1');
      // Keys not in the update survive.
      expect(sm.getVideoResolution(), (1280, 720));
    });

    test('resetToDefaults restores defaults in memory', () {
      final sm = SettingsManager(settingsPath);
      sm.set('video', 'fps', 60);
      sm.resetToDefaults();
      expect(sm.getVideoFps(), 30);
    });

    test('getAll returns a copy - mutating it does not affect settings', () {
      final sm = SettingsManager(settingsPath);
      final all = sm.getAll();
      (all['video'] as Map)['fps'] = 999;
      expect(sm.getVideoFps(), 30);
    });

    test('mutating defaults copy never leaks across instances', () {
      final sm1 = SettingsManager(settingsPath);
      sm1.set('video', 'fps', 60);
      final sm2 = SettingsManager(p.join(tempDir.path, 'other.json'));
      expect(sm2.getVideoFps(), 30);
    });
  });

  group('Config delegation', () {
    test('resolves relative storage paths against baseDir', () {
      final sm = SettingsManager(settingsPath);
      final config = Config(tempDir.path, sm);

      expect(config.videoStoragePath, p.join(tempDir.path, 'videos'));
      expect(config.databasePath, p.join(tempDir.path, 'database.db'));
      expect(config.logPath, p.join(tempDir.path, 'logs'));
    });

    test('absolute storage paths pass through unchanged', () {
      final absolute = p.join(tempDir.path, 'elsewhere', 'vids');
      File(settingsPath).writeAsStringSync(jsonEncode({
        'storage': {'video_path': absolute},
      }));
      final sm = SettingsManager(settingsPath);
      final config = Config(tempDir.path, sm);

      expect(config.videoStoragePath, p.normalize(absolute));
    });

    test('reads live values - settings changes propagate without reload',
        () {
      final sm = SettingsManager(settingsPath);
      final config = Config(tempDir.path, sm);

      expect(config.fps, 30);
      sm.updateCategory('video', {'fps': 60});
      expect(config.fps, 60);
      expect(config.cameraIndex, 0);
      sm.set('camera', 'index', 3);
      expect(config.cameraIndex, 3);
    });
  });
}
