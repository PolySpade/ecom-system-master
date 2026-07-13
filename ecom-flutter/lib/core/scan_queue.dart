/// Scan Queue - serializes barcode submissions so a scan arriving during a
/// save (REC-04) is queued and processed next, never dropped and never
/// interleaved with an in-flight stop/start sequence.
library;

import 'dart:collection';

/// Serialized single-flight processor for scanned/typed barcodes.
///
/// [submit] enqueues the barcode; if no drain loop is running one is
/// started, processing queued barcodes strictly in arrival order, one at a
/// time. Calls made while a drain is in progress return immediately
/// (fire-and-forget, matching UI event-handler usage).
class ScanQueue {
  ScanQueue(this._process);

  /// Processes one barcode end-to-end (validate -> stop/save -> start ...).
  final Future<void> Function(String barcode) _process;

  final Queue<Future<void> Function()> _pending =
      Queue<Future<void> Function()>();
  bool _draining = false;

  /// Whether an action is currently being processed.
  bool get isBusy => _draining;

  /// Actions waiting behind the in-flight one.
  int get pendingCount => _pending.length;

  /// Enqueues [barcode] for processing, draining if not already draining.
  Future<void> submit(String barcode) => submitAction(() => _process(barcode));

  /// Enqueues an arbitrary [action] on the same serialized lane (used by
  /// manual stop and exit-time stop so they never interleave with a scan).
  Future<void> submitAction(Future<void> Function() action) async {
    _pending.add(action);
    if (_draining) return;

    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        await _pending.removeFirst()();
      }
    } finally {
      _draining = false;
    }
  }
}
