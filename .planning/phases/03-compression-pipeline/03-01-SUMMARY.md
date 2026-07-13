---
phase: 03-compression-pipeline
plan: 01
subsystem: desktop-app
tags: [flutter, dart, ffmpeg, compression, ffi, sqlite, background-worker]

# Dependency graph
requires: ["01-01", "01-02"]
provides:
  - "FfmpegLocator.findFfmpeg()/findFfprobe(): static discovery (bundled dir beside exe -> common install paths -> PATH), cached, with test seams - contract byte-identical to the Phase-2 worktree's copy"
  - "VideoCompressor: serialized FIFO background worker (start/stop/queueCompression), CompressionStatus enum with ecom-py DB string values, CompressionSettings (+ fromConfig), injectable ProcessStarter/FfmpegFinder/PriorityApplier/jobTimeout seams"
  - "queueStatus ValueNotifier<CompressionQueueStatus> (queueSize/isProcessing/currentTransactionId/workerRunning) + queueLength getter for Phase 2's status panel"
  - "Crash-safe atomic replacement: temp-in-same-dir, original -> .bak, temp -> original, delete .bak; failure path restores + never touches the original"
  - "setProcessPriority(pid, priority): kernel32 OpenProcess/SetPriorityClass FFI mapping ecom-py's low/below_normal/normal flags"
  - "AppDatabase.updateCompressionStatus / getPendingCompressions mirroring ecom-py database.py"
  - "Config compression category (enabled/codec/crf/preset/delete_original/priority) + typed getters + Config.loadFrom(baseDir) test seam"
  - "CompressionStatusIndicator widget ready to slot into Phase 2's status panel"
affects: ["phase-04 settings dialog (SET-06 UI)", "phase-05 packaging (FFmpeg bundling)"]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Serialized async pump (_pump + whenComplete re-entry) as the Dart analog of ecom-py's queue.Queue + daemon worker thread - one job in flight, FIFO, caller never blocks"
    - "Injectable seams (typedefs for process start, binary discovery, priority, timeout) so external-binary behavior is unit-testable without the binary installed"
    - "dart:ffi kernel32 binding for APIs the win32 package (6.3.0) does not expose (SetPriorityClass)"
    - "@visibleForTesting static debug overrides (base dir/common paths/environment) on a static-only locator class"

key-files:
  created:
    - ecom-flutter/lib/core/ffmpeg_locator.dart
    - ecom-flutter/lib/core/video_compressor.dart
    - ecom-flutter/lib/core/process_priority.dart
    - ecom-flutter/lib/ui/compression_status_indicator.dart
    - ecom-flutter/test/ffmpeg_locator_test.dart
    - ecom-flutter/test/video_compressor_test.dart
    - ecom-flutter/test/process_priority_test.dart
    - ecom-flutter/test/config_test.dart
  modified:
    - ecom-flutter/lib/core/config.dart
    - ecom-flutter/lib/core/database.dart
    - ecom-flutter/test/database_test.dart

key-decisions:
  - "Process priority via post-spawn kernel32 OpenProcess/SetPriorityClass FFI rather than a `cmd /c start /low` wrapper: keeps Process.start's reliable argument-list quoting, drainable pipes, and direct exit codes; accepts a few milliseconds at default priority before the class is lowered. win32 6.3.0 does not export SetPriorityClass, so raw dart:ffi bindings were written (no new dependency)."
  - "Atomic swap diverges deliberately from ecom-py (which deletes the original before renaming): original -> .bak, temp -> original, delete .bak, so every crash point leaves at least one intact copy (COMP-03); failure mid-swap triggers a best-effort restore of the original."
  - "FfmpegLocator verifies by file existence instead of spawning `ffmpeg -version` (ecom-py's approach) - no child process during discovery, no hang risk; the compressor itself surfaces a broken binary as a failed job."
  - "No DB schema work needed: Phase 1's _ensureCompressionColumns already ships the idempotent ALTER TABLE migration for the four compression columns; this plan only added the update/query methods."
  - "deleteOriginal=false keeps BOTH the original and the _compressed file and records the _compressed basename in the DB - verified against ecom-py's _process_job (it only removes/renames when delete_original is true)."

requirements-completed: [COMP-01, COMP-02, COMP-03, COMP-04, COMP-05]

# Metrics
duration: 35min
completed: 2026-07-13
---

# Phase 03 Plan 01: Compression Pipeline Summary

