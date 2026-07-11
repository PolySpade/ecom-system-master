# Walking Skeleton — Ecom Video Tracker (Flutter Port)

**Phase:** 1
**Generated:** 2026-07-11

## Capability Proven End-to-End

An operator can enter/scan a barcode to start a recording on a live Windows webcam preview, enter/scan another barcode to stop-and-save the previous video and immediately start the next, and see every start/stop cycle written to a schema-compatible WAL SQLite database and `logs/app.log` — validated on real target hardware.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Framework | Flutter 3.41.6 stable (Dart 3.11.4), Windows desktop | Installed on dev machine; UI quality, packaging, startup speed, future mobile reuse (per PROJECT.md constraints) |
| Camera / recording | `camera ^0.12.0+1` + `camera_windows ^0.2.6+4` (Media Foundation CaptureEngine); `camera_desktop` as documented drop-in fallback (same `camera_platform_interface`) | Official flutter.dev plugin; thin Dart wrapper, native code owns capture — avoids the abandoned Qt6/C++ custom-FFI path. Fallback selectable in Plan 03 if hardware spike fails |
| Data layer | `sqflite_common_ffi ^2.4.2`, ONE long-lived connection with WAL mode | Raw-SQL API matches ecom-py/database.py near-verbatim; byte-compatible schema keeps existing `database.db` archives searchable across both apps (DB-01/DB-02) |
| Barcode input | Top-level `HardwareKeyboard.instance.addHandler` + inter-key debounce buffer; `Focus`-wrapper fallback for issue #160786 | Focus-independent keyboard-wedge capture (BAR-01); which mechanism works is decided by Plan 03's hardware checkpoint on 3.41.6 |
| Path/base-dir resolution | `Platform.resolvedExecutable`-relative base dir; relative settings paths resolve against it, absolute pass through | Matches ecom-py's frozen-exe "beside the executable" behavior for archive compatibility |
| Config | `settings.json` beside the exe, deep-merged over full defaults (read-only in Phase 1) | Mirrors ecom-py SettingsManager `_deep_merge`; full Settings UI is Phase 4 |
| Directory layout | `ecom-flutter/lib/{core,ui,models}` + `test/` for pure-Dart units | Separates native/OS-boundary concerns (core services) from UI; test/ holds hardware-independent unit tests runnable on Linux |
| Deployment target | `flutter build windows` self-contained release; Windows 10/11 (no Python/Flutter runtime needed) | Deployment target per constraints; Inno Setup packaging deferred to Phase 5 |
| Auth | None (single-session kiosk) | Explicitly out of scope per REQUIREMENTS.md |

## Stack Touched in Phase 1

- [x] Project scaffold (`flutter create` Windows, flutter_lints, analysis_options.yaml)
- [x] Routing — single main screen (desktop app, no multi-route needed for skeleton)
- [x] Database — real WAL SQLite write (createTransaction) AND real read (getRecentTransactions / getTotalStorageUsed)
- [x] UI — interactive barcode entry + Stop button + live preview wired to camera service and DB
- [x] Deployment — `flutter run -d windows` full-stack run + `flutter build windows` release smoke test (Plan 03 Task 4)

## Out of Scope (Deferred to Later Slices)

- Non-blocking "Saving Recording..." progress dialog off the UI thread (REC-04) — Phase 2
- Video Label routing beyond `Normal` (folder/watermark/DB/search) (REC-06) — Phase 2 (map shape built now, only `Normal` exercised)
- Burned-in watermarks (timestamp/label/barcode) (CAM-05) — Phase 2
- Camera auto-reinitialization on disconnect (CAM-04) — Phase 2
- Disk-space guard before recording (STO-02) and open/reveal-in-Explorer (STO-03) — Phase 2
- Exit-while-recording confirmation (REC-07) — Phase 2
- Full status panel, recent-list glyphs, auto-clearing status bar, themed identity (UI-01..04, DB-03) — Phase 2
- FFmpeg compression pipeline (COMP-01..05, SET-06) — Phase 3
- Search dialog (SRCH-01..08) — Phase 4
- Full Settings dialog: resolution/FPS/codec/exposure sliders, path pickers, reinit (SET-02..05, SET-07..08) — Phase 4
- Log rotation, soak test, Inno Setup installer, cold-start timing (LOG-02, REL-01, PKG-01..03) — Phase 5

## Subsequent Slice Plan

Each later phase adds vertical slices on top of this skeleton without altering the architectural decisions above:

- **Phase 2:** Full recording workflow — non-blocking save dialog, label routing + watermarks, camera auto-reinit, disk guard, exit confirmation, real main-window UI.
- **Phase 3:** Compression pipeline — serialized background FFmpeg worker with atomic file replacement, queued on stop.
- **Phase 4:** Search & Settings — full-featured search + complete settings dialog (built in parallel with Phase 3, depends only on Phase 2).
- **Phase 5:** Hardening & Packaging — log rotation, multi-hour soak, self-contained Windows installer, fast cold start.
