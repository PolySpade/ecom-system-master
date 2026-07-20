import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_mobile/core/config.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('compression defaults mirror ecom-py settings_manager.py', () {
    final config = Config.loadFrom(tempDir.path);

    expect(config.compressionEnabled, isTrue);
    expect(config.compressionCodec, 'h264');
    expect(config.compressionCrf, 23);
    expect(config.compressionPreset, 'medium');
    expect(config.compressionDeleteOriginal, isTrue);
    expect(config.compressionPriority, 'below_normal');
  });

  test('settings.json compression keys deep-merge over defaults', () {
    File(p.join(tempDir.path, 'settings.json')).writeAsStringSync('''
      {
        "compression": {
          "codec": "h265",
          "crf": 28,
          "delete_original": false
        }
      }
    ''');

    final config = Config.loadFrom(tempDir.path);

    // Overridden keys.
    expect(config.compressionCodec, 'h265');
    expect(config.compressionCrf, 28);
    expect(config.compressionDeleteOriginal, isFalse);
    // Untouched keys keep their defaults.
    expect(config.compressionEnabled, isTrue);
    expect(config.compressionPreset, 'medium');
    expect(config.compressionPriority, 'below_normal');
  });

  test('malformed settings.json falls back to defaults', () {
    File(p.join(tempDir.path, 'settings.json'))
        .writeAsStringSync('{not valid json');

    final config = Config.loadFrom(tempDir.path);

    expect(config.compressionEnabled, isTrue);
    expect(config.compressionCrf, 23);
  });

  test('loadFrom resolves relative storage paths against baseDir', () {
    final config = Config.loadFrom(tempDir.path);

    // video_path defaults to the absolute Movies collection path; the
    // relative database/log defaults resolve against baseDir.
    expect(
      config.databasePath,
      p.normalize(p.join(tempDir.path, 'database.db')),
    );
    expect(config.logPath, p.normalize(p.join(tempDir.path, 'logs')));
  });
}
