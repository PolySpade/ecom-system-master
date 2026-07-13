import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'package:ecom_flutter/core/database.dart';
import 'package:ecom_flutter/core/logger.dart';

void main() {
  late Directory tempDir;
  late Logger logger;
  late AppDatabase appDb;
  late String dbPath;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('advanced_search_test_');
    logger = Logger('test', '${tempDir.path}/logs/app.log');
    dbPath = '${tempDir.path}/database.db';
    appDb = await AppDatabase.open(dbPath, logger);
  });

  tearDown(() async {
    await appDb.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Inserts a fully-specified row via a raw connection so created_at,
  /// duration and size are controllable (createTransaction only sets
  /// barcode/filename/start_time/label).
  Future<void> insertRow({
    required String barcode,
    String filename = 'x.mp4',
    String label = 'Normal (Standard)',
    required String createdAt,
    int? durationSeconds,
    double? fileSizeMb,
  }) async {
    ffi.sqfliteFfiInit();
    // singleInstance: false - the ffi factory caches connections per path,
    // and closing the shared singleton would close appDb's handle too.
    final raw = await ffi.databaseFactoryFfi.openDatabase(
      dbPath,
      options: ffi.OpenDatabaseOptions(singleInstance: false),
    );
    await raw.insert('transactions', {
      'barcode': barcode,
      'video_filename': filename,
      'start_time': '${createdAt}T09:00:00.000',
      'label': label,
      'created_at': '$createdAt 09:00:00',
      'duration_seconds': durationSeconds,
      'file_size_mb': fileSizeMb,
    });
    await raw.close();
  }

  group('filters', () {
    test('barcode filter is partial and case-insensitive', () async {
      await insertRow(barcode: 'ABC123', createdAt: '2026-07-01');
      await insertRow(barcode: 'xyzabc999', createdAt: '2026-07-02');
      await insertRow(barcode: 'NOPE', createdAt: '2026-07-03');

      final result = await appDb.advancedSearch(barcode: 'abc');
      expect(result.total, 2);
      expect(
        result.results.map((t) => t.barcode).toSet(),
        {'ABC123', 'xyzabc999'},
      );
    });

    test('label filter is an exact match', () async {
      await insertRow(
        barcode: 'A',
        label: 'Return and Refund Unboxing',
        createdAt: '2026-07-01',
      );
      await insertRow(
        barcode: 'B',
        label: 'Normal (Standard)',
        createdAt: '2026-07-02',
      );

      final result =
          await appDb.advancedSearch(label: 'Return and Refund Unboxing');
      expect(result.total, 1);
      expect(result.results.single.barcode, 'A');

      // A partial label must NOT match.
      final partial = await appDb.advancedSearch(label: 'Return');
      expect(partial.total, 0);
    });

    test('date range filters on DATE(created_at), inclusive both ends',
        () async {
      await insertRow(barcode: 'OLD', createdAt: '2026-06-30');
      await insertRow(barcode: 'IN1', createdAt: '2026-07-01');
      await insertRow(barcode: 'IN2', createdAt: '2026-07-05');
      await insertRow(barcode: 'NEW', createdAt: '2026-07-06');

      final result = await appDb.advancedSearch(
        startDate: '2026-07-01',
        endDate: '2026-07-05',
      );
      expect(result.total, 2);
      expect(result.results.map((t) => t.barcode).toSet(), {'IN1', 'IN2'});

      // Each date bound is optional independently.
      final onlyStart = await appDb.advancedSearch(startDate: '2026-07-05');
      expect(onlyStart.results.map((t) => t.barcode).toSet(), {'IN2', 'NEW'});
      final onlyEnd = await appDb.advancedSearch(endDate: '2026-06-30');
      expect(onlyEnd.results.map((t) => t.barcode).toSet(), {'OLD'});
    });

    test('filters combine with AND', () async {
      await insertRow(
        barcode: 'ABC1',
        label: 'Normal (Standard)',
        createdAt: '2026-07-01',
      );
      await insertRow(
        barcode: 'ABC2',
        label: 'Return Parcel Unboxing',
        createdAt: '2026-07-01',
      );
      await insertRow(
        barcode: 'ABC3',
        label: 'Normal (Standard)',
        createdAt: '2026-07-09',
      );

      final result = await appDb.advancedSearch(
        barcode: 'ABC',
        label: 'Normal (Standard)',
        endDate: '2026-07-05',
      );
      expect(result.total, 1);
      expect(result.results.single.barcode, 'ABC1');
    });

    test('no filters returns everything', () async {
      await insertRow(barcode: 'A', createdAt: '2026-07-01');
      await insertRow(barcode: 'B', createdAt: '2026-07-02');

      final result = await appDb.advancedSearch();
      expect(result.total, 2);
      expect(result.results, hasLength(2));
    });
  });

  group('sorting', () {
    test('sorts by whitelisted columns in both orders', () async {
      await insertRow(
        barcode: 'BBB',
        createdAt: '2026-07-01',
        durationSeconds: 30,
        fileSizeMb: 5.0,
      );
      await insertRow(
        barcode: 'AAA',
        createdAt: '2026-07-02',
        durationSeconds: 10,
        fileSizeMb: 9.0,
      );

      final byBarcode =
          await appDb.advancedSearch(sortBy: 'barcode', sortOrder: 'ASC');
      expect(byBarcode.results.first.barcode, 'AAA');

      final byDuration = await appDb.advancedSearch(
        sortBy: 'duration_seconds',
        sortOrder: 'DESC',
      );
      expect(byDuration.results.first.barcode, 'BBB');

      final bySize =
          await appDb.advancedSearch(sortBy: 'file_size_mb', sortOrder: 'DESC');
      expect(bySize.results.first.barcode, 'AAA');

      final newest = await appDb.advancedSearch(
        sortBy: 'created_at',
        sortOrder: 'DESC',
      );
      expect(newest.results.first.barcode, 'AAA');
      final oldest = await appDb.advancedSearch(
        sortBy: 'created_at',
        sortOrder: 'ASC',
      );
      expect(oldest.results.first.barcode, 'BBB');
    });

    test('non-whitelisted sort column falls back to created_at', () async {
      await insertRow(barcode: 'OLD', createdAt: '2026-07-01');
      await insertRow(barcode: 'NEW', createdAt: '2026-07-02');

      // A hostile/typo'd sort column must not be interpolated into SQL.
      final result = await appDb.advancedSearch(
        sortBy: 'id; DROP TABLE transactions',
        sortOrder: 'DESC',
      );
      expect(result.results.first.barcode, 'NEW');
      // Table is intact afterwards.
      expect((await appDb.advancedSearch()).total, 2);
    });

    test('invalid sort order falls back to ASC', () async {
      await insertRow(barcode: 'OLD', createdAt: '2026-07-01');
      await insertRow(barcode: 'NEW', createdAt: '2026-07-02');

      final result = await appDb.advancedSearch(sortOrder: 'SIDEWAYS');
      expect(result.results.first.barcode, 'OLD');
    });
  });

  group('pagination', () {
    test('limit and offset page results while total stays full count',
        () async {
      for (var i = 1; i <= 5; i++) {
        await insertRow(barcode: 'BC$i', createdAt: '2026-07-0$i');
      }

      final page1 = await appDb.advancedSearch(
        sortBy: 'created_at',
        sortOrder: 'ASC',
        limit: 2,
      );
      expect(page1.total, 5);
      expect(page1.results.map((t) => t.barcode).toList(), ['BC1', 'BC2']);

      final page2 = await appDb.advancedSearch(
        sortBy: 'created_at',
        sortOrder: 'ASC',
        limit: 2,
        offset: 2,
      );
      expect(page2.total, 5);
      expect(page2.results.map((t) => t.barcode).toList(), ['BC3', 'BC4']);
      expect(page2.limit, 2);
      expect(page2.offset, 2);
    });

    test('no limit returns all matches', () async {
      for (var i = 1; i <= 3; i++) {
        await insertRow(barcode: 'BC$i', createdAt: '2026-07-0$i');
      }
      final result = await appDb.advancedSearch();
      expect(result.results, hasLength(3));
      expect(result.limit, isNull);
    });
  });
}
