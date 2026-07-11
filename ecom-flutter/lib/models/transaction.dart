/// Transaction model - mirrors a row of the `transactions` SQLite table.
///
/// No single "model class" exists in the Python reference (rows are plain
/// dicts via sqlite3.Row); this class has one field per schema column.
library;

/// A single scan-to-recording transaction row.
class Transaction {
  Transaction({
    required this.id,
    required this.barcode,
    required this.videoFilename,
    required this.startTime,
    this.endTime,
    this.durationSeconds,
    this.fileSizeMb,
    this.stopMethod,
    this.label = 'Normal (Standard)',
    required this.createdAt,
    this.compressionStatus = 'pending',
    this.compressedFileSizeMb,
    this.compressionRatio,
    this.compressedFilename,
  });

  /// Builds a [Transaction] from a raw SQLite row map.
  factory Transaction.fromRow(Map<String, Object?> row) {
    return Transaction(
      id: row['id'] as int,
      barcode: row['barcode'] as String,
      videoFilename: row['video_filename'] as String,
      startTime: row['start_time'] as String,
      endTime: row['end_time'] as String?,
      durationSeconds: row['duration_seconds'] as int?,
      fileSizeMb: (row['file_size_mb'] as num?)?.toDouble(),
      stopMethod: row['stop_method'] as String?,
      label: (row['label'] as String?) ?? 'Normal (Standard)',
      createdAt: row['created_at'] as String,
      compressionStatus: (row['compression_status'] as String?) ?? 'pending',
      compressedFileSizeMb:
          (row['compressed_file_size_mb'] as num?)?.toDouble(),
      compressionRatio: (row['compression_ratio'] as num?)?.toDouble(),
      compressedFilename: row['compressed_filename'] as String?,
    );
  }

  final int id;
  final String barcode;
  final String videoFilename;
  final String startTime;
  final String? endTime;
  final int? durationSeconds;
  final double? fileSizeMb;
  final String? stopMethod;
  final String label;
  final String createdAt;
  final String compressionStatus;
  final double? compressedFileSizeMb;
  final double? compressionRatio;
  final String? compressedFilename;
}
