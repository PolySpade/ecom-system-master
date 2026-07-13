import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_flutter/core/process_priority.dart';

void main() {
  test('priority flag map matches ecom-py PRIORITY_FLAGS', () {
    expect(priorityClassFlags['low'], 0x00000040);
    expect(priorityClassFlags['below_normal'], 0x00004000);
    expect(priorityClassFlags['normal'], 0x00000020);
  });

  test(
    'setProcessPriority round-trips on a real process (self)',
    () {
      final selfPid = pid;
      final originalFlag = queryProcessPriorityClass(selfPid);
      expect(originalFlag, isNotNull);

      try {
        expect(setProcessPriority(selfPid, 'below_normal'), isTrue);
        expect(queryProcessPriorityClass(selfPid), 0x00004000);

        expect(setProcessPriority(selfPid, 'normal'), isTrue);
        expect(queryProcessPriorityClass(selfPid), 0x00000020);

        // Unknown priority string falls back to below_normal (ecom-py
        // parity).
        expect(setProcessPriority(selfPid, 'bogus'), isTrue);
        expect(queryProcessPriorityClass(selfPid), 0x00004000);
      } finally {
        // Restore whatever the test runner started with.
        final restore = originalFlag == 0x00000040
            ? 'low'
            : originalFlag == 0x00004000
                ? 'below_normal'
                : 'normal';
        setProcessPriority(selfPid, restore);
      }
    },
    skip: !Platform.isWindows ? 'Windows-only kernel32 FFI' : false,
  );

  test(
    'setProcessPriority returns false for a nonexistent pid',
    () {
      // PIDs are multiples of 4 on Windows; an absurdly large one will not
      // exist.
      expect(setProcessPriority(0x7FFFFFFC, 'below_normal'), isFalse);
    },
    skip: !Platform.isWindows ? 'Windows-only kernel32 FFI' : false,
  );
}
