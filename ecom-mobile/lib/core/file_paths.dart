/// File path construction for recorded videos.
///
/// Direct behavioral port of the folder/filename logic embedded in
/// ecom-py/camera_handler.py's start_recording()/_get_label_folder_name().
/// Owns barcode path-safety sanitization (T-01-01 threat mitigation).
library;

import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

/// Exact 3-entry label -> folder-name map from ecom-py/camera_handler.py,
/// with "Normal" as the fallback default for any unrecognized label.
const Map<String, String> _labelFolderMap = {
  'Return and Refund Unboxing': 'Return and Refund',
  'Return Parcel Unboxing': 'Return Parcel',
  'Normal (Standard)': 'Normal',
};

/// Maps a label string to its folder name. Unknown labels fall back to
/// "Normal".
String labelFolderName(String label) {
  return _labelFolderMap[label] ?? 'Normal';
}

/// Removes/replaces path separators and traversal sequences so [barcode] is
/// safe to use as a filename segment (T-01-01 mitigation).
///
/// Strips/replaces '/', '\\', and any '..' sequence by replacing each
/// disallowed character with '_' and collapsing '..' sequences, so a
/// barcode can never inject a directory separator or parent-directory
/// traversal into a file path.
String sanitizeBarcode(String barcode) {
  var sanitized = barcode.replaceAll('/', '_').replaceAll('\\', '_');
  // Collapse any remaining '..' sequences (defends against '....' style
  // evasion attempts as well, by repeating until stable).
  while (sanitized.contains('..')) {
    sanitized = sanitized.replaceAll('..', '_');
  }
  return sanitized;
}

/// Builds the full video file path for a recording and ensures the target
/// directory exists.
///
/// Produces: `<basePath>/yyyy-MM-dd/<labelFolder>/yyyyMMdd_HHmmss_BARCODE.mp4`
/// The barcode is routed through [sanitizeBarcode] before being concatenated
/// into the filename so it can never escape the label directory.
String buildVideoPath(String basePath, String barcode, String labelFolder) {
  final now = DateTime.now();
  final dateFolder = DateFormat('yyyy-MM-dd').format(now);
  final timestamp = DateFormat('yyyyMMdd_HHmmss').format(now);

  final folder = p.join(basePath, dateFolder, labelFolder);
  Directory(folder).createSync(recursive: true);

  final safeBarcode = sanitizeBarcode(barcode);
  final filename = '${timestamp}_$safeBarcode.mp4';
  return p.join(folder, filename);
}

/// Resolves a stored transaction row back to a playable file path (STO-03),
/// mirroring ecom-py/app_gui.py's resolution: try the labeled layout
/// `<base>/<yyyy-MM-dd from startTime>/<labelFolder>/<filename>` first,
/// then fall back to the pre-label-folder legacy layout
/// `<base>/<yyyy-MM-dd>/<filename>`. Absolute [videoFilename] values
/// (written by the Phase-1 spike, which stored full paths) pass through.
/// Returns null when no candidate exists on disk.
String? resolveVideoPath(
  String basePath, {
  required String startTime,
  required String label,
  required String videoFilename,
}) {
  if (p.isAbsolute(videoFilename)) {
    return File(videoFilename).existsSync() ? videoFilename : null;
  }

  final DateTime parsed;
  try {
    parsed = DateTime.parse(startTime);
  } catch (_) {
    return null;
  }
  final dateFolder = DateFormat('yyyy-MM-dd').format(parsed);

  final labeled =
      p.join(basePath, dateFolder, labelFolderName(label), videoFilename);
  if (File(labeled).existsSync()) return labeled;

  final legacy = p.join(basePath, dateFolder, videoFilename);
  if (File(legacy).existsSync()) return legacy;

  return null;
}
