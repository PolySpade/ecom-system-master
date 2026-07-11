# Ecom Video Tracker — Flutter Port

## What This Is

A Flutter for Windows desktop application that ports the existing Python/Tkinter Ecom Video Tracker GUI feature-for-feature. It records barcode-triggered videos of e-commerce products: scan a barcode to start recording, scan the next barcode to stop-and-save the previous video and immediately begin the next — a continuous scanning workflow for packing/tracking stations. The new app lives in `ecom-flutter/`, alongside the reference Python implementation in `ecom-py/`.

## Core Value

The continuous scan → record → save loop must work flawlessly: every scanned barcode reliably stops the previous recording, saves it under the correct name, and starts a new one without missing frames or losing videos.

## Requirements

### Validated

<!-- Proven valuable in the existing ecom-py production app — the parity target. -->

- ✓ Barcode-triggered continuous recording (scan stops previous, starts next) — existing (ecom-py)
- ✓ Live camera preview with recording indicator — existing (ecom-py)
- ✓ Video files organized as `videos/YYYY-MM-DD/YYYYMMDD_HHMMSS_BARCODE.mp4` — existing (ecom-py)
- ✓ SQLite transaction log (barcode, start/end time, filename, duration, file size, stop method) — existing (ecom-py)
- ✓ Search recordings by barcode and date range with calendar pickers — existing (ecom-py)
- ✓ Settings UI: camera selection by name, resolution, FPS, codec, storage paths — existing (ecom-py)
- ✓ FFmpeg post-save video compression with progress dialog and compression settings — existing (ecom-py)
- ✓ Storage usage and recording statistics display — existing (ecom-py)

### Active

<!-- The Flutter port scope. Hypotheses until the port ships and is used in production. -->

- [ ] Full feature parity with the ecom-py desktop GUI (all Validated items above, rebuilt in Flutter)
- [ ] Runs as a native Windows 10/11 desktop app
- [ ] Faster startup than the Python app
- [ ] Modern, polished UI (upgrade from Tkinter's dated look; keep the purple theme identity)
- [ ] Simple distribution — self-contained Windows build without a Python runtime

### Out of Scope

- Windows 7 support — Flutter desktop requires Windows 10+; Win7 machines stay on the Python app
- Web interface (Flask equivalent) — straight port of the desktop GUI only; web UI remains available in ecom-py
- Mobile (Android/iOS) targets in v1 — future reuse is a motivation for choosing Flutter, but v1 ships Windows-only
- New features beyond parity (cloud sync, auth, multi-camera, inventory integration) — port first, extend later
- Porting `game_scanner.py` / `add_watermark.py` utilities — dead/one-off code, not part of the GUI product

## Context

- **Reference implementation:** `ecom-py/` (Python 3.11+, Tkinter GUI `app_gui.py` ~2491 lines, OpenCV capture, stdlib sqlite3, FFmpeg subprocess compression). Codebase map at `.planning/codebase/`.
- **Prior port attempt:** A Qt6/C++ port was started and abandoned (removed in commit `6dd8a66`) — C++ development was too slow/complex. Flutter is the second attempt at replacing Tkinter.
- **Known flaws in the reference app that the port should NOT replicate** (from `.planning/codebase/CONCERNS.md`): business-logic duplication between Flask and Tkinter frontends, SQLite connection-leak patterns, delete-then-rename data-loss risk in the video compressor (compress to temp file and atomically swap instead), no disk-space guard for long-running use.
- **Hardware:** USB barcode scanners acting as keyboard wedges (scan = fast keystrokes + Enter); standard USB/built-in webcams.
- **Dev/test environments:** primary development happens on Donald's Linux machine; a Windows machine is available for `flutter build windows`, the camera/scanner hardware spike, and all Windows-specific validation. Plans should split work accordingly (cross-platform code developed on Linux, hardware/release verification on Windows).
- **The hard technical problem:** camera capture + video encoding on Windows in Flutter. Flutter's official camera plugin support on Windows is limited (preview yes, but recording support is weak). Expect this to need dedicated research (options: `camera_windows`, FFI to native capture, FFmpeg-based recording pipeline).

## Constraints

- **Platform**: Windows 10/11 desktop — the deployment target; Flutter does not support Win7
- **Tech stack**: Flutter (Dart) — chosen for UI quality, packaging, startup speed, and future mobile reuse
- **Parity**: Behavior must match ecom-py desktop GUI — operators should not need retraining; file naming, folder layout, and DB schema should remain compatible
- **Dependencies**: FFmpeg required at runtime for compression (bundle or document, as in the Python app)
- **Data compatibility**: SQLite schema and video folder structure should match ecom-py so existing archives remain searchable

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Flutter over continuing Qt6/C++ | C++ port was too slow to develop; Flutter gives modern UI, easy packaging, fast startup, future mobile reuse | — Pending |
| Straight port, no new features | Reduce risk; parity is the measure of success | — Pending |
| Windows 10/11 only | Flutter desktop floor; Win7 stations keep the Python app | — Pending |
| Keep FFmpeg compression at parity | Compression is used in production workflow | — Pending |
| New app lives in `ecom-flutter/` in this repo | Same monorepo pattern as the previous Qt6 attempt; keeps reference code adjacent | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-11 after initialization*
