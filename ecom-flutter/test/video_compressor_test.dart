import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_flutter/core/logger.dart';
import 'package:ecom_flutter/core/video_compressor.dart';

/// Minimal fake of dart:io Process: exit code controlled by the test,
/// empty output streams, kill completes the exit code.
class FakeProcess implements Process {
  FakeProcess(this.pid, this.arguments);

  @override
  final int pid;

  /// The arguments this process was started with (last one is the output
  /// path).
  final List<String> arguments;

  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  String get outputPath => arguments.last;

  void completeWith(int code) {
    if (!_exit.isCompleted) {
      _exit.complete(code);
    }
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) {
      _exit.complete(-9);
    }
    return true;
  }

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnsupportedError('FakeProcess has no stdin');
}

/// One recorded onComplete invocation.
class CallbackRecord {
  CallbackRecord(this.transactionId, this.success, this.data);

  final int transactionId;
  final bool success;
  final Map<String, Object?> data;
}

Future<void> waitUntil(
  bool Function() condition, {
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory tempDir;
  late Logger logger;
  late String logFilePath;
  late List<FakeProcess> processes;
  late List<(String, List<String>)> startedCommands;
  late List<(int, String)> appliedPriorities;
  late List<CallbackRecord> callbacks;

  Future<Process> fakeStarter(String executable, List<String> args) async {
    startedCommands.add((executable, args));
    final process = FakeProcess(1000 + processes.length, args);
    processes.add(process);
    return process;
  }

  bool fakePriorityApplier(int processPid, String priority) {
    appliedPriorities.add((processPid, priority));
    return true;
  }

  void onComplete(int transactionId, bool success, Map<String, Object?> data) {
    callbacks.add(CallbackRecord(transactionId, success, data));
  }

  VideoCompressor buildCompressor({
    FfmpegFinder? ffmpegFinder,
    SourceBitrateProber? bitrateProber,
    Duration jobTimeout = const Duration(hours: 1),
  }) {
    return VideoCompressor(
      logger,
      onComplete: onComplete,
      processStarter: fakeStarter,
      ffmpegFinder: ffmpegFinder ?? () async => p.join(tempDir.path, 'ffmpeg'),
      priorityApplier: fakePriorityApplier,
      bitrateProber: bitrateProber ?? (_) async => null,
      jobTimeout: jobTimeout,
    );
  }

  File createInput(String name, {int sizeBytes = 1000}) {
    final file = File(p.join(tempDir.path, name));
    file.writeAsBytesSync(List<int>.filled(sizeBytes, 0x41));
    return file;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('video_compressor_test_');
    logFilePath = p.join(tempDir.path, 'logs', 'app.log');
    logger = Logger('test', logFilePath);
    processes = [];
    startedCommands = [];
    appliedPriorities = [];
    callbacks = [];
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('graceful skip (COMP-02)', () {
    test('disabled compression skips without spawning a process', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor();
      compressor.start();

      final queued = await compressor.queueCompression(
        input.path,
        7,
        const CompressionSettings(enabled: false),
      );

      expect(queued, isFalse);
      expect(startedCommands, isEmpty);
      expect(callbacks, hasLength(1));
      expect(callbacks.first.transactionId, 7);
      expect(callbacks.first.success, isTrue);
      expect(callbacks.first.data['status'], 'skipped');
      expect(callbacks.first.data['message'], 'Compression disabled');
      await compressor.stop();
    });

    test('missing FFmpeg skips gracefully with a logged warning', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor(ffmpegFinder: () async => null);
      compressor.start();

      final queued = await compressor.queueCompression(
        input.path,
        8,
        const CompressionSettings(),
      );

      expect(queued, isFalse);
      expect(startedCommands, isEmpty);
      expect(callbacks, hasLength(1));
      expect(callbacks.first.success, isFalse);
      expect(callbacks.first.data['status'], 'skipped');
      expect(callbacks.first.data['message'], 'FFmpeg not installed');
      // The warning is logged (visible-warning requirement).
      final log = File(logFilePath).readAsStringSync();
      expect(log, contains('WARNING'));
      expect(log, contains('FFmpeg not available, skipping compression'));
      // The original recording is untouched.
      expect(input.existsSync(), isTrue);
      await compressor.stop();
    });

    test('missing input file reports failed', () async {
      final compressor = buildCompressor();
      compressor.start();

      final queued = await compressor.queueCompression(
        p.join(tempDir.path, 'does_not_exist.mp4'),
        9,
        const CompressionSettings(),
      );

      expect(queued, isFalse);
      expect(startedCommands, isEmpty);
      expect(callbacks.first.data['status'], 'failed');
      expect(callbacks.first.data['message'], 'Video file not found');
      await compressor.stop();
    });
  });

  group('FFmpeg command construction (COMP-04)', () {
    test('h264 defaults produce the ecom-py argument list', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(input.path, 1, const CompressionSettings());
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      final (executable, args) = startedCommands.single;
      expect(executable, p.join(tempDir.path, 'ffmpeg'));
      final expectedOutput = p.join(tempDir.path, 'video_compressed.mp4');
      expect(args, [
        '-i', input.path,
        '-c:v', 'libx264',
        '-crf', '23',
        '-preset', 'medium',
        '-threads', '2',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-y',
        expectedOutput,
      ]);

      processes.single.completeWith(1); // fail fast to end the job
      await compressor.stop();
    });

    test('h265 maps to libx265 and CRF clamps into 18-35', () async {
      final inputHigh = createInput('high.mp4');
      final inputLow = createInput('low.mp4');
      final compressor = buildCompressor();
      compressor.start();

      await compressor.queueCompression(
        inputHigh.path,
        1,
        const CompressionSettings(codec: 'h265', crf: 99, preset: 'fast'),
      );
      await waitUntil(() => processes.length == 1, reason: 'first process');
      processes[0].completeWith(1);

      await compressor.queueCompression(
        inputLow.path,
        2,
        const CompressionSettings(crf: 1),
      );
      await waitUntil(() => processes.length == 2, reason: 'second process');
      processes[1].completeWith(1);

      final firstArgs = startedCommands[0].$2;
      expect(firstArgs[firstArgs.indexOf('-c:v') + 1], 'libx265');
      expect(firstArgs[firstArgs.indexOf('-crf') + 1], '35');
      expect(firstArgs[firstArgs.indexOf('-preset') + 1], 'fast');

      final secondArgs = startedCommands[1].$2;
      expect(secondArgs[secondArgs.indexOf('-crf') + 1], '18');

      await compressor.stop();
    });

    test('configured priority is applied to the spawned pid', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(
        input.path,
        1,
        const CompressionSettings(priority: 'low'),
      );
      await waitUntil(() => appliedPriorities.isNotEmpty, reason: 'priority');

      expect(appliedPriorities.single.$1, processes.single.pid);
      expect(appliedPriorities.single.$2, 'low');

      processes.single.completeWith(1);
      await compressor.stop();
    });
  });

  group('watermark single-pass (-vf)', () {
    test('videoFilter is injected before the codec args', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(
        input.path,
        5,
        const CompressionSettings(),
        videoFilter: 'drawtext=x=1',
      );
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      final (_, args) = startedCommands.single;
      final vf = args.indexOf('-vf');
      expect(vf, greaterThan(-1));
      expect(args[vf + 1], 'drawtext=x=1');
      expect(vf, lessThan(args.indexOf('-c:v')));

      processes.single.completeWith(1); // fail fast to end the job
      await compressor.stop();
    });

    test('a filtered job runs even when compression is disabled '
        '(the watermark requires the encode regardless)', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor();
      compressor.start();

      final queued = await compressor.queueCompression(
        input.path,
        6,
        const CompressionSettings(enabled: false),
        videoFilter: 'drawtext=x=1',
      );

      expect(queued, isTrue);
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');
      expect(startedCommands, hasLength(1));

      processes.single.completeWith(1);
      await compressor.stop();
    });
  });

  group('atomic replacement (COMP-03)', () {
    test('deleteOriginal=true swaps compressed file into place', () async {
      final input = createInput('video.mp4', sizeBytes: 1000);
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(input.path, 42, const CompressionSettings());
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      // Simulate FFmpeg writing a smaller output, then exiting cleanly.
      final process = processes.single;
      File(process.outputPath).writeAsBytesSync(List<int>.filled(400, 0x42));
      process.completeWith(0);
      await waitUntil(() => callbacks.isNotEmpty, reason: 'completion');

      final record = callbacks.single;
      expect(record.transactionId, 42);
      expect(record.success, isTrue);
      expect(record.data['status'], 'completed');
      expect(record.data['compressed_filename'], 'video.mp4');
      expect((record.data['compression_ratio'] as double), closeTo(60.0, 0.01));
      expect(
        (record.data['compressed_file_size_mb'] as double),
        closeTo(400 / (1024 * 1024), 1e-9),
      );

      // The original path now holds the compressed content; no temp/bak
      // files remain.
      expect(input.readAsBytesSync().length, 400);
      expect(File(process.outputPath).existsSync(), isFalse);
      expect(File('${input.path}.bak').existsSync(), isFalse);

      await compressor.stop();
    });

    test('deleteOriginal=false keeps both files (ecom-py parity)', () async {
      final input = createInput('video.mp4', sizeBytes: 1000);
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(
        input.path,
        43,
        const CompressionSettings(deleteOriginal: false),
      );
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      final process = processes.single;
      File(process.outputPath).writeAsBytesSync(List<int>.filled(400, 0x42));
      process.completeWith(0);
      await waitUntil(() => callbacks.isNotEmpty, reason: 'completion');

      expect(callbacks.single.data['status'], 'completed');
      expect(
        callbacks.single.data['compressed_filename'],
        'video_compressed.mp4',
      );
      // Original untouched, compressed file kept beside it.
      expect(input.readAsBytesSync().length, 1000);
      expect(File(process.outputPath).existsSync(), isTrue);

      await compressor.stop();
    });

    test('nonzero exit leaves the original untouched and cleans the temp',
        () async {
      final input = createInput('video.mp4', sizeBytes: 1000);
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(input.path, 44, const CompressionSettings());
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      final process = processes.single;
      // FFmpeg wrote a partial file, then failed.
      File(process.outputPath).writeAsBytesSync(List<int>.filled(50, 0x42));
      process.completeWith(1);
      await waitUntil(() => callbacks.isNotEmpty, reason: 'completion');

      expect(callbacks.single.success, isFalse);
      expect(callbacks.single.data['status'], 'failed');
      expect('${callbacks.single.data['message']}', contains('return code 1'));
      expect(input.readAsBytesSync().length, 1000);
      expect(File(process.outputPath).existsSync(), isFalse);

      await compressor.stop();
    });

    test('exit 0 with an empty output reports failed, original untouched',
        () async {
      final input = createInput('video.mp4', sizeBytes: 1000);
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(input.path, 45, const CompressionSettings());
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      final process = processes.single;
      File(process.outputPath).writeAsBytesSync(const <int>[]);
      process.completeWith(0);
      await waitUntil(() => callbacks.isNotEmpty, reason: 'completion');

      expect(callbacks.single.data['status'], 'failed');
      expect(input.readAsBytesSync().length, 1000);

      await compressor.stop();
    });
  });

  group('serialized worker (COMP-01)', () {
    test('jobs run strictly one at a time, FIFO', () async {
      final inputA = createInput('a.mp4');
      final inputB = createInput('b.mp4');
      final compressor = buildCompressor();
      compressor.start();

      await compressor.queueCompression(inputA.path, 1, const CompressionSettings());
      await compressor.queueCompression(inputB.path, 2, const CompressionSettings());
      await waitUntil(() => processes.length == 1, reason: 'first process');

      // Give the pump every chance to (incorrectly) start job B early.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(processes, hasLength(1));
      expect(startedCommands.single.$2[1], inputA.path);
      expect(compressor.queueStatus.value.isProcessing, isTrue);
      expect(compressor.queueStatus.value.currentTransactionId, 1);
      expect(compressor.queueStatus.value.queueSize, 1);

      // Finish A; B must start only now.
      File(processes[0].outputPath).writeAsBytesSync(List<int>.filled(10, 1));
      processes[0].completeWith(0);
      await waitUntil(() => processes.length == 2, reason: 'second process');
      expect(startedCommands[1].$2[1], inputB.path);

      File(processes[1].outputPath).writeAsBytesSync(List<int>.filled(10, 1));
      processes[1].completeWith(0);
      await waitUntil(() => callbacks.length == 2, reason: 'both callbacks');

      expect(callbacks[0].transactionId, 1);
      expect(callbacks[1].transactionId, 2);
      expect(compressor.queueStatus.value.isProcessing, isFalse);
      expect(compressor.queueStatus.value.queueSize, 0);
      expect(compressor.queueLength, 0);

      await compressor.stop();
    });

    test('jobs queued before start() wait until the worker starts', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor();

      await compressor.queueCompression(input.path, 1, const CompressionSettings());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(processes, isEmpty);
      expect(compressor.queueStatus.value.workerRunning, isFalse);
      expect(compressor.queueStatus.value.queueSize, 1);

      compressor.start();
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');
      expect(compressor.queueStatus.value.workerRunning, isTrue);

      processes.single.completeWith(1);
      await compressor.stop();
    });

    test('stop() waits for the in-flight job to finish', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(input.path, 1, const CompressionSettings());
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      var stopped = false;
      final stopFuture = compressor.stop().then((_) => stopped = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(stopped, isFalse); // job still in flight

      File(processes.single.outputPath)
          .writeAsBytesSync(List<int>.filled(10, 1));
      processes.single.completeWith(0);
      await stopFuture;
      expect(stopped, isTrue);
      expect(callbacks, hasLength(1));
    });
  });

  group('timeout (COMP-04)', () {
    test('a hung FFmpeg process is killed and reported failed', () async {
      final input = createInput('video.mp4', sizeBytes: 1000);
      final compressor =
          buildCompressor(jobTimeout: const Duration(milliseconds: 100));
      compressor.start();
      await compressor.queueCompression(input.path, 1, const CompressionSettings());
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      // Never complete the process - let the timeout fire.
      await waitUntil(() => callbacks.isNotEmpty, reason: 'timeout callback');

      expect(processes.single.killed, isTrue);
      expect(callbacks.single.success, isFalse);
      expect(callbacks.single.data['status'], 'failed');
      expect('${callbacks.single.data['message']}', contains('timed out'));
      // The original is untouched.
      expect(input.readAsBytesSync().length, 1000);

      await compressor.stop();
    });
  });

  group('size guard & source bitrate cap', () {
    test('probed source bitrate adds -maxrate/-bufsize to the args', () async {
      final input = createInput('video.mp4');
      final probedPaths = <String>[];
      final compressor = buildCompressor(
        bitrateProber: (path) async {
          probedPaths.add(path);
          return 6000; // kbps
        },
      );
      compressor.start();
      await compressor.queueCompression(
        input.path,
        1,
        const CompressionSettings(),
      );
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      expect(probedPaths, [input.path]);
      final args = startedCommands.single.$2;
      expect(args[args.indexOf('-maxrate') + 1], '6000k');
      expect(args[args.indexOf('-bufsize') + 1], '12000k');

      processes.single.completeWith(1);
      await compressor.stop();
    });

    test('unknown source bitrate omits -maxrate/-bufsize', () async {
      final input = createInput('video.mp4');
      final compressor = buildCompressor(bitrateProber: (_) async => null);
      compressor.start();
      await compressor.queueCompression(
        input.path,
        2,
        const CompressionSettings(),
      );
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      final args = startedCommands.single.$2;
      expect(args, isNot(contains('-maxrate')));
      expect(args, isNot(contains('-bufsize')));

      processes.single.completeWith(1);
      await compressor.stop();
    });

    test('larger output on a plain job keeps the original', () async {
      final input = createInput('video.mp4', sizeBytes: 1000);
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(
        input.path,
        50,
        const CompressionSettings(),
      );
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      // FFmpeg "reverse compresses": output larger than the original.
      final process = processes.single;
      File(process.outputPath).writeAsBytesSync(List<int>.filled(2000, 0x42));
      process.completeWith(0);
      await waitUntil(() => callbacks.isNotEmpty, reason: 'completion');

      final record = callbacks.single;
      expect(record.success, isTrue);
      expect(record.data['status'], 'completed');
      expect('${record.data['message']}', contains('kept original'));
      expect(record.data['compressed_filename'], 'video.mp4');
      expect((record.data['compression_ratio'] as double), 0.0);
      expect(
        (record.data['compressed_file_size_mb'] as double),
        closeTo(1000 / (1024 * 1024), 1e-9),
      );
      // Original untouched, useless larger output deleted.
      expect(input.readAsBytesSync().length, 1000);
      expect(File(process.outputPath).existsSync(), isFalse);

      await compressor.stop();
    });

    test('larger output on a watermark job still swaps (overlay required)',
        () async {
      final input = createInput('video.mp4', sizeBytes: 1000);
      final compressor = buildCompressor();
      compressor.start();
      await compressor.queueCompression(
        input.path,
        51,
        const CompressionSettings(),
        videoFilter: 'drawtext=x=1',
      );
      await waitUntil(() => processes.isNotEmpty, reason: 'process start');

      final process = processes.single;
      File(process.outputPath).writeAsBytesSync(List<int>.filled(2000, 0x42));
      process.completeWith(0);
      await waitUntil(() => callbacks.isNotEmpty, reason: 'completion');

      final record = callbacks.single;
      expect(record.success, isTrue);
      expect(record.data['status'], 'completed');
      expect(record.data['compressed_filename'], 'video.mp4');
      expect((record.data['compression_ratio'] as double), closeTo(-100.0, 0.01));
      // The watermarked (larger) encode replaced the original.
      expect(input.readAsBytesSync().length, 2000);
      expect(File('${input.path}.bak').existsSync(), isFalse);

      await compressor.stop();
    });
  });

  group('status strings (COMP-05)', () {
    test('CompressionStatus values match ecom-py database rows', () {
      expect(CompressionStatus.pending.value, 'pending');
      expect(CompressionStatus.processing.value, 'processing');
      expect(CompressionStatus.completed.value, 'completed');
      expect(CompressionStatus.failed.value, 'failed');
      expect(CompressionStatus.skipped.value, 'skipped');
    });
  });
}
