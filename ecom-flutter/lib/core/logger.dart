/// Minimal logger - appends to logs/app.log and prints to console.
///
/// Behavioral port of ecom-py/app_gui.py's logging.basicConfig setup
/// (FileHandler + StreamHandler, format
/// '%(asctime)s - %(name)s - %(levelname)s - %(message)s').
library;

import 'dart:io';

/// Appends log lines to a file (ensuring the parent directory exists) and
/// also prints them to the console, matching ecom-py's dual
/// FileHandler + StreamHandler behavior.
class Logger {
  Logger(this.name, this.logFilePath) {
    Directory(File(logFilePath).parent.path).createSync(recursive: true);
  }

  /// Logger name, printed in place of Python's %(name)s (module/class name).
  final String name;

  /// Full path to the log file (e.g. `<logPath>/app.log`).
  final String logFilePath;

  void info(String message) => _log('INFO', message);

  void warning(String message) => _log('WARNING', message);

  void error(String message) => _log('ERROR', message);

  void _log(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final line = '$timestamp - $name - $level - $message';
    // ignore: avoid_print
    print(line);
    try {
      File(logFilePath).writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Logging must never crash the app; swallow file-write failures.
    }
  }
}
