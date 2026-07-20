import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_mobile/core/ffmpeg_locator.dart';

void main() {
  late Directory tempDir;

  String exeName(String name) => Platform.isWindows ? '$name.exe' : name;

  File placeExe(String dir, String name) {
    final file = File(p.join(dir, exeName(name)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('fake $name binary');
    return file;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ffmpeg_locator_test_');
    FfmpegLocator.resetCache();
    // Isolate from the real machine: empty base dir, no common paths,
    // empty PATH.
    FfmpegLocator.debugBaseDirOverride = p.join(tempDir.path, 'app');
    Directory(FfmpegLocator.debugBaseDirOverride!).createSync(recursive: true);
    FfmpegLocator.debugCommonPathsOverride = [];
    FfmpegLocator.debugEnvironmentOverride = {'PATH': ''};
  });

  tearDown(() {
    FfmpegLocator.debugBaseDirOverride = null;
    FfmpegLocator.debugCommonPathsOverride = null;
    FfmpegLocator.debugEnvironmentOverride = null;
    FfmpegLocator.resetCache();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('returns null when ffmpeg exists nowhere', () async {
    expect(await FfmpegLocator.findFfmpeg(), isNull);
    expect(await FfmpegLocator.findFfprobe(), isNull);
  });

  test('finds ffmpeg in ffmpeg/bin/ beside the executable', () async {
    final baseDir = FfmpegLocator.debugBaseDirOverride!;
    final file = placeExe(p.join(baseDir, 'ffmpeg', 'bin'), 'ffmpeg');

    expect(await FfmpegLocator.findFfmpeg(), p.normalize(file.path));
  });

  test('finds ffmpeg directly beside the executable', () async {
    final baseDir = FfmpegLocator.debugBaseDirOverride!;
    final file = placeExe(baseDir, 'ffmpeg');

    expect(await FfmpegLocator.findFfmpeg(), p.normalize(file.path));
  });

  test('finds ffmpeg in a common install path', () async {
    final commonDir = p.join(tempDir.path, 'common');
    final file = placeExe(commonDir, 'ffmpeg');
    FfmpegLocator.debugCommonPathsOverride = [commonDir];

    expect(await FfmpegLocator.findFfmpeg(), p.normalize(file.path));
  });

  test('falls back to PATH directories', () async {
    final pathDir = p.join(tempDir.path, 'onpath');
    final file = placeExe(pathDir, 'ffmpeg');
    FfmpegLocator.debugEnvironmentOverride = {'PATH': pathDir};

    expect(await FfmpegLocator.findFfmpeg(), p.normalize(file.path));
  });

  test('bundled dir wins over common paths and PATH', () async {
    final baseDir = FfmpegLocator.debugBaseDirOverride!;
    final bundled = placeExe(p.join(baseDir, 'ffmpeg', 'bin'), 'ffmpeg');
    final commonDir = p.join(tempDir.path, 'common');
    placeExe(commonDir, 'ffmpeg');
    final pathDir = p.join(tempDir.path, 'onpath');
    placeExe(pathDir, 'ffmpeg');
    FfmpegLocator.debugCommonPathsOverride = [commonDir];
    FfmpegLocator.debugEnvironmentOverride = {'PATH': pathDir};

    expect(await FfmpegLocator.findFfmpeg(), p.normalize(bundled.path));
  });

  test('common path wins over PATH', () async {
    final commonDir = p.join(tempDir.path, 'common');
    final common = placeExe(commonDir, 'ffmpeg');
    final pathDir = p.join(tempDir.path, 'onpath');
    placeExe(pathDir, 'ffmpeg');
    FfmpegLocator.debugCommonPathsOverride = [commonDir];
    FfmpegLocator.debugEnvironmentOverride = {'PATH': pathDir};

    expect(await FfmpegLocator.findFfmpeg(), p.normalize(common.path));
  });

  test('ffmpeg and ffprobe are located independently', () async {
    final baseDir = FfmpegLocator.debugBaseDirOverride!;
    final probe = placeExe(p.join(baseDir, 'ffmpeg', 'bin'), 'ffprobe');

    expect(await FfmpegLocator.findFfmpeg(), isNull);
    expect(await FfmpegLocator.findFfprobe(), p.normalize(probe.path));
  });

  test('result is cached until resetCache()', () async {
    final baseDir = FfmpegLocator.debugBaseDirOverride!;
    final file = placeExe(p.join(baseDir, 'ffmpeg', 'bin'), 'ffmpeg');
    expect(await FfmpegLocator.findFfmpeg(), p.normalize(file.path));

    file.deleteSync();
    // Cached hit survives the file's deletion...
    expect(await FfmpegLocator.findFfmpeg(), p.normalize(file.path));

    // ...until the cache is reset.
    FfmpegLocator.resetCache();
    expect(await FfmpegLocator.findFfmpeg(), isNull);
  });
}
