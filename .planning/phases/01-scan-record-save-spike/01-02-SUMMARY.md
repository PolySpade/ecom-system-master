---
phase: 01-scan-record-save-spike
plan: 02
subsystem: desktop-app
tags: [flutter, dart, hardwarekeyboard, window_manager, camera, barcode-input]

# Dependency graph
requires: ["01-01"]
provides:
  - "GlobalBarcodeListener: top-level HardwareKeyboard handler with 100ms inter-key debounce buffer, injectable clock for unit testing, consumes only the flushing Enter"
  - "useHardwareKeyboardBarcodeListener toggle in main.dart selecting between the HardwareKeyboard mechanism and a Focus-wrapper fallback (both routed through the same GlobalBarcodeListener.handleKeyEvent buffer logic), for Plan 03's hardware checkpoint to decide"
  - "MainScreen wiring: scanned barcodes route into the same _submitBarcode/processBarcode path as manual entry (BAR-02)"
  - "CameraService.aspectRatio getter for preview scaling"
  - "800x600 minimum window size via window_manager, scaling AspectRatio preview, conditional red RECORDING:{filename}[{label}] overlay sourced from cameraService.currentFilename/currentLabel"
affects: ["01-03"]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Injectable clock (DateTime Function()) on GlobalBarcodeListener so debounce/timeout logic is unit-testable without real delays"
    - "Single buffer/flush implementation (handleKeyEvent) shared by both the primary HardwareKeyboard mechanism and the Focus-wrapper fallback, toggled by a documented const flag rather than duplicated logic"
    - "Conditional (not always-present-hidden) Stack overlay for recording state, matching PATTERNS.md's camera panel convention"

key-files:
  created:
    - ecom-flutter/lib/core/barcode_listener.dart
    - ecom-flutter/test/barcode_listener_test.dart
  modified:
    - ecom-flutter/lib/main.dart
    - ecom-flutter/lib/ui/main_screen.dart
    - ecom-flutter/lib/core/camera_service.dart

key-decisions:
  - "Renamed the initially-@visibleForTesting handleKeyForTest method to a public handleKeyEvent, since it is genuinely used in production by the Focus-wrapper fallback path in main.dart (not test-only) - avoids a misleading @visibleForTesting annotation on a method the app itself calls."
  - "windows/runner/main.cpp left unchanged: its generated initial window size (1280x720) already exceeds the 800x600 minimum and matches main.dart's _kInitialWindowSize, so no edit was needed to satisfy the plan's 'if smaller than 800x600' condition."

requirements-completed: [BAR-01, BAR-02, CAM-02, CAM-03]

# Metrics
duration: 24min
completed: 2026-07-11
---

# Phase 01 Plan 02: Keyboard-Wedge Capture + Scaling Preview Summary

**Top-level `HardwareKeyboard`-handler barcode listener with a 100ms debounce buffer and a toggle-selectable `Focus`-wrapper fallback (both sharing one buffer implementation), plus an 800x600-minimum, aspect-ratio-scaling preview with a conditional red RECORDING overlay sourced from `CameraService`'s single source of truth.**

## Performance

- **Duration:** 24 min
- **Completed:** 2026-07-11
- **Tasks:** 2
- **Files modified:** 5 (2 created, 3 modified)

## Accomplishments

- Implemented `GlobalBarcodeListener` (`ecom-flutter/lib/core/barcode_listener.dart`): a `StringBuffer` + `_lastKeyTime` + `Duration(milliseconds: 100)` inter-key timeout, an injectable clock (`DateTime Function()`, defaulting to `DateTime.now`) so the debounce/flush logic is fully unit-testable on Linux without real delays. Only `KeyDownEvent` is processed; the flushing Enter is consumed (`true`) while character keys are not (`false`), matching T-01-05's mitigation.
- Wired `GlobalBarcodeListener` into `main.dart` at app root, installed after the widget tree is built and disposed on teardown, gated by a documented `useHardwareKeyboardBarcodeListener` const toggle. When `false`, a root `Focus` widget (`autofocus: true`) routes key events through the exact same `handleKeyEvent` buffer/debounce logic via a `FocusNode` main.dart keeps alive - so switching mechanisms for Plan 03's hardware decision requires flipping one constant, not rewriting logic.
- Routed scanner-sourced barcodes into the identical `_submitBarcode`/`processBarcode` code path manual TextField/Submit entry already uses (BAR-02) - `MainScreen._handleScannedBarcode` populates the same `_barcodeController` and calls `_submitBarcode()`, so there is exactly one `processBarcode` implementation in the codebase (verified via grep).
- Added `_reclaimRootFocus()` in `MainScreen`, called after every dialog closes, which calls `rootFocusNode?.requestFocus()` - a no-op under the primary `HardwareKeyboard` mechanism, but reclaims root focus for the `Focus`-wrapper fallback after a modal closes.
- Enforced the 800x600 minimum window size (CAM-02) via `window_manager`: `WindowOptions(minimumSize: Size(800, 600), size: Size(1024, 768))`, applied through `windowManager.waitUntilReadyToShow` + `setMinimumSize` before the window is shown. Confirmed `windows/runner/main.cpp`'s generated initial size (1280x720) already exceeds the minimum, so no C++ edit was required.
- Added `CameraService.aspectRatio` (falls back to 4:3 pre-initialization) and wrapped the preview in `AspectRatio` inside `Center`/`LayoutBuilder` within the existing `Expanded` region, so the preview rescales continuously with window resizing without distortion (CAM-02).
- Rebuilt the RECORDING overlay (CAM-03) to be genuinely conditional - absent from the `Stack`'s widget tree entirely while idle, not always-present-and-hidden - and to read `"RECORDING: {filename} [{label}]"` exclusively from `cameraService.currentFilename`/`cameraService.currentLabel` (the single source of truth from Plan 01-01 Task 3), guarding against `filename == null`. Added a small white dot badge alongside the text.

