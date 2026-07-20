/// Database - SQLite data access layer, schema-identical to
/// ecom-py/database.py.
///
/// Behavioral port of ecom-py/database.py, with one deliberate divergence
/// (DB-02): a single long-lived WAL-mode connection opened once at startup,
/// instead of ecom-py's per-call sqlite3.connect()/close() pattern.
library;

import 'dart:io';

import 'package:sqflite/sqflite.dart' hide Transaction;

import 'logger.dart';
import '../models/transaction.dart';

/// The four compression columns added via ALTER TABLE in ecom-py, kept here
/// so an existing ecom-py-created database.db (which will not trigger
/// onCreate) can be brought up to the current schema.
const Map<String, String> _compressionColumns = {
  'compression_status': "TEXT DEFAULT 'pending'",
  'compressed_file_size_mb': 'REAL',
  'compression_ratio': 'REAL',
  'compressed_filename': 'TEXT',
};

/// Result of [AppDatabase.advancedSearch]: one page of matching rows plus
/// the total match count (for the "Showing X of Y" footer, SRCH-08).
class AdvancedSearchResult {
  const AdvancedSearchResult({
    required this.results,
    required this.total,
    this.limit,
    this.offset = 0,
  });

  /// The (possibly limited) page of matching transactions.
  final List<Transaction> results;

  /// Total number of rows matching the filters, ignoring limit/offset.
  final int total;

  /// The limit that was applied, or null for unlimited.
  final int? limit;

  /// The offset that was applied.
  final int offset;
}

/// Opens and owns the single long-lived SQLite connection for the app.
class AppDatabase {
  AppDatabase._(this._db, this._logger);

  final Database _db;
  final Logger _logger;

