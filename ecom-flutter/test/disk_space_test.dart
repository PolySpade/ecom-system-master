import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_flutter/core/disk_space.dart';

void main() {
  group('evaluateDiskSpace', () {
    test('blocks below the configured floor', () {
      expect(
        evaluateDiskSpace(0.5, minFreeGb: 1.0),
        DiskSpaceStatus.critical,
      );
      expect(
        evaluateDiskSpace(0.99, minFreeGb: 1.0),
        DiskSpaceStatus.critical,
      );
    });

    test('warns between 1x and 5x the floor', () {
      expect(evaluateDiskSpace(1.0, minFreeGb: 1.0), DiskSpaceStatus.low);
      expect(evaluateDiskSpace(4.99, minFreeGb: 1.0), DiskSpaceStatus.low);
    });

    test('ok at or above 5x the floor', () {
      expect(evaluateDiskSpace(5.0, minFreeGb: 1.0), DiskSpaceStatus.ok);
      expect(evaluateDiskSpace(500, minFreeGb: 1.0), DiskSpaceStatus.ok);
    });

    test('a failed probe (null) never blocks recording', () {
      expect(evaluateDiskSpace(null, minFreeGb: 1.0), DiskSpaceStatus.ok);
    });

    test('respects a custom threshold', () {
      expect(evaluateDiskSpace(9.0, minFreeGb: 10.0), DiskSpaceStatus.critical);
      expect(evaluateDiskSpace(20.0, minFreeGb: 10.0), DiskSpaceStatus.low);
      expect(evaluateDiskSpace(50.0, minFreeGb: 10.0), DiskSpaceStatus.ok);
    });
  });

  group('getFreeSpaceGb', () {
    test('probes a real volume on Windows', () {
      if (!Platform.isWindows) return;
      final free = getFreeSpaceGb(Directory.current.path);
      expect(free, isNotNull);
      expect(free, greaterThan(0));
    });

    test('falls back to the volume root for a not-yet-created path', () {
      if (!Platform.isWindows) return;
      final free = getFreeSpaceGb(
        '${Directory.current.path}\\does_not_exist_yet\\videos',
      );
      expect(free, isNotNull);
      expect(free, greaterThan(0));
    });
  });
}
