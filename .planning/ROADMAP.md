# Roadmap: Ecom Video Tracker — Flutter Port

**Mode:** MVP (vertical slicing)
**Granularity:** Coarse (3-5 phases)
**Core Value:** The continuous scan → record → save loop must work flawlessly: every scanned barcode reliably stops the previous recording, saves it under the correct name, and starts a new one without missing frames or losing videos.

## Phases

- [ ] **Phase 1: Scan-Record-Save Spike** - A minimal Flutter app on real target hardware proves barcode-triggered start/stop-and-start/stop recording, live preview, and a schema-compatible SQLite log — de-risking the camera pipeline before any further UI is built.
- [ ] **Phase 2: Full Recording Workflow** - The recording loop reaches parity: non-blocking save, Video Label routing (folder/watermark/DB), burned-in watermarks, camera auto-reinit, disk-space guard, exit confirmation, and the real main-window UI.
- [ ] **Phase 3: Compression Pipeline** - Completed recordings are automatically compressed in the background via a serialized FFmpeg worker with atomic file replacement, without ever blocking recording.
- [ ] **Phase 4: Search & Settings** - Operators can find any past recording via full-featured search and can reconfigure camera, storage, and compression behavior via a settings dialog — matching the reference app's operational surface.
- [ ] **Phase 5: Hardening & Packaging** - The app survives multi-hour unattended kiosk operation with flat resource usage, rotates its logs, and ships as a self-contained, fast-starting Windows installer.

## Phase Details

### Phase 1: Scan-Record-Save Spike
**Goal**: An operator can scan a barcode on real target webcam hardware to start a recording, scan another to stop-and-save it and start the next, and see every recording logged to a schema-compatible SQLite database — proving the highest-risk technical unknown (Windows camera capture + recording in Flutter) before any further work depends on it.
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: REC-01, REC-02, REC-03, REC-05, BAR-01, BAR-02, CAM-01, CAM-02, CAM-03, STO-01, DB-01, DB-02, SET-01, LOG-01
**Success Criteria** (what must be TRUE):
  1. Operator can scan a barcode with a real USB keyboard-wedge scanner (or type one manually) while idle and see recording start, tagged with that barcode
  2. Operator can scan a new barcode while recording and see the previous video stop-and-save correctly while a new recording starts immediately, with no dropped frames or corrupted files, validated against real target webcam hardware
  3. Operator can manually stop the active recording with a button, and it is disabled while idle
  4. Live camera preview renders continuously at ~30fps in a resizable window (min 800x600), with a red "RECORDING" indicator overlaid while recording
  5. Every start/stop cycle writes a row to a SQLite database whose schema is compatible with the existing `ecom-py` `database.db`, saved under `videos/YYYY-MM-DD/...`, and logged to `logs/app.log`
**Plans**: TBD
**UI hint**: yes

### Phase 2: Full Recording Workflow
**Goal**: The recording loop matches ecom-py feature parity end-to-end — saves never freeze the UI, every recording is correctly routed and watermarked by Video Label, the camera recovers from disconnects on its own, and the operator is protected from data loss on exit or low disk space.
**Mode:** mvp
**Depends on**: Phase 1
**Requirements**: REC-04, REC-06, REC-07, CAM-04, CAM-05, STO-02, STO-03, DB-03, UI-01, UI-02, UI-03, UI-04
**Success Criteria** (what must be TRUE):
  1. Stopping a recording shows a non-dismissible "Saving Recording..." progress dialog while the save runs off the UI thread, and the UI never freezes or drops the next scan
  2. Operator can select a Video Label (Normal / Return and Refund Unboxing / Return Parcel Unboxing) before/at recording start, and the resulting file lands in the correct label subfolder with a matching DB label column and a burned-in watermark (timestamp top-left, label top-right, barcode bottom-left) visible in the saved video file itself
  3. Disconnecting and reconnecting the camera causes automatic reinitialization after a cooldown, with no app restart required, and a disk-space check blocks/warns before starting a recording when free space is low
  4. Closing the app while recording prompts for confirmation and stops-and-saves the recording if confirmed; operator can open a saved recording's file or reveal it in Explorer
  5. The main window shows a live status panel (recording state, filename, MM:SS duration, storage used, compression queue), a recent-recordings list (last 10), status-bar messages that auto-clear after 5 seconds, and a modern theme seeded from the existing purple identity
