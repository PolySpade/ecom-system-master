---
phase: 04-search-and-settings
plan: 01
subsystem: desktop-app
tags: [flutter, dart, search, settings, sqlite, json-persistence, file_selector]

# Dependency graph
requires: ["01-01", "01-02"]
provides:
  - "SettingsManager: 5-category DEFAULT_SETTINGS (video/camera/storage/app/compression) mirroring ecom-py settings_manager.py, recursive deepMerge, indented human-editable settings.json persistence, typed getters (getVideoFps, getCameraIndex, ...)"
  - "Config refactored into a live projection over the shared SettingsManager - settings changes propagate to config getters without restart (Dart equivalent of reload_config)"
  - "AppDatabase.advancedSearch: barcode LIKE/label/DATE-range filters, whitelisted sort column + order, COUNT total + LIMIT/OFFSET, empty-result-on-error (port of ecom-py database.py advanced_search)"
  - "resolveVideoPath in file_paths.dart: label-folder path with legacy pre-label-folder date-root fallback (SRCH-06)"
  - "video_actions.dart: openVideo (cmd /c start) and showInFolder (explorer /select,) returning error strings instead of throwing"
  - "SearchScreen: filters, sort, result cards with color-coded badges, Play/Show-in-Folder, Showing X of Y footer, Esc/Ctrl+F/F5 shortcuts"
  - "SettingsScreen: Video/Camera/Storage tabs, non-blocking Refresh Cameras, persisted-but-annotated exposure controls, file_selector path pickers, Save & Apply with async camera reinit behind a non-dismissible progress dialog, Reset to Defaults, Cancel"
  - "CameraService.reinitialize(index, {resolutionPreset}) + resolutionPresetFor(width, height) mapper; init() gained an optional resolutionPreset parameter"
affects: ["02", "03", "05"]

# Tech tracking
tech-stack:
  added: ["file_selector 1.1.0 (publisher: flutter.dev)"]
  patterns:
    - "Config as a thin live delegate over SettingsManager (no cached copies) so Save & Apply propagates immediately"
    - "Sort columns interpolated into SQL only through a whitelist constant (matches ecom-py's valid_sort_columns defense)"
    - "Child screens opened via _openChildScreen: global scanner callback suspended during push, restored + root focus reclaimed + rebuild on pop"
    - "OS-shell handoff helpers return Future<String?> error messages (null = success) so UI callers decide dialog presentation"

key-files:
  created:
    - ecom-flutter/lib/core/settings_manager.dart
    - ecom-flutter/lib/core/video_actions.dart
    - ecom-flutter/lib/ui/search_screen.dart
    - ecom-flutter/lib/ui/settings_screen.dart
    - ecom-flutter/test/settings_manager_test.dart
    - ecom-flutter/test/advanced_search_test.dart
  modified:
    - ecom-flutter/lib/core/config.dart
    - ecom-flutter/lib/core/database.dart
    - ecom-flutter/lib/core/file_paths.dart
    - ecom-flutter/lib/core/camera_service.dart
    - ecom-flutter/lib/ui/main_screen.dart
    - ecom-flutter/lib/main.dart
    - ecom-flutter/pubspec.yaml
    - ecom-flutter/test/file_paths_test.dart

key-decisions:
  - "Exposure/gain/brightness sliders are persisted (settings.json parity) but annotated as unsupported: camera_windows has no manual exposure API; a Win32 IAMCameraControl/IAMVideoProcAmp FFI shim (SET-04 full parity) is deliberately NOT built now - known project blocker, flagged for later"
  - "Settings screen has Video/Camera/Storage tabs only: Compression tab is Phase 3 scope (SET-06) and the Web App tab does not apply to the Flutter port; the 'app' and 'compression' settings.json categories are preserved untouched so ecom-py can still read the file"
  - "resolveVideoPath uses p.basename(video_filename) so rows written by ecom-py (basename) and by the Phase-1 Flutter build (full path) both resolve"
  - "Reset to Defaults resets in-memory only without saving to disk, faithfully mirroring the reference's reset_to_defaults behavior"
  - "Scanner callback is suspended while Search/Settings screens are open so a keyboard-wedge scan cannot silently start a recording behind the child route"

requirements-completed: [SRCH-01, SRCH-02, SRCH-03, SRCH-04, SRCH-05, SRCH-06, SRCH-07, SRCH-08, SET-02, SET-03, SET-05, SET-07, SET-08]

# Metrics
duration: 35min
completed: 2026-07-13
---

# Phase 04 Plan 01: Search & Settings Summary

