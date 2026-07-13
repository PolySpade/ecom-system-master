import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ecom_flutter/core/file_paths.dart';

void main() {
  group('labelFolderName', () {
    test('maps known labels to their folder names', () {
      expect(labelFolderName('Normal (Standard)'), 'Normal');
      expect(
        labelFolderName('Return and Refund Unboxing'),
        'Return and Refund',
      );
      expect(labelFolderName('Return Parcel Unboxing'), 'Return Parcel');
    });

    test('falls back to Normal for unrecognized labels', () {
      expect(labelFolderName('unknown-xyz'), 'Normal');
    });
  });

  group('sanitizeBarcode', () {
    test('leaves benign input unchanged', () {
      expect(sanitizeBarcode('ABC123'), 'ABC123');
    });

    test('path-traversal payload rendered filename-safe', () {
      final sanitized = sanitizeBarcode('../../etc/passwd');
      expect(sanitized.contains('/'), isFalse);
      expect(sanitized.contains('\\'), isFalse);
      expect(sanitized.contains('..'), isFalse);
    });

    test('strips backslashes', () {
      final sanitized = sanitizeBarcode(r'..\..\windows\system32');
      expect(sanitized.contains('/'), isFalse);
      expect(sanitized.contains('\\'), isFalse);
      expect(sanitized.contains('..'), isFalse);
    });
  });

  group('buildVideoPath', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('file_paths_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('produces a path matching the videos layout', () {
      final path = buildVideoPath(tempDir.path, 'ABC123', 'Normal');

      expect(path.contains('${p.separator}Normal${p.separator}'), isTrue);
      expect(path.endsWith('_ABC123.mp4'), isTrue);

      final basename = p.basename(path);
      // yyyyMMdd_HHmmss_ABC123.mp4 -> first 15 chars are "yyyyMMdd_HHmmss"
      final timestampSegment = basename.split('_ABC123.mp4').first;
      expect(timestampSegment.length, 15);
      expect(RegExp(r'^\d{8}_\d{6}$').hasMatch(timestampSegment), isTrue);

      // Directory must have been created.
      expect(Directory(p.dirname(path)).existsSync(), isTrue);
    });

    test('path-traversal barcode cannot escape the label directory', () {
      final path = buildVideoPath(tempDir.path, '../evil', 'Normal');

      final basename = p.basename(path);
      final finalSegment = basename.split('_').last; // "evil.mp4" or similar

      expect(finalSegment.contains('/'), isFalse);
      expect(finalSegment.contains('\\'), isFalse);
      expect(finalSegment.contains('..'), isFalse);

      // The produced path must still live under the label directory.
      expect(path.contains('${p.separator}Normal${p.separator}'), isTrue);
    });
  });

  group('resolveVideoPath (SRCH-06 legacy fallback)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('resolve_video_path_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('returns the label-folder path when the file exists there', () {
      final labeled = Directory(
        p.join(tempDir.path, '2026-07-01', 'Return and Refund'),
      )..createSync(recursive: true);
      File(p.join(labeled.path, 'v.mp4')).createSync();

      final resolved = resolveVideoPath(
        basePath: tempDir.path,
        startTime: '2026-07-01T10:30:00.000',
        label: 'Return and Refund Unboxing',
        videoFilename: 'v.mp4',
      );
      expect(resolved, p.join(labeled.path, 'v.mp4'));
    });

    test('falls back to the legacy date-root path when label path missing',
        () {
      final dateRoot = Directory(p.join(tempDir.path, '2026-07-01'))
        ..createSync(recursive: true);
      File(p.join(dateRoot.path, 'legacy.mp4')).createSync();

      final resolved = resolveVideoPath(
        basePath: tempDir.path,
        startTime: '2026-07-01T10:30:00.000',
        label: 'Normal (Standard)',
        videoFilename: 'legacy.mp4',
      );
      expect(resolved, p.join(dateRoot.path, 'legacy.mp4'));
      expect(File(resolved).existsSync(), isTrue);
    });

    test('prefers the label-folder path when both layouts have the file',
        () {
      final labeled = Directory(p.join(tempDir.path, '2026-07-01', 'Normal'))
        ..createSync(recursive: true);
      File(p.join(labeled.path, 'both.mp4')).createSync();
      File(p.join(tempDir.path, '2026-07-01', 'both.mp4')).createSync();

      final resolved = resolveVideoPath(
        basePath: tempDir.path,
        startTime: '2026-07-01T10:30:00.000',
        label: 'Normal (Standard)',
        videoFilename: 'both.mp4',
      );
      expect(resolved, p.join(labeled.path, 'both.mp4'));
    });

    test('returns the legacy path even when neither file exists '
        '(caller surfaces not-found, matching the reference)', () {
      final resolved = resolveVideoPath(
        basePath: tempDir.path,
        startTime: '2026-07-01T10:30:00.000',
        label: 'Normal (Standard)',
        videoFilename: 'ghost.mp4',
      );
      expect(resolved, p.join(tempDir.path, '2026-07-01', 'ghost.mp4'));
      expect(File(resolved).existsSync(), isFalse);
    });

    test('unknown label resolves through the Normal folder', () {
      final labeled = Directory(p.join(tempDir.path, '2026-07-01', 'Normal'))
        ..createSync(recursive: true);
      File(p.join(labeled.path, 'v.mp4')).createSync();

      final resolved = resolveVideoPath(
        basePath: tempDir.path,
        startTime: '2026-07-01T10:30:00.000',
        label: 'Something Unrecognized',
        videoFilename: 'v.mp4',
      );
      expect(resolved, p.join(labeled.path, 'v.mp4'));
    });
  });
}
