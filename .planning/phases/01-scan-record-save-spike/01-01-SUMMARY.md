---
phase: 01-scan-record-save-spike
plan: 01
subsystem: desktop-app
tags: [flutter, dart, sqlite, sqflite_common_ffi, camera, camera_windows, windows-desktop]

# Dependency graph
requires: []
provides:
  - "ecom-flutter/ Flutter Windows project scaffold with full dependency set (camera, camera_windows, sqflite_common_ffi, window_manager, win32, win32_registry, path, path_provider, intl)"
  - "BarcodeHandler 3-action state machine (start/stopAndStart/invalid), direct behavioral port of ecom-py/barcode_handler.py"
  - "file_paths.dart: sanitizeBarcode (T-01-01 path-traversal mitigation) + buildVideoPath (videos/YYYY-MM-DD/<Label>/timestamp_BARCODE.mp4) + labelFolderName map"
  - "AppDatabase: single long-lived WAL sqflite_common_ffi connection, schema byte-compatible with ecom-py/database.py (14 columns), createTransaction/completeTransaction/getRecentTransactions/getTotalStorageUsed"
  - "CameraService: thin CameraController wrapper (init/buildPreview/startRecording/stopRecording), currentFilename/currentLabel getters for the RECORDING overlay"
  - "MainScreen: manual barcode entry + Stop button (disabled while idle) + live preview + recent-recordings list, wiring the full scan->record->stop-and-start->stop->DB loop"
  - "main.dart composition root: config -> db -> camera -> barcodeHandler construction order"
affects: [01-02, 01-03, phase-2-recording-workflow]

# Tech tracking
tech-stack:
  added: [flutter 3.41.6, camera ^0.12.0+1, camera_windows ^0.2.6+4, sqflite_common_ffi 2.4.0+3, window_manager ^0.5.2, win32 ^6.3.0, win32_registry ^3.0.3, path ^1.9.1, path_provider ^2.1.6, intl ^0.20.3, flutter_lints ^6.0.0]
  patterns:
    - "Thin native-plugin wrapper (CameraService) instead of reimplementing frame-buffer/capture-thread machinery"
    - "Single long-lived WAL SQLite connection instead of ecom-py's per-call connect/close"
    - "Barcode sanitization at the file_paths boundary before path concatenation (T-01-01)"
    - "Fail-loud writes / fail-safe reads across database.dart and camera_service.dart"

key-files:
  created:
    - ecom-flutter/lib/core/barcode_handler.dart
    - ecom-flutter/lib/core/file_paths.dart
    - ecom-flutter/lib/core/config.dart
    - ecom-flutter/lib/core/logger.dart
    - ecom-flutter/lib/core/database.dart
    - ecom-flutter/lib/core/camera_service.dart
    - ecom-flutter/lib/models/transaction.dart
    - ecom-flutter/lib/ui/main_screen.dart
    - ecom-flutter/test/barcode_handler_test.dart
    - ecom-flutter/test/file_paths_test.dart
    - ecom-flutter/test/database_test.dart
  modified:
    - ecom-flutter/lib/main.dart
    - ecom-flutter/pubspec.yaml

key-decisions:
  - "sqflite_common_ffi pinned to 2.4.0+3 (not the plan's requested ^2.4.2) because 2.4.1+ requires Dart SDK ^3.12.0 and the installed toolchain is Dart 3.11.4; 2.4.0+3 (SDK ^3.10.0-0) is the newest version compatible with the installed SDK and still resolves sqlite3 3.3.4 (>=3.0.0, satisfying the release-DLL bundling requirement from RESEARCH.md Pitfall 5)"
  - "Removed the default flutter_create widget_test.dart (counter smoke test) since it referenced MyApp/MyHomePage, both replaced by EcomVideoTrackerApp/MainScreen in Task 3"

requirements-completed: [REC-01, REC-02, REC-03, REC-05, CAM-01, STO-01, DB-01, DB-02, SET-01, LOG-01]

# Metrics
duration: 34min
completed: 2026-07-11
---

# Phase 01 Plan 01: Walking Skeleton Summary

