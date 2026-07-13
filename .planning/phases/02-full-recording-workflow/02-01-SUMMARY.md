---
phase: 02-full-recording-workflow
plan: 01
subsystem: desktop-app
tags: [flutter, dart, ffmpeg, drawtext, watermark, win32, disk-space, window_manager, scan-queue]

# Dependency graph
requires: ["01-01", "01-02"]
provides:
  - "FfmpegLocator with the exact shared contract findFfmpeg()/findFfprobe() (bundled ffmpeg/bin beside exe -> common install paths -> PATH, process-lifetime cache, resetCache for tests/Settings refresh) - Phase 3's compression pipeline builds against this same file"
  - "WatermarkService: serialized post-save FFmpeg drawtext re-encode (running timestamp top-left via pts:localtime seeded with recording-start epoch, label top-right on 0x667eea box, Barcode: X bottom-left), temp-file + backup swap that can never lose the original, graceful skip (logged warning) when FFmpeg or a font is missing; enqueue() returns a Future Phase 3 chains compression onto"
  - "ScanQueue: serialized single-flight lane for barcode submissions + submitAction for manual stop / exit-time stop - scans arriving during a save are queued in order, never dropped (REC-04)"
  - "CameraService auto-reinit (CAM-04): 2s health monitor, consecutive-failure counter, 5s cooldown, non-reentrant guard, in-progress-recording salvage via onRecordingSalvaged; StopRecordingResult extended with videoPath/barcode/label/startTime; rename-first plugin-output move"
  - "disk_space.dart: Win32 GetDiskFreeSpaceEx probe + pure evaluateDiskSpace (critical/low/ok) against config storage.min_free_space_gb (STO-02)"
  - "resolveVideoPath in file_paths.dart: labeled layout -> legacy pre-label fallback -> absolute passthrough (STO-03, legacy ecom-py archives + Phase-1 spike rows)"
  - "MainScreen full UI: label dropdown, non-dismissible Saving Recording... dialog, System Status panel (state/file/MM:SS/storage/compression placeholder), last-10 recordings with Open File + Show in Folder, 5s auto-clear status bar, onWindowClose confirm-stop-save-exit, #667EEA-seeded theme"
affects: ["03", "04"]

# Tech tracking
tech-stack:
  added: ["ffi ^2.1.0 (direct dependency for calloc/toNativeUtf16 alongside existing win32)"]
  patterns:
    - "Serialized worker via Future-chaining tail (WatermarkService._tail) instead of an isolate/queue primitive - one FFmpeg process at a time, mirroring ecom-py's single compression worker thread"
    - "Injectable collaborators (findFfmpeg/runProcess/findFont function params) on WatermarkService so the swap/skip/failure paths are unit-testable without FFmpeg"
    - "Drain-loop queue (ScanQueue) serializing all recording mutations (scans, manual stop, exit stop) on one lane"
    - "Pure decision function + thin Win32 probe split (evaluateDiskSpace vs getFreeSpaceGb) so threshold logic tests need no FFI"

key-files:
  created:
    - ecom-flutter/lib/core/ffmpeg_locator.dart
    - ecom-flutter/lib/core/watermark_service.dart
    - ecom-flutter/lib/core/disk_space.dart
    - ecom-flutter/lib/core/scan_queue.dart
    - ecom-flutter/test/watermark_service_test.dart
    - ecom-flutter/test/ffmpeg_locator_test.dart
    - ecom-flutter/test/disk_space_test.dart
    - ecom-flutter/test/scan_queue_test.dart
  modified:
    - ecom-flutter/lib/core/camera_service.dart
    - ecom-flutter/lib/core/config.dart
    - ecom-flutter/lib/core/file_paths.dart
    - ecom-flutter/lib/main.dart
    - ecom-flutter/lib/ui/main_screen.dart
    - ecom-flutter/test/file_paths_test.dart
    - ecom-flutter/pubspec.yaml

key-decisions:
  - "Watermark implemented as a post-save FFmpeg drawtext re-encode (camera_windows exposes no per-frame access); running timestamp uses %{pts:localtime:START_EPOCH} so it advances during playback like ecom-py's per-frame stamps; label/barcode overlays use expansion=none to disable % expansion on operator text"
  - "Label box color set to #667eea (the intended brand color): ecom-py passes (102,126,234) to cv2 which interprets tuples as BGR, so the reference actually renders orange-ish - the port follows the evident intent (#667eea appears throughout the reference UI) rather than reproducing the BGR bug"
  - "DB video_filename now stores the basename (ecom-py parity - Phase 1 stored full paths); resolveVideoPath handles all three layouts: labeled, legacy pre-label, and absolute Phase-1 spike rows"
  - "storage.min_free_space_gb defaults to 1.0 GB: ecom-py has no free-space guard at all (MAX_STORAGE_GB=500 is dead code), so a conservative new configurable floor was chosen; a failed probe evaluates to ok so a broken Win32 call can never block recording"
  - "Watermarking is skipped when stopping-and-saving during app exit (the closing app would kill FFmpeg mid-write); the video itself is always saved"
  - "For stopAndStart under critical disk space, the previous recording is still stopped and saved - only the new start is blocked (never lose the in-progress video)"
  - "Win32 6.x API shape: GetDiskFreeSpaceEx takes PCWSTR (extension type over Pointer<Utf16>) and returns Win32Result<bool> - consumed via PCWSTR(ptr) and result.value"

