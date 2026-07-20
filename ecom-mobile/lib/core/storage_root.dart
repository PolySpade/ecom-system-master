/// Storage root resolution - picks the effective video root at startup.
///
/// The configured default points at the public Movies collection
/// (gallery-visible, USB-copyable, survives uninstall). Android 11+ lets
/// an app create its own media files there via direct paths; Android 9-
/// needs the (manifest + runtime) storage permission; some OEM setups
/// disallow it entirely. So the path is write-probed once at startup and
/// the app-private fallback is used when the probe fails - recording must
/// never be blocked by storage-permission quirks.
library;

import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'logger.dart';

/// Probes [preferred] for writability (creating it if needed); returns it
/// on success, otherwise [fallback]. On Android a failed first probe
/// triggers one storage-permission request (pre-Android-10 devices) and a
/// retry.
Future<String> resolveWritableVideoRoot(
  String preferred,
  String fallback,
  Logger logger,
) async {
  if (await _isWritable(preferred)) {
    return preferred;
  }

  if (Platform.isAndroid) {
    try {
      final status = await Permission.storage.request();
      if (status.isGranted && await _isWritable(preferred)) {
        return preferred;
      }
    } catch (e) {
      logger.warning('Storage permission request failed: $e');
    }
  }

  logger.warning(
    'Video root not writable ($preferred) - falling back to $fallback',
  );
  return fallback;
}

Future<bool> _isWritable(String dir) async {
  try {
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final probe = File(
      '$dir${Platform.pathSeparator}.write_probe',
    );
    probe.writeAsStringSync('probe');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}
