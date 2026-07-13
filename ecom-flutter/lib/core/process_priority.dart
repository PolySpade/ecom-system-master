/// Process Priority - lowers a spawned process's Windows priority class
/// (COMP-04/SET-06).
///
/// Ports ecom-py/video_compressor.py's PRIORITY_FLAGS behavior. ecom-py
/// passes the priority class as a CreateProcess creation flag; Dart's
/// Process.start exposes no creation flags, so this shim instead applies
/// the priority immediately after spawn via kernel32
/// OpenProcess/SetPriorityClass (dart:ffi). The child runs at its default
/// priority for the few milliseconds between spawn and this call - an
/// accepted tradeoff for keeping Process.start's reliable argument
/// handling, piped/drainable output, and exit codes.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Windows priority class flags (WinBase.h), matching ecom-py's
/// PRIORITY_FLAGS map key-for-key.
const Map<String, int> priorityClassFlags = {
  'low': 0x00000040, // IDLE_PRIORITY_CLASS
  'below_normal': 0x00004000, // BELOW_NORMAL_PRIORITY_CLASS
  'normal': 0x00000020, // NORMAL_PRIORITY_CLASS
};

// Process access rights (winnt.h).
const int _processSetInformation = 0x0200;
const int _processQueryLimitedInformation = 0x1000;

// Top-level finals are lazily initialized in Dart, so kernel32 is only
// loaded on first use - and both entry points below guard on
// Platform.isWindows before touching these.
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function(int, int, int) _openProcess = _kernel32.lookupFunction<
    IntPtr Function(Uint32, Int32, Uint32),
    int Function(int, int, int)>('OpenProcess');

final int Function(int, int) _setPriorityClass = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Uint32), int Function(int, int)>('SetPriorityClass');

final int Function(int) _getPriorityClass = _kernel32.lookupFunction<
    Uint32 Function(IntPtr), int Function(int)>('GetPriorityClass');

final int Function(int) _closeHandle = _kernel32.lookupFunction<
    Int32 Function(IntPtr), int Function(int)>('CloseHandle');

/// Sets the priority class of process [pid] to [priority] ('low',
/// 'below_normal', or 'normal'; unknown values fall back to
/// 'below_normal', matching ecom-py). Returns true on success. No-op
/// (returns false) on non-Windows platforms.
bool setProcessPriority(int pid, String priority) {
  if (!Platform.isWindows) {
    return false;
  }
  final flag =
      priorityClassFlags[priority] ?? priorityClassFlags['below_normal']!;
  final handle = _openProcess(_processSetInformation, 0, pid);
  if (handle == 0) {
    return false;
  }
  try {
    return _setPriorityClass(handle, flag) != 0;
  } finally {
    _closeHandle(handle);
  }
}

/// Returns the current priority class flag of process [pid], or null when
/// it cannot be queried (or on non-Windows platforms). Test-support for
/// verifying [setProcessPriority] round-trips.
@visibleForTesting
int? queryProcessPriorityClass(int pid) {
  if (!Platform.isWindows) {
    return null;
  }
  final handle = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (handle == 0) {
    return null;
  }
  try {
    final flag = _getPriorityClass(handle);
    return flag == 0 ? null : flag;
  } finally {
    _closeHandle(handle);
  }
}
