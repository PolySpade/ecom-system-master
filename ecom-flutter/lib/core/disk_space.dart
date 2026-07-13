/// Disk Space guard - free-space probe + pre-recording threshold check.
///
/// STO-02/CAM-05: a disk-space check runs before starting a recording; the
/// operator is blocked when free space is critically low and warned when it
/// is merely low. ecom-py has no free-space guard (its only related
/// constant, MAX_STORAGE_GB=500, is unused), so the threshold lives in this
/// app's config as `storage.min_free_space_gb`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Result of evaluating free disk space against the configured threshold.
enum DiskSpaceStatus {
  /// Plenty of space (or space unknown - never block on a failed probe).
  ok,

  /// Below 5x the threshold: warn the operator but allow recording.
  low,

  /// Below the threshold: block starting a new recording.
  critical,
}

/// Pure threshold logic (unit-testable without Win32). A null [freeGb]
/// (probe failed / non-Windows) is treated as ok so a broken probe can
/// never block recording.
DiskSpaceStatus evaluateDiskSpace(double? freeGb, {required double minFreeGb}) {
  if (freeGb == null) return DiskSpaceStatus.ok;
  if (freeGb < minFreeGb) return DiskSpaceStatus.critical;
  if (freeGb < minFreeGb * 5) return DiskSpaceStatus.low;
  return DiskSpaceStatus.ok;
}

/// Returns the free space (GB, available to the current user) on the volume
/// containing [path], or null when it cannot be determined. Uses Win32
/// GetDiskFreeSpaceEx; falls back to the volume root when [path] does not
/// exist yet (e.g. videos/ before the first recording).
double? getFreeSpaceGb(String path) {
  if (!Platform.isWindows) return null;

  var probePath = p.normalize(p.absolute(path));
  if (!Directory(probePath).existsSync()) {
    final root = p.rootPrefix(probePath);
    if (root.isEmpty) return null;
    probePath = root;
  }

  final pathPtr = probePath.toNativeUtf16();
  final freeAvailable = calloc<Uint64>();
  final totalBytes = calloc<Uint64>();
  final totalFree = calloc<Uint64>();
  try {
    final result = GetDiskFreeSpaceEx(
      PCWSTR(pathPtr),
      freeAvailable,
      totalBytes,
      totalFree,
    );
    if (!result.value) return null;
    return freeAvailable.value / (1024 * 1024 * 1024);
  } catch (_) {
    return null;
  } finally {
    calloc.free(pathPtr);
    calloc.free(freeAvailable);
    calloc.free(totalBytes);
    calloc.free(totalFree);
  }
}