**Serialized FIFO FFmpeg background worker with graceful skip when FFmpeg is missing/disabled, crash-safe backup-rename atomic replacement, kernel32-FFI process priority, 1-hour kill timeout, ecom-py-exact DB status persistence, and a drop-in queue-status widget - all unit-tested without FFmpeg installed.**

## Performance

- **Duration:** ~35 min
- **Completed:** 2026-07-13
- **Tasks:** 5
- **Files modified:** 11 (8 created, 3 modified)

## Accomplishments

- Implemented `FfmpegLocator` (`ecom-flutter/lib/core/ffmpeg_locator.dart`) with the exact two-method static contract shared with the Phase-2 worktree (`findFfmpeg`/`findFfprobe`), searching (1) `ffmpeg.exe`, `ffmpeg/ffmpeg.exe`, `ffmpeg/bin/ffmpeg.exe` beside the executable, (2) `C:\ffmpeg\bin`, both Program Files variants, `~\ffmpeg\bin`, (3) every PATH directory - ecom-py's `check_ffmpeg_installed` ordering. Results cached per binary; 9 unit tests cover each tier, precedence, independence of ffmpeg/ffprobe, and cache reset.
- Added the `compression` settings category to `Config` (`enabled`/`codec`/`crf`/`preset`/`delete_original`/`priority`) with ecom-py `settings_manager.py`'s exact defaults, six typed getters, and a `Config.loadFrom(baseDir)` seam; 4 tests cover defaults, deep-merge overrides, malformed-JSON fallback, and path resolution.
- Extended `AppDatabase` with `updateCompressionStatus` (partial-field UPDATE mirroring ecom-py's dynamically-built query) and `getPendingCompressions` (`compression_status='pending' AND end_time IS NOT NULL`, oldest first). Phase 1's idempotent `_ensureCompressionColumns` migration already covers ecom-py-created databases, so no schema change was required.
- Built `VideoCompressor` (`ecom-flutter/lib/core/video_compressor.dart`): a `ListQueue` + `_pump()`/`whenComplete` re-entry loop that processes jobs strictly one at a time FIFO (COMP-01), `CompressionStatus` enum with ecom-py's DB string values, callback resultData keys matching ecom-py (`status`, `compressed_file_size_mb`, `compression_ratio`, `compressed_filename`, `message`), and graceful-skip short-circuits for disabled compression / missing FFmpeg (logged warning + `skipped` callback, recording never touched) (COMP-02).
- Atomic replacement (COMP-03): compresses to `<name>_compressed.mp4` in the same directory, requires exit code 0 AND non-empty output, then swaps via original->`.bak`, temp->original, delete `.bak` - every crash point leaves at least one intact copy; swap failure attempts to restore the original. `deleteOriginal=false` keeps both files (ecom-py parity).
- FFmpeg invocation (COMP-04): `-c:v libx264|libx265`, CRF clamped 18-35, preset, `-threads 2`, `-c:a aac -b:a 128k -y`; stdout/stderr drained; 1-hour timeout (injectable) with forced kill; process priority applied post-spawn via new `process_priority.dart` kernel32 FFI (`low`/`below_normal`/`normal` mapping ecom-py's PRIORITY_FLAGS), round-trip-verified on the test runner's own process.
- Published `queueStatus` (`ValueNotifier<CompressionQueueStatus>`) + `queueLength`, and a self-contained `CompressionStatusIndicator` widget for Phase 2's status panel - `lib/ui/main_screen.dart` and `lib/main.dart` untouched as planned.
- 34 new tests (15 compressor, 9 locator, 4 config, 3 database additions, 3 priority); full suite now 63 tests, all passing; `flutter analyze` clean.

## Task Commits

1. **Plan document** - `a780b51` (docs)
2. **Task 1: FFmpeg discovery via FfmpegLocator (COMP-02)** - `413bc62` (feat)
3. **Task 2: compression settings in Config (COMP-04/SET-06)** - `09ccf11` (feat)
4. **Task 3: DB compression status persistence (COMP-05)** - `2556720` (feat)
5. **Task 4: serialized FFmpeg compression worker (COMP-01/03/04)** - `7966ba9` (feat)
6. **Task 5: compression status indicator widget** - `0aee173` (feat)

**Plan metadata:** committed alongside this SUMMARY (see final commit)

## Files Created/Modified

- `ecom-flutter/lib/core/ffmpeg_locator.dart` - static FFmpeg/ffprobe discovery, shared Phase-2 contract, cached, test seams
- `ecom-flutter/lib/core/video_compressor.dart` - CompressionStatus/CompressionSettings/CompressionJob/CompressionQueueStatus + VideoCompressor worker
- `ecom-flutter/lib/core/process_priority.dart` - kernel32 OpenProcess/SetPriorityClass/GetPriorityClass FFI, ecom-py priority flag map
- `ecom-flutter/lib/ui/compression_status_indicator.dart` - drop-in queue status widget for Phase 2
- `ecom-flutter/lib/core/config.dart` - compression category defaults + getters, loadFrom seam
- `ecom-flutter/lib/core/database.dart` - updateCompressionStatus, getPendingCompressions
- `ecom-flutter/test/ffmpeg_locator_test.dart` / `test/video_compressor_test.dart` / `test/process_priority_test.dart` / `test/config_test.dart` - new suites
- `ecom-flutter/test/database_test.dart` - 3 added compression persistence tests

## Decisions Made

- **Priority mechanism:** post-spawn `SetPriorityClass` via raw `dart:ffi` kernel32 bindings (win32 6.3.0 exposes the constants but not the function), chosen over a `cmd /c start /low` wrapper to keep argument-list spawning (no shell quoting, T-03-01), drainable pipes, and direct exit codes. Tradeoff: the child runs a few ms at default priority before being lowered - documented in `process_priority.dart`.
- **Atomic swap is stricter than ecom-py:** backup-rename sequence instead of delete-then-rename, plus an empty-output guard (`exit 0` + 0-byte file → `failed`, original kept) that ecom-py lacks.
- **Discovery by file existence, not `-version` spawn:** avoids child processes and hang risk during lookup; a corrupt binary surfaces as a failed job instead.
- **Console-window behavior deferred:** Dart's `Process.start` exposes no CREATE_NO_WINDOW flag; whether a console flashes on real hardware is unverifiable here (FFmpeg not installed). The injectable `ProcessStarter` seam makes an FFI `CreateProcess` starter a drop-in replacement if Phase 5's hardware check needs it.

## Deviations from Plan

None - plan executed as written.

## Issues Encountered

- `flutter analyze` flagged the initial `if (x != null) 'k': x` map entries in `updateCompressionStatus` (`use_null_aware_elements`); rewrote with Dart's `'k': ?x` null-aware marker.
- `package:meta` is not a direct dependency; imported `visibleForTesting` from `package:flutter/foundation.dart` instead to satisfy `depend_on_referenced_packages`.
- Pre-existing worktree drift (transitive pubspec.lock bumps from `flutter pub get`, CRLF churn in generated `windows/flutter/*` files) left uncommitted deliberately - environment-caused, not part of this plan.

## User Setup Required

None for the test suite. End-to-end verification (a real recording actually compressed, priority visible in Task Manager, no console flash) requires FFmpeg installed on the target machine - deferred to on-hardware validation.

## Next Phase Readiness

- **Phase 2 merge wiring needed** (flagged, not done here to keep the merge clean): construct `VideoCompressor` in `main.dart` with an `onComplete` that calls `database.updateCompressionStatus(...)`, call `compressor.start()`, call `queueCompression(path, transactionId, CompressionSettings.fromConfig(config))` after each save (and `updateCompressionStatus(id, 'processing')` when a job starts, as ecom-py's app_gui does), and slot `CompressionStatusIndicator(compressor: ...)` into the status panel.
- `FfmpegLocator` contract matches the Phase-2 worktree's file byte-for-byte in its public API; whichever copy survives the merge satisfies both consumers.
- Phase 4's settings dialog gets `compressionEnabled`/`compressionCodec`/`compressionCrf`/`compressionPreset`/`compressionDeleteOriginal`/`compressionPriority` getters and `FfmpegLocator.findFfmpeg()` for the live found/not-found readout (SET-06).
- Phase 5 packaging: bundle FFmpeg under `ffmpeg/bin/` beside the exe (the first-priority search location) or surface its absence; verify console-window behavior with a real FFmpeg run.

---
*Phase: 03-compression-pipeline*
*Completed: 2026-07-13*

## Self-Check: PASSED

All created files verified present on disk (ffmpeg_locator.dart, video_compressor.dart, process_priority.dart, compression_status_indicator.dart + 4 test suites); all five task commits (`413bc62`, `09ccf11`, `2556720`, `7966ba9`, `0aee173`) verified in git log; final gate re-run: `flutter analyze` clean, `flutter test` 63/63 passing; `git diff HEAD -- lib/ui/main_screen.dart lib/main.dart` empty (Phase-2-owned files untouched).
