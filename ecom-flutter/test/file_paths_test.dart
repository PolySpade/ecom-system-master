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

  group('resolveVideoPath', () {
    late Directory tempDir;
    const startTime = '2026-07-13T10:30:00.000';

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('resolve_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    File placeFile(List<String> segments) {
      final file = File(p.joinAll([tempDir.path, ...segments]));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('video');
      return file;
    }

    test('resolves the labeled layout from start time + label', () {
      final file = placeFile(
        ['2026-07-13', 'Return and Refund', 'x.mp4'],
      );

      final resolved = resolveVideoPath(
        tempDir.path,
        startTime: startTime,
        label: 'Return and Refund Unboxing',
        videoFilename: 'x.mp4',
      );

      expect(resolved, file.path);
    });

    test('falls back to the pre-label legacy layout', () {
      final file = placeFile(['2026-07-13', 'x.mp4']);

      final resolved = resolveVideoPath(
        tempDir.path,
        startTime: startTime,
        label: 'Normal (Standard)',
        videoFilename: 'x.mp4',
      );

      expect(resolved, file.path);
    });

    test('absolute filenames (Phase-1 spike rows) pass through when present',
        () {
      final file = placeFile(['abs.mp4']);

      final resolved = resolveVideoPath(
        tempDir.path,
        startTime: startTime,
        label: 'Normal (Standard)',
        videoFilename: file.path,
      );

      expect(resolved, file.path);
    });

    test('returns null when the file cannot be found anywhere', () {
      final resolved = resolveVideoPath(
        tempDir.path,
        startTime: startTime,
        label: 'Normal (Standard)',
        videoFilename: 'missing.mp4',
      );

      expect(resolved, isNull);
    });

    test('returns null for an unparseable start time', () {
      final resolved = resolveVideoPath(
        tempDir.path,
        startTime: 'not-a-date',
        label: 'Normal (Standard)',
        videoFilename: 'x.mp4',
      );

      expect(resolved, isNull);
    });
  });
}