**Plans**: TBD
**UI hint**: yes

### Phase 3: Compression Pipeline
**Goal**: Every completed recording is compressed automatically in the background without ever slowing down or blocking the next scan, and a crash mid-compression can never destroy the original video.
**Mode:** mvp
**Depends on**: Phase 2
**Requirements**: COMP-01, COMP-02, COMP-03, COMP-04, COMP-05, SET-06
**Success Criteria** (what must be TRUE):
  1. Completed recordings automatically queue for FFmpeg compression on a serialized background worker, and recording/scanning stays fully responsive while compression runs
  2. When FFmpeg is missing or disabled, the app detects this automatically (bundled dir, common paths, PATH) and skips compression gracefully with a visible warning — recording still works normally
  3. Compression always writes to a temp file and atomically swaps it in place of the original; killing the app mid-compression never loses the original video
  4. Operator can configure compression (enable toggle, codec H.264/H.265, CRF 18-35, preset, delete-original toggle, process priority) and see live FFmpeg found/not-found status in Settings
  5. Each recording's compression status (pending/processing/completed with ratio/failed/skipped) persists in the database and is visible in the UI
**Plans**: TBD

### Phase 4: Search & Settings
**Goal**: An operator can locate any past recording through flexible search filters and can reconfigure every camera, storage, and behavior setting the reference app exposes, without needing to edit files by hand.
**Mode:** mvp
**Depends on**: Phase 2
**Requirements**: SRCH-01, SRCH-02, SRCH-03, SRCH-04, SRCH-05, SRCH-06, SRCH-07, SRCH-08, SET-02, SET-03, SET-04, SET-05, SET-07, SET-08
**Success Criteria** (what must be TRUE):
  1. Operator can search recordings by partial case-insensitive barcode, filter by Video Label ("All Labels" default) and by optional/clearable date range using calendar pickers, and sort by date/barcode/duration/size
  2. Search results render as cards (barcode, color-coded label badge, timestamp, duration, size, filename) with working Play and Show-in-Folder actions, a "Showing X of Y" footer, and keyboard shortcuts (Esc, Ctrl+F, F5); legacy pre-label-folder ecom-py recordings still resolve and play
  3. Operator can change camera (by human-readable name, with non-blocking Refresh Cameras), resolution/FPS, codec, and live-tune auto-exposure/exposure/gain/brightness via sliders
  4. Operator can edit storage paths (videos, database, logs) via native pickers, and Save & Apply / Reset to Defaults / Cancel behave as in the reference, with capture-affecting changes triggering an async reinit with a progress dialog
  5. Settings persist to a human-editable `settings.json` beside the executable, deep-merged with defaults on load
**Plans**: TBD
**UI hint**: yes

### Phase 5: Hardening & Packaging
**Goal**: The app is production-ready for unattended, hours-long kiosk shifts and ships as a fast, self-contained Windows install that operators can adopt as a full replacement for the Python app.
**Mode:** mvp
**Depends on**: Phase 3, Phase 4
**Requirements**: LOG-02, REL-01, PKG-01, PKG-02, PKG-03
**Success Criteria** (what must be TRUE):
  1. Log files rotate by size or date so a long-running kiosk session never grows `logs/app.log` unbounded
  2. The app survives a multi-hour soak test of hundreds of scan cycles with flat memory/handle counts and zero lost videos
  3. `flutter build windows` produces a self-contained release that runs on a clean Windows 10/11 machine with no Python or Flutter runtime installed
  4. The app installs via an Inno Setup installer (or portable folder) with FFmpeg either bundled or its absence clearly surfaced to the operator
  5. The app's cold start is noticeably faster than the ecom-py reference app, verified by side-by-side timing
**Plans**: TBD

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Scan-Record-Save Spike | 0/TBD | Not started | - |
| 2. Full Recording Workflow | 0/TBD | Not started | - |
| 3. Compression Pipeline | 0/TBD | Not started | - |
| 4. Search & Settings | 0/TBD | Not started | - |
| 5. Hardening & Packaging | 0/TBD | Not started | - |

---
*Roadmap created: 2026-07-11*
*Requirements coverage: 51/51 v1 requirements mapped (FUT-01/02/03 deferred to v2)*