**Full SearchWindow and SettingsDialog ports: an `advancedSearch`-backed search screen with cards, badges, shortcuts, and legacy-path fallback, plus a `SettingsManager`-backed tabbed settings screen with live Config delegation and async camera reinit behind a progress dialog.**

## Performance

- **Duration:** 35 min
- **Completed:** 2026-07-13
- **Tasks:** 5
- **Files modified:** 14 (6 created, 8 modified)

## Accomplishments

- Ported `SettingsManager` (`ecom-flutter/lib/core/settings_manager.dart`) key-for-key from ecom-py: all five DEFAULT_SETTINGS categories (including `compression`, so a settings.json written by either app parses in both), a genuinely recursive `deepMerge` (the Phase-1 Config merge was shallow per-category), indented human-editable JSON on save, malformed-file fallback to defaults, and the full typed getter family (SET-07).
- Refactored `Config` into a thin live projection over the shared `SettingsManager` while keeping every Phase-1 call-site getter (`cameraIndex`, `videoStoragePath`, `fps`, ...) intact - Save & Apply changes propagate to config consumers immediately, the Dart equivalent of `config.reload_config()`.
- Added `AppDatabase.advancedSearch` mirroring ecom-py `advanced_search` exactly: partial case-insensitive barcode (`UPPER(barcode) LIKE UPPER(?)`), inclusive `DATE(created_at)` range, exact label match, whitelist-validated sort column/order (the column is interpolated, so the whitelist is the injection defense), COUNT total plus optional LIMIT/OFFSET, and the empty-result-on-error read contract (SRCH-01..04, SRCH-08).
- Added `resolveVideoPath` (SRCH-06): label-folder layout first, then the legacy pre-label-folder `videos/YYYY-MM-DD/<file>` layout - returned even when missing, so open-time "file not found" surfaces exactly like the reference.
- Built `SearchScreen` (SRCH-01..08): barcode field (Enter searches, autofocused), All Labels-default label dropdown, clearable calendar date pickers, the reference's five sort options, result cards with the exact reference badge colors (#dc2626 / #f59e0b / #10b981) and accent purple (#667eea), Play + Show-in-Folder actions via `video_actions.dart` (`cmd /c start` / `explorer /select,`), "Showing X of Y results" footer, and `CallbackShortcuts` for Esc/Ctrl+F/F5, limit 100.
- Built `SettingsScreen` (SET-02/03/05/08 + SET-04 partial): Video tab (5 resolution presets, 15/24/30/60 FPS, 4 codec options persisted for parity with a note that Media Foundation picks the actual encoder), Camera tab (enumeration by human-readable name, non-blocking Refresh Cameras with inline spinner, auto-exposure toggle + exposure/gain/brightness sliders persisted with a prominent unsupported-backend warning), Storage tab (three path editors with `file_selector` native folder/file pickers), and Reset to Defaults / Cancel / Save & Apply with capture-affecting-change detection triggering `CameraService.reinitialize` behind a non-dismissible progress dialog.
- Kept the Phase-2-contended diffs minimal: `camera_service.dart` gained only an optional `resolutionPreset` on `init`, a `reinitialize()` (guarded against mid-recording calls), and a top-level `resolutionPresetFor` mapper; `main_screen.dart` gained only two AppBar IconButtons, a `config` constructor param, and `_openChildScreen` (which suspends the global scanner callback while Search/Settings are open so a scan cannot start a recording behind the child route, then restores routing, reclaims root focus, and rebuilds).

## Task Commits

1. **Task 1: SettingsManager + Config delegation** - `900b685` (feat)
2. **Task 2: advancedSearch + legacy path resolution** - `5d0b35e` (feat)
3. **Task 3: Search screen + video actions** - `e8a7141` (feat)
4. **Task 4: Tabbed settings screen + CameraService.reinitialize** - `cd92bfb` (feat)
5. **Task 5: Main-screen AppBar entry points** - `c0ea517` (feat)

**Plan metadata:** committed alongside this SUMMARY (see final commit)

## Files Created/Modified

