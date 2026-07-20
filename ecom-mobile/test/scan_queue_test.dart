import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_mobile/core/scan_queue.dart';

void main() {
  group('ScanQueue', () {
    test('processes a single barcode', () async {
      final processed = <String>[];
      final queue = ScanQueue((barcode) async => processed.add(barcode));

      await queue.submit('A');

      expect(processed, ['A']);
      expect(queue.isBusy, isFalse);
      expect(queue.pendingCount, 0);
    });

    test('queues scans arriving during a save and preserves order', () async {
      final processed = <String>[];
      final gates = <Completer<void>>[];

      final queue = ScanQueue((barcode) async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future; // Simulate a slow stop/save.
        processed.add(barcode);
      });

      // First scan starts processing; two more arrive mid-save.
      final first = queue.submit('A');
      await Future<void>.delayed(Duration.zero);
      unawaited(queue.submit('B'));
      unawaited(queue.submit('C'));

      expect(queue.isBusy, isTrue);
      expect(queue.pendingCount, 2); // B and C queued, not dropped.
      expect(processed, isEmpty);

      // Release each save in turn.
      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(processed, ['A']);

      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      expect(processed, ['A', 'B']);

      gates[2].complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(processed, ['A', 'B', 'C']);
      expect(queue.isBusy, isFalse);
    });

    test('never runs two actions concurrently', () async {
      var concurrent = 0;
      var maxConcurrent = 0;

      final queue = ScanQueue((barcode) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        concurrent--;
      });

      await Future.wait([
        queue.submit('A'),
        queue.submit('B'),
        queue.submit('C'),
      ]);

      expect(maxConcurrent, 1);
    });

    test('submitAction serializes on the same lane as scans', () async {
      final events = <String>[];
      final queue = ScanQueue((barcode) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        events.add('scan:$barcode');
      });

      final scan = queue.submit('A');
      final action = queue.submitAction(() async => events.add('stop'));
      await Future.wait([scan, action]);

      expect(events, ['scan:A', 'stop']);
    });

    test('keeps working after a processor error', () async {
      final processed = <String>[];
      final queue = ScanQueue((barcode) async {
        if (barcode == 'BAD') throw StateError('boom');
        processed.add(barcode);
      });

      await expectLater(queue.submit('BAD'), throwsStateError);
      await queue.submit('GOOD');

      expect(processed, ['GOOD']);
      expect(queue.isBusy, isFalse);
    });
  });
}
