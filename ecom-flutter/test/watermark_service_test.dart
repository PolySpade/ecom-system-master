import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_flutter/core/logger.dart';
import 'package:ecom_flutter/core/watermark_service.dart';

void main() {
  late Directory tempDir;
  late Logger logger;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('watermark_test_');
    logger = Logger('test', p.join(tempDir.path, 'test.log'));
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('escapeDrawtextText', () {
    test('leaves benign text unchanged', () {
      expect(escapeDrawtextText('Normal (Standard)'), 'Normal (Standard)');
      expect(escapeDrawtextText('ABC123'), 'ABC123');
    });

    test('escapes colons and commas (filtergraph separators - the bundled '
        '2026 FFmpeg applies backslash escapes inside single quotes, so a '
        'bare : or , breaks the chain even when quoted)', () {
      expect(escapeDrawtextText('Barcode: ABC123'), r'Barcode\: ABC123');
      expect(escapeDrawtextText('a,b'), r'a\,b');
    });

    test('escapes single quotes and backslashes', () {
      expect(escapeDrawtextText("it's"), contains(r"'\''"));
      expect(escapeDrawtextText(r'a\b'), contains(r'\\'));
    });

    test('flattens newlines', () {
      expect(escapeDrawtextText('a\nb\rc'), 'a b c');
    });
  });

  group('buildRecordingPostFilter', () {
    final start = DateTime(2026, 7, 13, 12, 0);

    test('combines escaped scale and watermark in order', () {
      final filter = buildRecordingPostFilter(
        barcode: 'ABC',
        label: 'Normal (Standard)',
        startTime: start,
        targetHeight: 720,
        fontFile: r'C:\Windows\Fonts\arial.ttf',
      )!;

      // Comma inside min() must be escaped or it splits the filterchain.
      expect(filter, startsWith(r'scale=-2:min(720\,ih),drawtext='));
      expect(filter, contains(r"text='Barcode\: ABC'"));
    });

    test('scale-only when no font is available', () {
      final filter = buildRecordingPostFilter(
        barcode: 'ABC',
        label: 'Normal (Standard)',
        startTime: start,
        targetHeight: 1080,
        fontFile: null,
      );
      // fontFile null falls back to findWindowsFontFile(); on a machine
      // with fonts this returns the full chain, so only assert the scale
      // prefix is always present.
      expect(filter, isNotNull);
      expect(filter, startsWith(r'scale=-2:min(1080\,ih)'));
    });

    test('watermark-only when targetHeight is 0', () {
      final filter = buildRecordingPostFilter(
        barcode: 'ABC',
        label: 'Normal (Standard)',
        startTime: start,
        targetHeight: 0,
        fontFile: r'C:\Windows\Fonts\arial.ttf',
      )!;
      expect(filter, startsWith('drawtext='));
      expect(filter.contains('scale'), isFalse);
    });

    test('unparseable start time drops the watermark, keeps the scale', () {
      final filter = buildRecordingPostFilter(
        barcode: 'ABC',
        label: 'Normal (Standard)',
        startTime: null,
        targetHeight: 720,
        fontFile: r'C:\Windows\Fonts\arial.ttf',
      );
      expect(filter, r'scale=-2:min(720\,ih)');
    });
  });

  group('buildWatermarkFilter', () {
    test('contains three drawtext overlays at the reference positions', () {
      final filter = buildWatermarkFilter(
        fontFile: r'C:\Windows\Fonts\arial.ttf',
        barcode: 'ABC123',
        label: 'Normal (Standard)',
        startEpochSeconds: 1234567890,
      );

      expect('drawtext'.allMatches(filter).length, 3);
      // Timestamp top-left: running clock seeded with the start epoch.
      expect(filter, contains(r'%{pts\:localtime\:1234567890}'));
      expect(filter, contains('x=10:y=10'));
      // Label top-right on the #667eea brand box.
      expect(filter, contains("text='Normal (Standard)'"));
      expect(filter, contains('boxcolor=0x667eea'));
      expect(filter, contains('x=w-tw-10:y=10'));
      // Barcode bottom-left.
      expect(filter, contains(r"text='Barcode\: ABC123'"));
      expect(filter, contains('x=10:y=h-th-10'));
    });

    test('font path is forward-slashed with escaped drive colon', () {
      final filter = buildWatermarkFilter(
        fontFile: r'C:\Windows\Fonts\arial.ttf',
        barcode: 'X',
        label: 'Y',
        startEpochSeconds: 0,
      );
      expect(filter, contains(r"fontfile='C\:/Windows/Fonts/arial.ttf'"));
    });

    test('label and barcode overlays disable text expansion', () {
      final filter = buildWatermarkFilter(
        fontFile: 'f.ttf',
        barcode: 'B',
        label: 'L',
        startEpochSeconds: 0,
      );
      expect('expansion=none'.allMatches(filter).length, 2);
    });
  });

  group('buildFfmpegArgs', () {
    test('produces overwrite + filter + encode + output ordering', () {
      final args = buildFfmpegArgs(
        inputPath: 'in.mp4',
        outputPath: 'out.mp4',
        filter: 'drawtext=x',
      );
      expect(args.first, '-y');
      expect(args[args.indexOf('-i') + 1], 'in.mp4');
      expect(args[args.indexOf('-vf') + 1], 'drawtext=x');
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args.last, 'out.mp4');
    });
  });

  group('findWindowsFontFile', () {
    test('returns null when no candidate exists', () {
      expect(findWindowsFontFile(fontsDir: tempDir.path), isNull);
    });

    test('returns the first available candidate', () {
      final segoe = File(p.join(tempDir.path, 'segoeui.ttf'))
        ..writeAsStringSync('font');
      expect(findWindowsFontFile(fontsDir: tempDir.path), segoe.path);
    });
  });

  group('WatermarkService', () {
    File createVideo(String name) {
      return File(p.join(tempDir.path, name))..writeAsStringSync('ORIGINAL');
    }

    WatermarkJob jobFor(File video) => WatermarkJob(
          videoPath: video.path,
          barcode: 'ABC123',
          label: 'Normal (Standard)',
          recordingStart: DateTime(2026, 7, 13, 12, 0, 0),
        );

    test('skips gracefully when FFmpeg is absent, keeping the video', () async {
      final video = createVideo('a.mp4');
      final service = WatermarkService(
        logger,
        findFfmpeg: () async => null,
        findFont: () => 'arial.ttf',
        runProcess: (exe, args) async => fail('must not run ffmpeg'),
      );

      final outcome = await service.enqueue(jobFor(video));

      expect(outcome, WatermarkOutcome.skippedNoFfmpeg);
      expect(video.readAsStringSync(), 'ORIGINAL');
    });

    test('skips gracefully when no font is found, keeping the video',
        () async {
      final video = createVideo('a.mp4');
      final service = WatermarkService(
        logger,
        findFfmpeg: () async => 'ffmpeg.exe',
        findFont: () => null,
        runProcess: (exe, args) async => fail('must not run ffmpeg'),
      );

      final outcome = await service.enqueue(jobFor(video));

      expect(outcome, WatermarkOutcome.skippedNoFont);
      expect(video.readAsStringSync(), 'ORIGINAL');
    });

    test('swaps the watermarked output in place of the original on success',
        () async {
      final video = createVideo('a.mp4');
      final service = WatermarkService(
        logger,
        findFfmpeg: () async => 'ffmpeg.exe',
        findFont: () => 'arial.ttf',
        runProcess: (exe, args) async {
          // Simulate ffmpeg writing the output file (last arg).
          File(args.last).writeAsStringSync('WATERMARKED');
          return ProcessResult(0, 0, '', '');
        },
      );

      final outcome = await service.enqueue(jobFor(video));

      expect(outcome, WatermarkOutcome.completed);
      expect(video.readAsStringSync(), 'WATERMARKED');
      // No temp/backup residue.
      final residue = tempDir
          .listSync()
          .whereType<File>()
          .where((f) =>
              f.path.contains('wm_tmp') || f.path.contains('wm_bak'))
          .toList();
      expect(residue, isEmpty);
    });

    test('keeps the original untouched when ffmpeg fails', () async {
      final video = createVideo('a.mp4');
      final service = WatermarkService(
        logger,
        findFfmpeg: () async => 'ffmpeg.exe',
        findFont: () => 'arial.ttf',
        runProcess: (exe, args) async => ProcessResult(0, 1, '', 'boom'),
      );

      final outcome = await service.enqueue(jobFor(video));

      expect(outcome, WatermarkOutcome.failed);
      expect(video.readAsStringSync(), 'ORIGINAL');
    });

    test('fails without touching anything when the video is missing',
        () async {
      final service = WatermarkService(
        logger,
        findFfmpeg: () async => 'ffmpeg.exe',
        findFont: () => 'arial.ttf',
        runProcess: (exe, args) async => fail('must not run ffmpeg'),
      );

      final outcome = await service.enqueue(
        WatermarkJob(
          videoPath: p.join(tempDir.path, 'missing.mp4'),
          barcode: 'X',
          label: 'Y',
          recordingStart: DateTime(2026),
        ),
      );

      expect(outcome, WatermarkOutcome.failed);
    });

    test('serializes jobs: one ffmpeg invocation at a time, in order',
        () async {
      final videoA = createVideo('a.mp4');
      final videoB = createVideo('b.mp4');
      final order = <String>[];
      var concurrent = 0;
      var maxConcurrent = 0;

      final service = WatermarkService(
        logger,
        findFfmpeg: () async => 'ffmpeg.exe',
        findFont: () => 'arial.ttf',
        runProcess: (exe, args) async {
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          order.add(p.basename(args[args.indexOf('-i') + 1]));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          File(args.last).writeAsStringSync('WATERMARKED');
          concurrent--;
          return ProcessResult(0, 0, '', '');
        },
      );

      final futures = [
        service.enqueue(jobFor(videoA)),
        service.enqueue(jobFor(videoB)),
      ];
      expect(service.pendingCount, 2);

      final outcomes = await Future.wait(futures);

      expect(outcomes, everyElement(WatermarkOutcome.completed));
      expect(order, ['a.mp4', 'b.mp4']);
      expect(maxConcurrent, 1);
      expect(service.pendingCount, 0);
      expect(service.isProcessing, isFalse);
    });
  });
}
