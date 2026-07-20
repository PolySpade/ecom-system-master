/// Video file actions - open with the default player, share to other apps.
///
/// Mobile port of open_video / show_in_folder (SRCH-05, STO-03): normalize
/// the path, verify the file exists, then hand off to Android. "Reveal in
/// folder" has no Android equivalent, so it becomes a share-sheet export.
/// Failures return an error message string instead of throwing so UI
/// callers can show a dialog.
library;

import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Opens [videoPath] with the system default video player. Returns null on
/// success, or a user-displayable error message.
Future<String?> openVideo(String videoPath) async {
  final path = p.normalize(videoPath);
  if (!File(path).existsSync()) {
    return 'Video file not found:\n$path';
  }
  try {
    final result = await OpenFilex.open(path, type: 'video/mp4');
    if (result.type != ResultType.done) {
      return 'Failed to open video: ${result.message}';
    }
    return null;
  } catch (e) {
    return 'Failed to open video: $e';
  }
}

/// Shares [videoPath] through the Android share sheet (the mobile stand-in
/// for the desktop "show in folder" action). Returns null on success, or a
/// user-displayable error message.
Future<String?> shareVideo(String videoPath) async {
  final path = p.normalize(videoPath);
  if (!File(path).existsSync()) {
    return 'Video file not found:\n$path';
  }
  try {
    await Share.shareXFiles([XFile(path)]);
    return null;
  } catch (e) {
    return 'Failed to share video: $e';
  }
}
