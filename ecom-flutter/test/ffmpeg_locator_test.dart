import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_flutter/core/ffmpeg_locator.dart';

void main() {
  group('FfmpegLocator', () {
    setUp(FfmpegLocator.resetCache);

    test('findFfmpeg returns null or an existing binary path', () async {
      final path = await FfmpegLocator.findFfmpeg();
      if (path != null) {
        expect(File(path).existsSync(), isTrue);
        expect(path.toLowerCase(), contains('ffmpeg'));
      }
    });

    test('findFfprobe returns null or an existing binary path', () async {
      final path = await FfmpegLocator.findFfprobe();
      if (path != null) {
        expect(File(path).existsSync(), isTrue);
        expect(path.toLowerCase(), contains('ffprobe'));
      }
    });

    test('results are cached across calls', () async {
      final first = await FfmpegLocator.findFfmpeg();
      final second = await FfmpegLocator.findFfmpeg();
      expect(second, first);
    });
  });
}