## Task Commits

1. **Task 1: Global keyboard-wedge barcode listener with debounce buffer + Focus-wrapper fallback** - `a7d4a64` (feat)
2. **Task 2: Minimum-size scaling preview + red RECORDING overlay** - `2aed49a` (feat)

**Plan metadata:** committed alongside this SUMMARY (see final commit)

## Files Created/Modified

- `ecom-flutter/lib/core/barcode_listener.dart` - `GlobalBarcodeListener`: install/dispose lifecycle, injectable-clock debounce buffer, `handleKeyEvent` shared by both the primary and fallback mechanisms
- `ecom-flutter/test/barcode_listener_test.dart` - 7 pure-Dart unit tests covering buffer/flush/debounce/consume-semantics/KeyDown-only filtering
- `ecom-flutter/lib/main.dart` - `useHardwareKeyboardBarcodeListener` toggle, `GlobalBarcodeListener` construction/install/dispose, root `Focus` fallback wrapper, `window_manager` `WindowOptions`/`setMinimumSize` setup
- `ecom-flutter/lib/ui/main_screen.dart` - scanned-barcode routing into `_submitBarcode`, `_reclaimRootFocus`, `AspectRatio`-scaling preview, conditional RECORDING overlay reading `cameraService.currentFilename`/`currentLabel`
- `ecom-flutter/lib/core/camera_service.dart` - new `aspectRatio` getter

## Decisions Made

- Renamed the originally `@visibleForTesting`-annotated `handleKeyForTest` to a plain public `handleKeyEvent`: the plan's own Focus-wrapper fallback design calls this method from production code (`main.dart`'s `_handleRootFocusKeyEvent`), so marking it test-only would have been misleading. This keeps the single-implementation guarantee (both mechanisms share one buffer/flush code path) explicit in the API surface.
- Left `windows/runner/main.cpp` unmodified - its generated initial window size (`Win32Window::Size size(1280, 720)`) already exceeds 800x600 and matches `main.dart`'s `_kInitialWindowSize`, satisfying the plan's conditional instruction ("if the generated default is smaller than 800x600") without needing an edit.

## Deviations from Plan

None - plan executed as written. The `handleKeyForTest` -> `handleKeyEvent` rename and the no-op verification of `main.cpp`'s window size are both within the plan's own stated design (the plan explicitly asks for a fallback usable by production code, and explicitly conditions the `main.cpp` edit on the generated size being too small), not deviations from it.

## Issues Encountered

None. `flutter analyze` and the full `flutter test` suite (29 tests: 7 new `barcode_listener_test.dart` + 22 carried over from Plan 01-01) both passed clean on the first attempt after one minor lint fix (an unnecessary `services.dart` import in `main.dart`, corrected before commit) and one `use_null_aware_elements` lint fix (`if (overlay != null) overlay` -> `?overlay` in a collection literal).

## User Setup Required

None - all work in this plan is Linux-verifiable (`flutter analyze`, `flutter test`). Per the plan's own scope, hardware focus-independence verification (scan while idle / TextField focused / dialog open, and the choice between the `HardwareKeyboard` mechanism vs. the `Focus`-wrapper fallback) is explicitly deferred to Plan 03's Windows hardware checkpoint - not automatable here.

## Next Phase Readiness

- `GlobalBarcodeListener` is fully built and unit-tested; Plan 03 only needs to run the app on the target Windows machine with real scanner hardware and decide which of the two mechanisms (`useHardwareKeyboardBarcodeListener = true/false`) actually works, per RESEARCH.md Pitfall 2 / Flutter issue #160786.
- The 800x600 minimum window size, scaling preview, and RECORDING overlay are all implemented and `flutter analyze`-clean; visual confirmation on Windows (resize behavior, overlay appearance/disappearance) is Plan 03's responsibility per this plan's own `<done>` criteria.
- No blockers identified. The two genuinely open upstream questions this phase exists to resolve (keyboard focus-independence, and `stopVideoRecording()`/`startVideoRecording()` back-to-back reliability from Plan 01-01) both remain correctly deferred to Plan 03's hardware spike tasks.

---
*Phase: 01-scan-record-save-spike*
*Completed: 2026-07-11*