**Flutter Windows scaffold with a full manual scan->record->stop-and-start->stop->DB loop: BarcodeHandler 3-action state machine, WAL sqflite_common_ffi data layer schema-identical to ecom-py, and a thin CameraController wrapper - all analyze-clean and covered by 22 passing pure-Dart unit tests on Linux.**

## Performance

- **Duration:** 34 min
- **Started:** 2026-07-11T07:41:00Z (approx, based on worktree branch check)
- **Completed:** 2026-07-11T07:15:43Z
- **Tasks:** 3
- **Files modified:** 37 (33 scaffold + core files in Task 1, 2 in Task 2, 4 in Task 3, 2 planning docs already existed)

## Accomplishments
- Scaffolded `ecom-flutter/` (Flutter 3.41.6, Windows platform target) with the full RESEARCH.md Standard Stack dependency set
- Ported `BarcodeHandler` (3 actions only: start/stopAndStart/invalid - no dead `stop` action, no `is_start_code`/`is_stop_code` prefix logic) with unit tests covering every validate/process behavior case
- Ported `file_paths.dart` with `sanitizeBarcode` (T-01-01 path-traversal mitigation) and `buildVideoPath`, unit-tested including two explicit path-traversal payload cases
- Built a schema-byte-compatible WAL SQLite data layer (`database.dart`) with a single long-lived connection (DB-02), all 14 columns matching `ecom-py/database.py`, and `ALTER TABLE` backward-compat for the 4 compression columns
- Wired the full manual scan -> record -> stop-and-start -> stop -> DB loop through `camera_service.dart` + `main_screen.dart` + `main.dart`, with the sequential stop-before-start ordering ecom-py's `process_barcode` requires

## Task Commits

1. **Task 1: Scaffold Flutter project + pure-Dart core (barcode handler, file paths, config, logger) with unit tests** - `8cde9e7` (feat)
2. **Task 2: Schema-compatible WAL SQLite data layer with a real read/write and unit test** - `4d72852` (feat)
3. **Task 3: Camera service + minimal main screen wiring the full scan->record->stop-and-start->stop->DB loop** - `8d98a7c` (feat)

**Plan metadata:** committed alongside this SUMMARY (see final commit)

## Files Created/Modified
- `ecom-flutter/lib/core/barcode_handler.dart` - 3-action barcode state machine, direct port of ecom-py/barcode_handler.py
- `ecom-flutter/lib/core/file_paths.dart` - sanitizeBarcode + buildVideoPath + labelFolderName map
- `ecom-flutter/lib/core/config.dart` - beside-executable base dir, deep-merged settings.json over defaults
- `ecom-flutter/lib/core/logger.dart` - dual file+console logging matching ecom-py's log format
- `ecom-flutter/lib/core/database.dart` - single long-lived WAL SQLite connection, schema-identical to ecom-py
- `ecom-flutter/lib/core/camera_service.dart` - thin CameraController wrapper: init, start/stop recording, preview
- `ecom-flutter/lib/models/transaction.dart` - typed row shape with fromRow factory
- `ecom-flutter/lib/ui/main_screen.dart` - preview + manual barcode entry + Stop button + recordings list
- `ecom-flutter/lib/main.dart` - composition root: config -> db -> camera -> barcodeHandler
- `ecom-flutter/test/barcode_handler_test.dart`, `test/file_paths_test.dart`, `test/database_test.dart` - 22 passing pure-Dart unit tests

