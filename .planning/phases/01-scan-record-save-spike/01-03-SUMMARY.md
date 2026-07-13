---
phase: 01-scan-record-save-spike
plan: 03
subsystem: desktop-app
tags: [flutter, windows, hardware-validation, camera_windows, release-build, spike]

# Dependency graph
requires: ["01-01", "01-02"]
provides:
  - "A2 CONFIRMED: camera_windows stop->start back-to-back is reliable with a measured ~115 ms gap (stop_method=barcode, no exceptions, no corrupt files) — camera_desktop fallback NOT needed"
  - "A1 CONFIRMED: primary top-level HardwareKeyboard handler captures real scanner input on Flutter 3.44.6 (useHardwareKeyboardBarcodeListener stays true; Focus fallback never toggled)"
  - "A3 CONFIRMED: availableCameras() enumerates the target webcam by usable name ('4K Camera'); win32/DirectShow registry fallback NOT needed in Phase 1"
  - "Release build opens the WAL SQLite DB and writes transactions from the Release folder (sqlite3 3.3.4 bundled DLL works)"
  - "Recorded codec captured for Phase 3: H.264 (avc1) in MP4 (ftyp mp42), video-only"
affects: ["02", "03"]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "MP4-box byte inspection as an ffprobe substitute when FFmpeg tooling is absent on the target machine"
    - "Release smoke test via synthesized keyboard events (SendKeys) against the exe launched from the Release folder"

key-files:
  created:
    - ecom-flutter/SPIKE_RESULTS.md
  modified: []

key-decisions:
  - "camera_windows 0.2.6+4 retained as the recording backend; camera_desktop fallback rejected as unnecessary (A2 passed with ~115 ms stop->start gap over repeated real-scanner cycles in both debug and release builds)"
  - "useHardwareKeyboardBarcodeListener remains true permanently; the Focus-wrapper fallback stays in the codebase but dormant (issue #160786 did not reproduce on 3.44.6)"
  - "Target environment is Flutter 3.44.6 (not the 3.41.6 assumed in RESEARCH.md) on Windows 11 25H2 with VS Build Tools 2026; Developer Mode is a documented machine prerequisite for plugin symlinks"

requirements-completed: [REC-02, BAR-01, CAM-01, CAM-02, CAM-03, SET-01, DB-01, DB-02, STO-01, LOG-01]

# Metrics
duration: ~45min (hardware session, 2026-07-13)
completed: 2026-07-13
---

# Phase 01 Plan 03: Windows Hardware Validation Spike Summary

**All three phase-critical assumptions (A1 keyboard focus-independence, A2 back-to-back recording, A3 camera enumeration) CONFIRMED on the real target Windows 11 machine with a real Bluetooth keyboard-wedge scanner and the target "4K Camera" webcam — plus release-build WAL DB smoke test PASS and codec (H.264/avc1 in mp42) captured for Phase 3.**

## Performance

- **Duration:** ~45 min operator-driven hardware session + automated verification
- **Completed:** 2026-07-13
- **Tasks:** 4 human-gated checkpoints, all passed

## Checkpoint Results

1. **Task 1 (hardware + debug build):** Flutter 3.44.6/Dart 3.12.2 installed at `C:\Users\Donald\develop\flutter`; VS Build Tools 2026 detected; Developer Mode had to be enabled for plugin symlinks. `flutter pub get` resolved transitive `sqlite3` at **3.3.4** (>= 3.0.0 required — PASS). App launched via `flutter run -d windows`; preview renders continuously. Hardware: generic USB **"4K Camera"** webcam, generic **Bluetooth HID keyboard-wedge scanner** (auto-types + Enter).
2. **Task 2 (back-to-back loop, REC-02):** Real scanner chains produced `stop_method=barcode` transitions with a measured stop->start gap of **114/115/116 ms** across consecutive cycles, zero PlatformExceptions, all MP4s non-zero (1.0-10.8 MB) with plausible durations, correct `videos/YYYY-MM-DD/Normal/` layout, matching DB rows and log lines. **camera_desktop fallback not needed.**
3. **Task 3 (focus-independence, BAR-01):** Scanner input drove the loop via the **primary HardwareKeyboard handler** (`useHardwareKeyboardBarcodeListener = true`); operator reports scanning worked throughout, including alongside the TextField. Issue #160786 did not reproduce on 3.44.6. (Caveat recorded in SPIKE_RESULTS.md: the 3-state focus matrix was confirmed in aggregate by operator report, not as three individually logged checks.)
4. **Task 4 (enumeration, overlay, resize, codec, release):** Camera enumerates as "4K Camera"; 800x600 minimum enforced with rescaling preview; RECORDING overlay appears/disappears correctly. Codec = **H.264 (avc1) in MP4 (mp42)**, video-only (via MP4-box inspection; ffprobe absent from the machine). Release exe run directly from the Release folder opened the WAL DB, wrote 3 transactions, and recorded videos — **Pitfall 5 PASS**.

## Files Created/Modified

- `ecom-flutter/SPIKE_RESULTS.md` — full empirical findings, requirement verdicts, and A1/A2/A3 CONFIRMED markings

## Decisions Made

- **Keep `camera_windows`** — the highest-risk unknown of the whole project resolved positively; no backend swap, no fresh pub.dev audit needed (threat T-01-SC not triggered).
- **Keep the primary HardwareKeyboard mechanism** — Focus fallback stays dormant in the codebase as insurance.
- **Flutter 3.44.6 is the validated baseline** (RESEARCH.md assumed 3.41.6; all findings apply to 3.44.6).

## Deviations from Plan

- The spike ran on the developer's own Windows 11 machine with Claude Code executing the automatable steps directly (build, log/DB verification, codec capture, release smoke test), rather than the all-manual flow the plan assumed from a Linux dev environment. Human checkpoints (scanning, visual verification) were still operator-performed.
- ffprobe is not installed on the machine; codec was captured by direct MP4-box byte inspection instead (same data recorded). FFmpeg/ffprobe installation or bundling becomes a Phase 3 prerequisite.
- The scanner is Bluetooth HID rather than USB — identical at the keyboard-event level; noted in SPIKE_RESULTS.md per A4.

## Issues Encountered

- Windows Developer Mode was initially off, blocking plugin symlink creation during `flutter pub get`/build — enabled by the operator; documented as a machine-setup prerequisite.
- Early testing only exercised the manual Stop button (13 cycles, `stop_method=manual`); the critical stop-and-start path had to be explicitly re-tested with chained scans — worth remembering for Phase 5 soak-test instructions (test scripts must specify "scan while recording, don't press Stop").
- Killing the release exe mid-recording left an in-flight transaction incomplete and its video unfinalized — expected, and direct empirical justification for Phase 2's UI-02 exit-confirmation requirement.

## Next Phase Readiness

- Phase 1 success criteria all TRUE; Phase 2 (Full Recording Workflow) is unblocked with zero carried risk from the camera backend.
- Phase 2 should carry forward: UI-02 exit confirmation (validated data-loss scenario), watermarking (not yet implemented — camera_windows records raw frames, so burn-in strategy needs Phase 2 design), FFmpeg absence on the target machine (Phase 3 prerequisite).

---
*Phase: 01-scan-record-save-spike*
*Completed: 2026-07-13*
