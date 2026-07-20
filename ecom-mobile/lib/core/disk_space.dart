/// Disk Space guard - free-space probe + pre-recording threshold check.
///
/// STO-02/CAM-05: a disk-space check runs before starting a recording; the
/// operator is blocked when free space is critically low and warned when it
/// is merely low. The desktop app probes via Win32; Android has no probe
/// yet, so [getFreeSpaceGb] returns null and the check never blocks (a
/// StatFs-based probe can be added later if storage-full becomes a real
/// operational issue on phones).
library;

/// Result of evaluating free disk space against the configured threshold.
enum DiskSpaceStatus {
  /// Plenty of space (or space unknown - never block on a failed probe).
  ok,

  /// Below 5x the threshold: warn the operator but allow recording.
  low,

  /// Below the threshold: block starting a new recording.
  critical,
}

/// Pure threshold logic. A null [freeGb] (probe unavailable) is treated as
/// ok so a broken probe can never block recording.
DiskSpaceStatus evaluateDiskSpace(double? freeGb, {required double minFreeGb}) {
  if (freeGb == null) return DiskSpaceStatus.ok;
  if (freeGb < minFreeGb) return DiskSpaceStatus.critical;
  if (freeGb < minFreeGb * 5) return DiskSpaceStatus.low;
  return DiskSpaceStatus.ok;
}

/// Returns the free space (GB) on the volume containing [path], or null
/// when it cannot be determined. No probe is implemented on Android yet.
double? getFreeSpaceGb(String path) => null;