requirements-completed: [REC-04, REC-06, REC-07, CAM-04, CAM-05, STO-02, STO-03, DB-03, UI-01, UI-02, UI-03, UI-04]

# Metrics
duration: 35min
completed: 2026-07-13
---

# Phase 02 Plan 01: Full Recording Workflow Summary

**Non-blocking saves behind a serialized scan queue and a non-dismissible progress dialog, Video Label routing into folder/DB/watermark, post-save FFmpeg drawtext watermarks that can never lose the original, cooldown-guarded camera auto-reinit with recording salvage, a Win32 disk-space guard, exit confirmation that stops-and-saves, and the full purple-themed main window (status panel, recent list with Explorer actions, auto-clearing status bar).**

## Performance

- **Duration:** ~35 min
- **Completed:** 2026-07-13
- **Tasks:** 4 feature commits + docs
- **Files modified:** 15 (8 created, 7 modified)

## Accomplishments

- **REC-04 non-blocking save + scan queueing:** `_stopAndSave` runs behind a non-dismissible `PopScope(canPop:false)` "Saving Recording..." dialog; all recording mutations (scans, manual stop, exit stop) flow through a new `ScanQueue` drain loop so a scan arriving mid-save is queued in arrival order and processed next - verified by unit tests that hold a save open with a `Completer` while two more scans arrive. The plugin-output move now renames first (instant on the same volume) instead of copying.
- **REC-06/STO-02/DB-03 labels:** dropdown with the exact three ecom-py options (default "Normal (Standard)"), captured at submit time; folder routing already matched ecom-py's map ("Return and Refund", "Return Parcel", "Normal"); DB rows store the label and now the file basename (ecom-py parity).
- **Watermark (CAM-05 via post-save step):** `WatermarkService` re-encodes the saved file with three drawtext overlays matching ecom-py's layout - running timestamp top-left (`%{pts\:localtime\:EPOCH}`, default format `%Y-%m-%d %H:%M:%S` matches the reference strftime), label top-right on a #667eea box, `Barcode: X` bottom-left, white text on dark boxes. Output goes to a `.wm_tmp.mp4`, then original -> `.wm_bak` -> tmp -> original -> delete bak, restoring the backup on any swap failure. Missing FFmpeg or font logs a warning and leaves a valid unwatermarked video. Jobs serialize via Future-chaining; `enqueue()` returns the outcome Future Phase 3 chains compression onto.
- **FfmpegLocator contract:** exactly `class FfmpegLocator { static Future<String?> findFfmpeg(); static Future<String?> findFfprobe(); }` searching bundled `ffmpeg/bin/` (plus `ffmpeg/` and the exe dir, per ecom-py), `C:\ffmpeg\bin`, Program Files (x86 too), `~\ffmpeg\bin`, then PATH via `where`.
- **CAM-04 auto-reinit:** 2s health monitor checks `controller.value.isInitialized && !hasError`; on failure, a consecutive counter increments and reinit runs behind a 5s cooldown and non-reentrant flag (ports `_try_reinitialize_camera`). If the camera dies mid-recording, the service attempts a salvage stop and reports it via `onRecordingSalvaged` so MainScreen completes the DB row with `stop_method='camera_failure'` and still watermarks the saved file. The preview shows a "Camera unavailable - reconnecting..." placeholder during reinit.
- **STO-02 disk guard:** `getFreeSpaceGb` (Win32 `GetDiskFreeSpaceEx`, falling back to the volume root for not-yet-created paths) + pure `evaluateDiskSpace`: block with a dialog below `storage.min_free_space_gb` (default 1.0), warn on the status bar below 5x. Checked before every recording start, including the start half of stop-and-start (the stop/save always proceeds).
- **REC-07/UI-02 exit confirmation:** `setPreventClose(true)` at startup; `onWindowClose` destroys immediately when idle, otherwise shows "A recording is in progress. Stop and exit?" and, on confirm, stops-and-saves on the serialized lane (completing the DB transaction) before `windowManager.destroy()`.
- **UI-01/UI-03/UI-04 main window:** System Status card (Status / Current File / MM:SS Duration ticker / Storage Used via `getTotalStorageUsed()` on a 1s timer / Compression line fed by the watermark queue as the Phase-3 placeholder), Recent Recordings card (last 10: barcode, label, start time, duration, size, compression text, Open File + `explorer.exe /select,` Show in Folder via `resolveVideoPath` with legacy fallback), bottom status bar auto-clearing to "Ready" after 5s, and `ColorScheme.fromSeed(seedColor: Color(0xFF667EEA))` with #10b981/#dc2626 accents on the ready dot / Stop button.