- `ecom-flutter/lib/core/settings_manager.dart` - SettingsManager: defaults, recursive deepMerge, JSON persistence, typed getters
- `ecom-flutter/lib/core/config.dart` - live delegation to SettingsManager, path resolution unchanged
- `ecom-flutter/lib/core/database.dart` - `AdvancedSearchResult` + `advancedSearch` with whitelisted sort
- `ecom-flutter/lib/core/file_paths.dart` - `resolveVideoPath` legacy fallback
- `ecom-flutter/lib/core/video_actions.dart` - `openVideo` / `showInFolder` shell handoff
- `ecom-flutter/lib/core/camera_service.dart` - `reinitialize`, `resolutionPresetFor`, `init` preset param
- `ecom-flutter/lib/ui/search_screen.dart` - SearchScreen (filters, cards, footer, shortcuts)
- `ecom-flutter/lib/ui/settings_screen.dart` - SettingsScreen (3 tabs + button row + reinit progress dialog)
- `ecom-flutter/lib/ui/main_screen.dart` - AppBar actions + `_openChildScreen` (minimal diff, merge attention)
- `ecom-flutter/lib/main.dart` - Config passed through; startup resolution mapped to camera preset
- `ecom-flutter/pubspec.yaml` - added `file_selector ^1.0.3` (resolved 1.1.0, publisher flutter.dev)
- `ecom-flutter/test/settings_manager_test.dart` - 17 tests: load/merge/malformed/persistence/mutation/Config delegation
- `ecom-flutter/test/advanced_search_test.dart` - 10 tests: filters/AND-combination/sorting/whitelist injection defense/pagination
- `ecom-flutter/test/file_paths_test.dart` - +5 tests for resolveVideoPath fallback semantics

## Decisions Made

- **SET-04 deliberately partial:** camera_windows exposes no manual exposure/gain/brightness API. The sliders exist, persist to settings.json, and are disabled while auto-exposure is on, with a prominent amber warning that live-apply is unsupported on this backend. The Win32 IAMCameraControl/IAMVideoProcAmp FFI shim was NOT built now per phase instructions - this remains the known blocker for full SET-04 parity.
- **No Compression or Web App tabs:** SET-06 (compression settings UI + FFmpeg status) is Phase 3's requirement; Flask settings don't apply to the port. Both settings.json categories round-trip untouched for cross-app compatibility.
- **Basename-based path resolution:** Phase 1's `main_screen` stores the full video path in `video_filename` while ecom-py stores the basename; `SearchScreen` resolves via `p.basename(...)` so both row shapes work. Recommend Phase 2 normalize to basename for full schema parity.
- **Reference-faithful Reset:** Reset to Defaults resets in-memory only (not saved to disk), exactly like `SettingsManager.reset_to_defaults()` + dialog-destroy in the reference.
- **Scanner suspension on child routes:** a keyboard-wedge scan while Search/Settings is open would otherwise flow into MainScreen's `_submitBarcode` and start a recording invisibly behind the route; the callback is swapped to a no-op during the push and restored on pop.

## Deviations from Plan

None - plan executed as written.

## Issues Encountered

- The sqflite ffi factory caches connections per path (singleInstance), so the advanced-search test's raw-insert helper initially closed the shared handle out from under `AppDatabase` (`database_closed` errors). Fixed by opening the helper connection with `singleInstance: false`. A stale `flutter_tester` process from that failed run also locked `build/native_assets/windows/sqlite3.dll` and had to be killed before re-running.

## User Setup Required

None for this plan's code. FFmpeg (user has an essentials build at `C:\Users\Donald\Downloads\ffmpeg-2026-07-09-git-8de8405796-essentials_build.7z`) is Phase 3's concern.

## Next Phase Readiness

- **Merge attention (Phase 2 conflicts likely):** `lib/ui/main_screen.dart` (AppBar `actions`, `config` param, `_openChildScreen`) and `lib/core/camera_service.dart` (`init` signature gained an optional named param, new `reinitialize`, new top-level `resolutionPresetFor`). Both diffs were kept as small and additive as possible. `lib/main.dart` also passes `config` into `MainScreen`/`EcomVideoTrackerApp`.
- Phase 3 can reuse: the `compression` settings category + `SettingsManager` getters pattern, and should add its Compression tab into `settings_screen.dart` (tab scaffolding is trivially extensible - bump `DefaultTabController.length`).
- Needs Windows visual/hardware verification (not automatable here): search card layout/shortcut behavior, date pickers, camera dropdown contents and Refresh Cameras, file_selector dialogs, Save & Apply reinit progress dialog and preview recovery after reinit, and Play/Show-in-Folder against real recordings (including a legacy pre-label-folder archive).

---
*Phase: 04-search-and-settings*
*Completed: 2026-07-13*

## Self-Check: PASSED

All created files verified present on disk (`settings_manager.dart`, `video_actions.dart`, `search_screen.dart`, `settings_screen.dart`, `settings_manager_test.dart`, `advanced_search_test.dart`); all five task commits (`900b685`, `5d0b35e`, `e8a7141`, `cd92bfb`, `c0ea517`) verified present in git log; `flutter analyze` clean and full `flutter test` suite (61 tests) passing at completion.
