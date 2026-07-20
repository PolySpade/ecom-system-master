/// Video file actions - open with the default player, reveal in Explorer.
///
/// Behavioral port of EcomVideoTrackerApp.open_video / show_in_folder in
/// ecom-py/app_gui.py (SRCH-05, and reusable for STO-03): normalize the
/// path, verify the file exists, then hand off to the OS shell. Failures
/// return an error message string instead of throwing so UI callers can
/// show a dialog.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Opens [videoPath] with the system default video player. Returns null on
/// success, or a user-displayable error message.
Future<String?> openVideo(String videoPath) async {
  final path = p.normalize(videoPath);
  if (!File(path).existsSync()) {
    return 'Video file not found:\n$path';
  }
  try {
    if (Platform.isWindows) {
      // `start "" <path>` is the shell equivalent of Python's os.startfile:
      // opens the file with its registered default handler. The empty ""
      // is the window title slot so quoted paths aren't eaten by `start`.
      await Process.run('cmd', ['/c', 'start', '', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
    return null;
  } catch (e) {
    return 'Failed to open video: $e';
  }
}

/// Reveals [videoPath] in the system file manager (Explorer with the file
/// pre-selected on Windows). Returns null on success, or a user-displayable
/// error message.
Future<String?> showInFolder(String videoPath) async {
  final path = p.normalize(videoPath);
  if (!File(path).existsSync()) {
    return 'Video file not found:\n$path';
  }
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      await Process.run('xdg-open', [p.dirname(path)]);
    }
    return null;
  } catch (e) {
    return 'Failed to open folder: $e';
  }
}