## Decisions Made
- Pinned `sqflite_common_ffi` to `2.4.0+3` instead of the plan's `^2.4.2` due to an SDK constraint mismatch (2.4.1+ requires Dart SDK ^3.12.0, installed toolchain is 3.11.4). This is a Rule 3 blocking-issue fix, not a package-legitimacy concern - `sqflite_common_ffi` itself was already vetted in RESEARCH.md's Package Legitimacy Audit; only the exact patch version differs, and the resolved transitive `sqlite3` dependency (3.3.4) still satisfies RESEARCH.md Pitfall 5's `>=3.0.0` DLL-bundling requirement.
- Removed the stock `widget_test.dart` counter smoke test (Rule 1 - it referenced `MyApp`/`MyHomePage`, both replaced by `EcomVideoTrackerApp`/`MainScreen` when `main.dart` was rewired in Task 3; leaving it would have been a compile-time failure, not a deferred concern).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] sqflite_common_ffi version pinned to 2.4.0+3 instead of plan's ^2.4.2**
- **Found during:** Task 1 (dependency installation)
- **Issue:** `flutter pub add sqflite_common_ffi:^2.4.2` failed version solving - `sqflite_common_ffi` >=2.4.1 requires Dart SDK `^3.12.0`, but the installed Dart SDK is 3.11.4 (pinned via `environment: sdk: ^3.11.4` generated by `flutter create`).
- **Fix:** Verified via the live pub.dev API that `2.4.0+3` is the newest version with an SDK floor (`^3.10.0-0`) compatible with the installed toolchain; installed that version instead. Confirmed transitive `sqlite3` dependency still resolves to `3.3.4` (>=3.0.0), satisfying RESEARCH.md's release-DLL bundling requirement (Pitfall 5).
- **Files modified:** ecom-flutter/pubspec.yaml, ecom-flutter/pubspec.lock
- **Verification:** `flutter pub get` resolved successfully; `flutter test test/database_test.dart` passes all 6 cases including the WAL-mode assertion.
- **Committed in:** 8cde9e7 (Task 1 commit)

**2. [Rule 1 - Bug] Removed obsolete widget_test.dart referencing deleted classes**
- **Found during:** Task 3 (main.dart rewrite)
- **Issue:** The default `flutter create` counter `widget_test.dart` imports and instantiates `MyApp`/`MyHomePage`, both of which were replaced by `EcomVideoTrackerApp`/`MainScreen` when `main.dart` became the real composition root. Leaving it in place would break `flutter test` and `flutter analyze`.
- **Fix:** Deleted `test/widget_test.dart`. No replacement widget test was added in this task (out of plan scope - Task 3's `<files>` list does not include a widget test, and its `<verify>` block only requires `flutter analyze`).
- **Files modified:** ecom-flutter/test/widget_test.dart (deleted)
- **Verification:** `flutter analyze` exits 0; `flutter test` (full suite) still passes all 22 tests with the file removed.
- **Committed in:** 8d98a7c (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (1 blocking dependency-resolution fix, 1 bug fix for a broken pre-existing test file)
**Impact on plan:** Neither deviation changes architecture or scope. The SDK version pin is a patch-level substitution of an already-vetted package: no new package name was introduced, so this does not require a `checkpoint:human-verify` gate. The test deletion removes dead code that the plan's own Task 3 changes made unrunnable.

## Issues Encountered
None beyond the two auto-fixed deviations above.

## User Setup Required
None - no external service configuration required. All work in this plan is Linux-verifiable (flutter create, flutter analyze, flutter test); Windows hardware validation is explicitly deferred to Plan 03 per the plan's own scope.

## Next Phase Readiness
- The architectural skeleton (barcode state machine, file paths, config, database, thin camera wrapper, main screen orchestration) is in place and unit-tested on Linux.
- `SKELETON.md` (already produced during the planning phase, unchanged by this execution) documents the architectural decisions and out-of-scope deferrals for Phases 2-5.
- Plan 02 (keyboard-wedge global barcode capture) and Plan 03 (Windows hardware validation: back-to-back stop/start reliability, HardwareKeyboard focus-independence, real camera/scanner hardware) can proceed - both depend only on the services built in this plan.
- No blockers identified. The one open risk carried forward from RESEARCH.md (undocumented `stopVideoRecording()` -> `startVideoRecording()` latency/frame-loss behavior) remains explicitly deferred to Plan 03's hardware spike, as designed.

---
*Phase: 01-scan-record-save-spike*
*Completed: 2026-07-11*

## Self-Check: PASSED

All created files verified present on disk; all 4 task/summary commits (8cde9e7, 4d72852, 8d98a7c, 33e8a6a) verified present in git log.
