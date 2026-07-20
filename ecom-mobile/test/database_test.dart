import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'package:ecom_mobile/core/database.dart';
import 'package:ecom_mobile/core/logger.dart';

void main() {
  late Directory tempDir;
  late Logger logger;

  setUpAll(() {
    ffi.sqfliteFfiInit();
    databaseFactory = ffi.databaseFactoryFfi;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('database_test_');
    logger = Logger('test', '${tempDir.path}/logs/app.log');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('open() creates the transactions table with all 14 columns', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    // Re-open the raw connection to inspect schema directly.
    ffi.sqfliteFfiInit();
    final rawDb = await ffi.databaseFactoryFfi.openDatabase(dbPath);
    final info = await rawDb.rawQuery('PRAGMA table_info(transactions)');
    final columnNames = info.map((row) => row['name'] as String).toSet();

    expect(columnNames, {
      'id',
      'barcode',
      'video_filename',
      'start_time',
      'end_time',
      'duration_seconds',
      'file_size_mb',
      'stop_method',
      'label',
      'created_at',
      'compression_status',
      'compressed_file_size_mb',
      'compression_ratio',
      'compressed_filename',
    });

    await rawDb.close();
    await appDb.close();
  });

  test('journal_mode is wal after open()', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    ffi.sqfliteFfiInit();
    final rawDb = await ffi.databaseFactoryFfi.openDatabase(dbPath);
    final result = await rawDb.rawQuery('PRAGMA journal_mode');
    final mode = (result.first.values.first as String).toLowerCase();
    expect(mode, 'wal');

    await rawDb.close();
    await appDb.close();
  });

  test('createTransaction inserts a row and returns a positive id', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    final id = await appDb.createTransaction(
      'ABC123',
      '/videos/x.mp4',
      label: 'Normal (Standard)',
    );

    expect(id, greaterThan(0));

    final recent = await appDb.getRecentTransactions(limit: 10);
    expect(recent, hasLength(1));
    expect(recent.first.barcode, 'ABC123');
    expect(recent.first.label, 'Normal (Standard)');
    expect(recent.first.startTime, isNotEmpty);
    expect(recent.first.compressionStatus, 'pending');

    await appDb.close();
  });

  test('completeTransaction updates the row', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    final id = await appDb.createTransaction('ABC123', '/videos/x.mp4');
    await appDb.completeTransaction(
      id,
      durationSeconds: 12,
      fileSizeMb: 3.45,
      stopMethod: 'manual',
    );

    final recent = await appDb.getRecentTransactions(limit: 10);
    final row = recent.firstWhere((t) => t.id == id);
    expect(row.endTime, isNotNull);
    expect(row.durationSeconds, 12);
    expect(row.fileSizeMb, 3.45);
    expect(row.stopMethod, 'manual');

    await appDb.close();
  });

  test('getRecentTransactions returns newest-first', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    await appDb.createTransaction('FIRST', '/videos/first.mp4');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await appDb.createTransaction('SECOND', '/videos/second.mp4');

    final recent = await appDb.getRecentTransactions(limit: 10);
    expect(recent, hasLength(2));
    expect(recent.first.barcode, 'SECOND');
    expect(recent.last.barcode, 'FIRST');

    await appDb.close();
  });

  test('getTotalStorageUsed sums file_size_mb, 0.0 when none', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    expect(await appDb.getTotalStorageUsed(), 0.0);

    final id1 = await appDb.createTransaction('A', '/videos/a.mp4');
    await appDb.completeTransaction(
      id1,
      durationSeconds: 5,
      fileSizeMb: 1.5,
      stopMethod: 'barcode',
    );
    final id2 = await appDb.createTransaction('B', '/videos/b.mp4');
    await appDb.completeTransaction(
      id2,
      durationSeconds: 5,
      fileSizeMb: 2.5,
      stopMethod: 'barcode',
    );

    expect(await appDb.getTotalStorageUsed(), 4.0);

    await appDb.close();
  });

  test('updateCompressionStatus writes status only when no extras given',
      () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    final id = await appDb.createTransaction('ABC123', '/videos/x.mp4');
    await appDb.updateCompressionStatus(id, 'processing');

    final recent = await appDb.getRecentTransactions(limit: 10);
    final row = recent.firstWhere((t) => t.id == id);
    expect(row.compressionStatus, 'processing');
    expect(row.compressedFileSizeMb, isNull);
    expect(row.compressionRatio, isNull);
    expect(row.compressedFilename, isNull);

    await appDb.close();
  });

  test('updateCompressionStatus persists size, ratio and filename', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    final id = await appDb.createTransaction('ABC123', '/videos/x.mp4');
    await appDb.updateCompressionStatus(
      id,
      'completed',
      compressedFileSizeMb: 1.23,
      compressionRatio: 45.6,
      compressedFilename: 'x.mp4',
    );

    final recent = await appDb.getRecentTransactions(limit: 10);
    final row = recent.firstWhere((t) => t.id == id);
    expect(row.compressionStatus, 'completed');
    expect(row.compressedFileSizeMb, 1.23);
    expect(row.compressionRatio, 45.6);
    expect(row.compressedFilename, 'x.mp4');

    await appDb.close();
  });

  test(
      'getPendingCompressions returns only pending completed recordings, '
      'oldest first', () async {
    final dbPath = '${tempDir.path}/database.db';
    final appDb = await AppDatabase.open(dbPath, logger);

    // Pending but still recording (no end_time) - excluded.
    await appDb.createTransaction('STILL_RECORDING', '/videos/a.mp4');

    // Completed recording, still pending - included.
    final pending1 = await appDb.createTransaction('OLD', '/videos/b.mp4');
    await appDb.completeTransaction(
      pending1,
      durationSeconds: 5,
      fileSizeMb: 1.0,
      stopMethod: 'barcode',
    );

    // Completed recording, already compressed - excluded.
    final done = await appDb.createTransaction('DONE', '/videos/c.mp4');
    await appDb.completeTransaction(
      done,
      durationSeconds: 5,
      fileSizeMb: 1.0,
      stopMethod: 'barcode',
    );
    await appDb.updateCompressionStatus(done, 'completed');

    // Second pending completed recording - included, after pending1.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final pending2 = await appDb.createTransaction('NEW', '/videos/d.mp4');
    await appDb.completeTransaction(
      pending2,
      durationSeconds: 5,
      fileSizeMb: 1.0,
      stopMethod: 'manual',
    );

    final result = await appDb.getPendingCompressions();
    expect(result.map((t) => t.barcode).toList(), ['OLD', 'NEW']);

    await appDb.close();
  });
}