## Task Commits

1. **FFmpeg locator + watermark pipeline** - `7fbc086` (feat)
2. **Camera auto-reinit + richer stop result** - `cdb46ba` (feat)
3. **Disk-space guard** - `416aeb2` (feat)
4. **Full main window + scan queue + exit confirm** - `7306e0d` (feat)

**Plan metadata:** committed alongside this SUMMARY (see final commit)

## Files Created/Modified

- `ecom-flutter/lib/core/ffmpeg_locator.dart` - shared FFmpeg/ffprobe discovery contract (Phase 3 dependency)
- `ecom-flutter/lib/core/watermark_service.dart` - serialized drawtext watermark worker + pure filter/args builders
- `ecom-flutter/lib/core/disk_space.dart` - Win32 free-space probe + pure threshold evaluation
- `ecom-flutter/lib/core/scan_queue.dart` - serialized scan/action lane (REC-04 queueing)
- `ecom-flutter/lib/core/camera_service.dart` - auto-reinit, salvage, extended StopRecordingResult, rename-first move
- `ecom-flutter/lib/core/config.dart` - `storage.min_free_space_gb` default + getter
- `ecom-flutter/lib/core/file_paths.dart` - `resolveVideoPath` labeled/legacy/absolute resolution
- `ecom-flutter/lib/main.dart` - #667EEA theme seed, setPreventClose, WatermarkService wiring, health monitor start
- `ecom-flutter/lib/ui/main_screen.dart` - full main-window rewrite (dialog, queue, panels, list, status bar, exit)
- `ecom-flutter/test/*` - 35 new unit tests (watermark 14, scan queue 5, disk 7, ffmpeg locator 3, resolveVideoPath 5, plus carried tests updated)
- `ecom-flutter/pubspec.yaml` - added `ffi`

## Decisions Made

- **Watermark approach:** post-save FFmpeg re-encode (libx264, CRF 18, veryfast) rather than per-frame drawing - camera_windows owns the capture pipeline natively and exposes no frame hook. `pts:localtime` seeded with the recording-start epoch reproduces the reference's advancing per-frame timestamps in a single pass. The step is structured as a serialized queue whose `enqueue()` Future is the Phase-3 chaining point.
- **Brand color over BGR bug:** ecom-py's label box tuple `(102,126,234)` is BGR in OpenCV, rendering ~orange; the port uses the evident intent, #667eea.
- **Basename in DB:** switched `video_filename` from Phase 1's full path to the basename for ecom-py archive compatibility; `resolveVideoPath` keeps old spike rows and legacy pre-label ecom-py layouts playable.
- **Disk threshold:** new `storage.min_free_space_gb` (1.0 GB default) because ecom-py has no free-space guard to inherit; probe failure never blocks.
- **Exit skips watermarking:** the saved video is preserved; running FFmpeg during shutdown would be killed mid-write.

## Deviations from Plan

None from this plan's own scope. One environmental note: the task brief referenced `ecom-flutter/SPIKE_RESULTS.md` and a completed Phase-1 hardware spike (01-03); neither exists in this worktree (ROADMAP shows 01-03 unchecked). Work proceeded against the Phase-1 code that does exist; nothing in this plan depended on the spike file's contents beyond decisions already baked into the codebase (camera plugin retained, HardwareKeyboard listener default).

## Issues Encountered

- win32 6.3.0's modernized API: `GetDiskFreeSpaceEx` takes a `PCWSTR` extension type and returns `Win32Result<bool>` instead of an int - fixed by wrapping the pointer (`PCWSTR(ptr)`) and checking `result.value`. Only analyze failure of the session; everything else passed first run.
- No FFmpeg is installed on the dev machine, so the drawtext filter could not be executed end-to-end here (construction is unit-tested against FFmpeg's documented quoting rules; see Next Phase Readiness).

## User Setup Required

- Install FFmpeg (or place it in `ffmpeg/bin/` beside the executable) on the target machine to get watermarked output; without it videos save unwatermarked with a logged warning.

## Next Phase Readiness

- **Phase 3 compression** can build directly against `FfmpegLocator.findFfmpeg()/findFfprobe()` and chain onto `WatermarkService.enqueue()`'s returned Future; the status panel's Compression line is already wired to queue-state callbacks.
- **Hardware verification required (not automatable in this session):** (1) run one real recording through FFmpeg to confirm the drawtext filter renders all three overlays and the running timestamp (no FFmpeg on this machine); (2) unplug/replug the camera to confirm camera_windows surfaces `hasError`/uninitialized state that the health monitor can observe, and that reinit + mid-recording salvage behave; (3) confirm the saving dialog duration and scan-queue behavior under real back-to-back scanning; (4) confirm `onWindowClose` fires from the title-bar X with window_manager 0.5.2 and the stop-and-save completes before destroy.
- `flutter analyze` clean; full `flutter test` suite green (64 tests: 35 new + 29 carried).

---
*Phase: 02-full-recording-workflow*
*Completed: 2026-07-13*
