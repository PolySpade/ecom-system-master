# Phase 01 Spike Results — Windows Hardware Validation (Plan 01-03)

Empirical findings from the real target Windows machine, resolving RESEARCH.md
Assumptions A1/A2/A3 and Pitfalls 1/2/3/4/5. Validated 2026-07-13.

## Test Environment

| Item | Value |
|------|-------|
| OS | Windows 11 Pro 25H2 (10.0.26200) |
| Flutter | 3.44.6 stable (Dart 3.12.2) — newer than the 3.41.6 the research assumed |
| Toolchain | Visual Studio Build Tools 2026 (18.7.3), Developer Mode enabled (required for plugin symlinks) |
| Webcam | Generic USB "4K Camera" (enumerated by that name) |
| Barcode scanner | Generic Bluetooth HID keyboard-wedge scanner (auto-types barcode + Enter) |
| camera_windows | 0.2.6+4 |
| sqlite3 (transitive) | 3.3.4 (Pitfall 5 requires >= 3.0.0 — PASS) |

Note (A4): the scanner is a Bluetooth HID wedge rather than USB; behavior is
identical at the keyboard-event level, but if packing stations later
standardize on a specific USB model, re-run the Task 3 focus matrix on it.

## A2 — Back-to-back stopVideoRecording() -> startVideoRecording() (REC-02, Core Value): CONFIRMED

Driven by real scanner input against the live camera (transactions 14-17,
2026-07-13 09:33 in `logs/app.log`):

- Chained scan-while-recording cycles completed with `stop_method=barcode`,
  no PlatformException, no 0-byte or corrupt files.
- Measured stop -> next-start gap from log timestamps:
  - 09:33:04.163 -> 09:33:04.279 = **116 ms**
  - 09:33:06.198 -> 09:33:06.312 = **114 ms**
  - 09:33:09.493 -> 09:33:09.608 = **115 ms**
  - Gap is consistent at **~115 ms** (stop is awaited sequentially before the
    new start, matching ecom-py orchestration).
- An additional 13 start/stop cycles via the manual Stop button (transactions
  1-13, 2026-07-11 and 2026-07-13) all saved correctly: every MP4 non-zero
  (1.0-7.7 MB), plausible durations vs wall clock, plays back correctly per
  operator verification.
- Videos land in `videos/YYYY-MM-DD/Normal/YYYYMMDD_HHMMSS_BARCODE.mp4`
  (STO-01 PASS); every cycle wrote a matching transactions row (DB-01 PASS)
  and start/stop lines to `logs/app.log` (LOG-01 PASS).

**Decision: `camera_windows` retained. The `camera_desktop` fallback is NOT
needed.** (No fresh pub.dev legitimacy audit required per threat T-01-SC,
since no package swap occurred.)

## A1 — Focus-independent scanner capture on Flutter 3.44.6 (BAR-01, issue #160786): CONFIRMED

- Mechanism in effect: **primary top-level `HardwareKeyboard` handler**
  (`useHardwareKeyboardBarcodeListener = true` in `main.dart`). The
  `Focus`-wrapper fallback was never toggled on.
- Real scanner scans drove the full record loop end-to-end during the A2 test
  session; operator reports scanning worked throughout testing, including with
  the manual-entry TextField present ("all works").
- Caveat: the three-state focus matrix (idle / TextField focused / modal
  dialog open) was verified by operator report in aggregate rather than as
  three individually logged checks. The #160786 regression (top-level handler
  starved after TextField focus) did not manifest on 3.44.6.

## A3 — availableCameras() enumeration by name (SET-01): CONFIRMED

- The target webcam enumerates with the usable human-readable name
  "4K Camera" and initializes for preview + recording.
- Historical note: `app.log` 2026-07-11 18:54 shows
  `Bad state: No cameras available` from a session run before the webcam was
  connected — enumeration correctly reflects device presence, and the app
  surfaces the error rather than crashing.
- The win32/DirectShow registry fallback layer is NOT needed for Phase 1.

## CAM-01/02/03 — Preview, min-size, RECORDING overlay: PASS

- Live preview renders continuously in a resizable window; operator confirmed
  the 800x600 minimum is enforced and the preview rescales during resize.
- Red `RECORDING: {filename} [{label}]` overlay appears while recording and
  disappears on stop (observed across 17 recording cycles).

## Pitfall 4 — Recorded codec/container (Phase 3 planning data)

ffprobe is not installed on the target machine; codec identified by direct
MP4 box inspection of `20260713_093300_12211112.mp4`:

- Container brand: `ftyp mp42` (MP4)
- Video codec fourcc: `avc1` (**H.264/AVC**)
- No audio track fourcc found (video-only recording)

Phase 3 implication: FFmpeg re-encode from H.264 MP4 input is the standard
path (same as ecom-py's OpenCV output); no exotic codec handling needed.
FFmpeg/ffprobe must be bundled or installed for Phase 3 — not present on this
machine today.

## Pitfall 5 — Release-build DLL/WAL smoke test (DB-01/DB-02): PASS

- `flutter build windows --release` succeeded (74 s).
- Release exe launched **directly from `build/windows/x64/runner/Release/`**
  (not via `flutter run`): camera initialized, barcodes injected via
  synthesized keyboard events drove the full loop.
- WAL database opened and written from the release build: `database.db` +
  `database.db-wal`/`-shm` created beside the exe; 3 transactions created,
  2 completed with `stop_method=barcode` — the bundled sqlite3 DLL works.
- Back-to-back gap in release mode: ~115-126 ms (consistent with debug).
- Videos (5.2 MB / 10.8 MB) saved under `videos/2026-07-13/Normal/` beside
  the exe; `logs/app.log` written.
- Two incidental findings worth carrying to Phase 2:
  1. Killing the process mid-recording left transaction 3 incomplete and its
     video unfinalized — empirical confirmation that UI-02 (exit
     confirmation + stop-and-save on close) is required to prevent data loss.
  2. Synthesized keystrokes slower than the listener's 100 ms inter-key
     debounce split into multiple "barcodes" — expected behavior (real
     scanners burst much faster); the app handled the fragments gracefully.

## Requirement Verdicts

| Requirement | Verdict |
|-------------|---------|
| REC-02 back-to-back stop-and-start | PASS (~115 ms gap, stop_method=barcode) |
| BAR-01 focus-independent scanner capture | PASS (primary HardwareKeyboard handler) |
| CAM-01 continuous preview | PASS |
| CAM-02 resizable window, 800x600 min | PASS |
| CAM-03 RECORDING overlay | PASS |
| SET-01 camera enumeration by name | PASS ("4K Camera") |
| STO-01 videos/YYYY-MM-DD/label/ layout | PASS |
| DB-01/DB-02 WAL SQLite transactions | PASS (debug AND release builds) |
| LOG-01 logs/app.log | PASS |