  /// Opens (and if needed, creates/migrates) the database at [dbPath].
  /// WAL mode is enabled via PRAGMA in onConfigure. Returns a single shared
  /// [AppDatabase] instance - callers must NOT open per-call connections.
  static Future<AppDatabase> open(String dbPath, Logger logger) async {
    // On Android this is the sqflite plugin's factory; host-side tests
    // point the same global at sqflite_common_ffi in setUp.
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        onConfigure: (db) async {
          // Android's SQLiteDatabase.execSQL() rejects statements that
          // return a result row; journal_mode=WAL returns the resulting
          // mode, so this must go through rawQuery, not execute.
          await db.rawQuery('PRAGMA journal_mode=WAL');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS transactions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              barcode TEXT NOT NULL,
              video_filename TEXT NOT NULL,
              start_time TIMESTAMP,
              end_time TIMESTAMP,
              duration_seconds INTEGER,
              file_size_mb REAL,
              stop_method TEXT,
              label TEXT DEFAULT 'Normal (Standard)',
              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
              compression_status TEXT DEFAULT 'pending',
              compressed_file_size_mb REAL,
              compression_ratio REAL,
              compressed_filename TEXT
            )
          ''');
        },
        version: 1,
      ),
    );

    // Backward-compat: an existing ecom-py-created database.db will not
    // trigger onCreate. Check for the compression columns individually and
    // ALTER TABLE ADD COLUMN any that are missing.
    await _ensureCompressionColumns(db, logger);

    return AppDatabase._(db, logger);
  }

  static Future<void> _ensureCompressionColumns(
    Database db,
    Logger logger,
  ) async {
    final info = await db.rawQuery('PRAGMA table_info(transactions)');
    final existingColumns = info.map((row) => row['name'] as String).toSet();

    for (final entry in _compressionColumns.entries) {
      if (!existingColumns.contains(entry.key)) {
        try {
          await db.execute(
            'ALTER TABLE transactions ADD COLUMN ${entry.key} ${entry.value}',
          );
        } catch (e) {
          logger.error('Error adding column ${entry.key}: $e');
        }
      }
    }
  }

  /// Inserts a new transaction row and returns its rowid.
  Future<int> createTransaction(
    String barcode,
    String videoFilename, {
    String label = 'Normal (Standard)',
  }) async {
    try {
      final startTime = DateTime.now().toIso8601String();
      final id = await _db.insert('transactions', {
        'barcode': barcode,
        'video_filename': videoFilename,
        'start_time': startTime,
        'label': label,
      });
      _logger.info(
        'Created transaction $id for barcode $barcode (Label: $label)',
      );
      return id;
    } catch (e) {
      _logger.error('Error creating transaction: $e');
      rethrow;
    }
  }

  /// Updates a transaction row when its recording stops.
  Future<void> completeTransaction(
    int id, {
    required int durationSeconds,
    required double fileSizeMb,
    required String stopMethod,
  }) async {
    try {
      final endTime = DateTime.now().toIso8601String();
      await _db.update(
        'transactions',
        {
          'end_time': endTime,
          'duration_seconds': durationSeconds,
          'file_size_mb': fileSizeMb,
          'stop_method': stopMethod,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      _logger.info(
        'Completed transaction $id (${durationSeconds}s, '
        '${fileSizeMb.toStringAsFixed(2)}MB, stop_method=$stopMethod)',
      );
    } catch (e) {
      _logger.error('Error completing transaction: $e');
      rethrow;
    }
  }

  /// Returns the most recent transactions, newest first.
  Future<List<Transaction>> getRecentTransactions({int limit = 10}) async {
    try {
      final rows = await _db.query(
        'transactions',
        orderBy: 'start_time DESC',
        limit: limit,
      );
      return rows.map(Transaction.fromRow).toList();
    } catch (e) {
      _logger.error('Error fetching recent transactions: $e');
      return [];
    }
  }

  /// Returns the sum of file_size_mb across all rows, or 0.0 when none.
  Future<double> getTotalStorageUsed() async {
    try {
      final result = await _db.rawQuery(
        'SELECT SUM(file_size_mb) as total FROM transactions',
      );
      final total = result.first['total'];
      if (total == null) return 0.0;
      return (total as num).toDouble();
    } catch (e) {
      _logger.error('Error fetching total storage used: $e');
      return 0.0;
    }
  }

  /// Updates the compression status for a transaction (COMP-05).
  ///
  /// Only the provided optional fields are written, mirroring ecom-py
  /// database.py's dynamically-built UPDATE in update_compression_status().
  /// [status] must be one of ecom-py's status strings:
  /// pending/processing/completed/failed/skipped.
  Future<void> updateCompressionStatus(
    int id,
    String status, {
    double? compressedFileSizeMb,
    double? compressionRatio,
    String? compressedFilename,
  }) async {
    try {
      final values = <String, Object?>{
        'compression_status': status,
        'compressed_file_size_mb': ?compressedFileSizeMb,
        'compression_ratio': ?compressionRatio,
        'compressed_filename': ?compressedFilename,
      };
      await _db.update(
        'transactions',
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
      _logger.info('Updated compression status for transaction $id: $status');
    } catch (e) {
      _logger.error('Error updating compression status: $e');
      rethrow;
    }
  }

  /// Returns completed recordings still awaiting compression
  /// (compression_status = 'pending' AND end_time set), oldest first -
  /// mirrors ecom-py database.py's get_pending_compressions().
  Future<List<Transaction>> getPendingCompressions() async {
    try {
      final rows = await _db.query(
        'transactions',
        where: "compression_status = 'pending' AND end_time IS NOT NULL",
        orderBy: 'created_at ASC',
      );
      return rows.map(Transaction.fromRow).toList();
    } catch (e) {
      _logger.error('Error fetching pending compressions: $e');
      return [];
    }
  }

  /// Columns [advancedSearch] accepts for ORDER BY; anything else falls
  /// back to created_at (mirrors ecom-py's valid_sort_columns whitelist -
  /// the sort column is interpolated into SQL, so it MUST be whitelisted).
  static const List<String> _validSortColumns = [
    'id',
    'barcode',
    'created_at',
    'duration_seconds',
    'file_size_mb',
    'label',
  ];

  /// Advanced search with filtering, sorting, and pagination - behavioral
  /// port of ecom-py database.py's advanced_search (SRCH-01..04, SRCH-08).
  ///
  /// - [barcode]: partial, case-insensitive match (UPPER LIKE UPPER)
  /// - [startDate]/[endDate]: inclusive ISO dates (YYYY-MM-DD) compared
  ///   against DATE(created_at)
  /// - [label]: exact match
  /// - [sortBy]: whitelisted column (falls back to created_at)
  /// - [sortOrder]: 'ASC' or 'DESC' (anything not DESC becomes ASC,
  ///   matching the reference)
  ///
  /// Returns an empty result on error instead of throwing (matches the
  /// reference's read-query error contract).
  Future<AdvancedSearchResult> advancedSearch({
    String? barcode,
    String? startDate,
    String? endDate,
    String? label,
    String sortBy = 'created_at',
    String sortOrder = 'DESC',
    int? limit,
    int offset = 0,
  }) async {
    try {
      final whereClauses = <String>[];
      final params = <Object?>[];

      if (barcode != null && barcode.isNotEmpty) {
        whereClauses.add('UPPER(barcode) LIKE UPPER(?)');
        params.add('%$barcode%');
      }
      if (startDate != null && startDate.isNotEmpty) {
        whereClauses.add('DATE(created_at) >= ?');
        params.add(startDate);
      }
      if (endDate != null && endDate.isNotEmpty) {
        whereClauses.add('DATE(created_at) <= ?');
        params.add(endDate);
      }
      if (label != null && label.isNotEmpty) {
        whereClauses.add('label = ?');
        params.add(label);
      }

      final whereClause =
          whereClauses.isNotEmpty ? 'WHERE ${whereClauses.join(' AND ')}' : '';

      final safeSortBy =
          _validSortColumns.contains(sortBy) ? sortBy : 'created_at';
      final safeSortOrder = sortOrder.toUpperCase() == 'DESC' ? 'DESC' : 'ASC';

      final countRows = await _db.rawQuery(
        'SELECT COUNT(*) AS total FROM transactions $whereClause',
        params,
      );
      final total = (countRows.first['total'] as num?)?.toInt() ?? 0;

      var query = 'SELECT * FROM transactions $whereClause '
          'ORDER BY $safeSortBy $safeSortOrder';
      if (limit != null) {
        query += ' LIMIT $limit OFFSET $offset';
      }

      final rows = await _db.rawQuery(query, params);
      final results = rows.map(Transaction.fromRow).toList();

      _logger.info(
        'Advanced search returned ${results.length} of $total total results',
      );
      return AdvancedSearchResult(
        results: results,
        total: total,
        limit: limit,
        offset: offset,
      );
    } catch (e) {
      _logger.error('Error in advanced search: $e');
      return AdvancedSearchResult(
        results: const [],
        total: 0,
        limit: limit,
        offset: offset,
      );
    }
  }

  /// Resets rows stuck in compression_status='processing' back to
  /// 'pending' (a job that was mid-flight when the app was killed). Run at
  /// startup so interrupted jobs reappear in the Compress All backlog.
  Future<int> resetStuckProcessing() async {
    final n = await _db.update(
      'transactions',
      {'compression_status': 'pending'},
      where: "compression_status = 'processing'",
    );
    if (n > 0) {
      _logger.info('Reset $n interrupted compression job(s) to pending');
    }
    return n;
  }

  /// Deletes every transaction row (Settings > Clear Database). Returns the
  /// number of rows removed. Does not touch video files on disk.
  Future<int> clearAllTransactions() async {
    final removed = await _db.delete('transactions');
    _logger.info('Cleared database: $removed transaction rows deleted');
    return removed;
  }

  /// Copies the database file to [destPath] (Settings > Backup Database).
  /// Forces a WAL checkpoint first so the snapshot contains every committed
  /// transaction (the -wal sidecar is folded into the main file).
  Future<void> backupTo(String destPath) async {
    // Same execSQL-vs-rawQuery restriction as onConfigure above:
    // wal_checkpoint returns a (busy, log, checkpointed) row.
    await _db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await File(_db.path).copy(destPath);
    _logger.info('Database backed up to $destPath');
  }

  /// Closes the underlying database connection.
  Future<void> close() => _db.close();
}
