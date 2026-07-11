# Requirements: Ecom Video Tracker — Flutter Port

**Defined:** 2026-07-11
**Core Value:** The continuous scan → record → save loop must work flawlessly: every scanned barcode reliably stops the previous recording, saves it under the correct name, and starts a new one without missing frames or losing videos.

## v1 Requirements

Requirements for the initial Flutter release (`ecom-flutter/`, Windows 10/11). Each maps to roadmap phases. Behavior reference: `ecom-py/app_gui.py` and supporting modules.

### Recording Workflow

- [ ] **REC-01**: Operator can scan a barcode while idle to start recording tagged with that barcode
- [ ] **REC-02**: Operator can scan a new barcode while recording to stop-and-save the previous video and immediately start a new recording with the new barcode
- [ ] **REC-03**: Operator can stop the active recording with a manual "Stop Recording" button (disabled when idle)
- [ ] **REC-04**: Stop/save runs off the UI thread with a non-dismissible "Saving Recording..." progress dialog — UI never freezes
- [ ] **REC-05**: Barcode input is validated as non-empty, trimmed, and uppercased (no format validation — matches reference behavior)
- [ ] **REC-06**: Operator can select a Video Label (Normal / Return and Refund Unboxing / Return Parcel Unboxing) that determines storage subfolder, watermark text, DB label column, and search filter value
- [ ] **REC-07**: Closing the app while recording prompts for confirmation and stops-and-saves the recording if confirmed

### Barcode Input

- [ ] **BAR-01**: USB keyboard-wedge scanner input (fast keystrokes + Enter) is captured and submitted regardless of which widget has focus, including while dialogs are open
- [ ] **BAR-02**: Operator can type a barcode manually and submit via Enter key or a Submit button (same code path as scanner input)

### Camera & Preview

- [ ] **CAM-01**: Live camera preview renders continuously (~30fps), independent of recording state
- [ ] **CAM-02**: Preview scales with window resizing (min window 800x600)
- [ ] **CAM-03**: A red "RECORDING: {filename} [{label}]" indicator overlays the preview while recording
- [ ] **CAM-04**: Camera auto-reinitializes after failure/disconnect with a cooldown, without requiring an app restart
- [ ] **CAM-05**: Recorded frames carry a burned-in watermark: timestamp (top-left), label (top-right), barcode (bottom-left) — rendered into the video file itself, not just the preview

### Storage & Files

- [ ] **STO-01**: Videos save to `videos/YYYY-MM-DD/<LabelFolder>/YYYYMMDD_HHMMSS_BARCODE.mp4` with folders auto-created (label folders: `Normal`, `Return and Refund`, `Return Parcel`)
- [ ] **STO-02**: A disk-space check runs before starting a recording; operator is warned/blocked when free space is below threshold
- [ ] **STO-03**: Operator can open a recording's video file or reveal it in Explorer from the app

### Database

- [ ] **DB-01**: Every recording writes a transaction row to SQLite matching the existing ecom-py schema exactly (barcode, video_filename, start/end time, duration, file size, stop method, label, compression columns) so existing archives stay searchable across both apps
- [ ] **DB-02**: Database uses one long-lived connection with WAL mode enabled (no per-call connection churn)
- [ ] **DB-03**: Total storage used (SUM of file sizes) and recording statistics display in the main window, refreshed ~1s

### Main Window UI

- [ ] **UI-01**: Live status panel shows recording state, current filename, duration timer (MM:SS), storage used, and compression queue status
- [ ] **UI-02**: Recent recordings list (last 10) shows barcode, label, start time, duration, size, and compression status glyph
- [ ] **UI-03**: Status bar messages auto-clear back to "Ready" after 5 seconds
- [ ] **UI-04**: App uses a modern Flutter theme seeded from the existing purple identity (#667eea primary, #10b981 success, #dc2626 danger)

### Search

- [ ] **SRCH-01**: Operator can search recordings by partial, case-insensitive barcode
- [ ] **SRCH-02**: Operator can filter search results by Video Label (with "All Labels" default)
- [ ] **SRCH-03**: Operator can filter by date range using calendar date pickers (both dates optional/clearable)
- [ ] **SRCH-04**: Operator can sort results by date (newest/oldest), barcode, duration, or file size
- [ ] **SRCH-05**: Results render as cards showing barcode, color-coded label badge, timestamp, duration, size, filename, with Play and Show-in-Folder actions
- [ ] **SRCH-06**: Result path resolution falls back to the pre-label-folder layout so legacy ecom-py archives remain playable
- [ ] **SRCH-07**: Search dialog supports keyboard shortcuts: Esc closes, Ctrl+F focuses search, F5 refreshes
- [ ] **SRCH-08**: Results footer shows result count ("Showing X of Y")

### Settings

- [ ] **SET-01**: Operator can select the camera by human-readable device name (e.g., "Logitech C920"), with a non-blocking Refresh Cameras action
- [ ] **SET-02**: Operator can set resolution from presets (640x480 through 4K) and FPS (15/24/30/60)
- [ ] **SET-03**: Operator can select the recording codec from options equivalent to the reference set (subject to the chosen capture backend; parity of the setting, mapped codecs may differ)
- [ ] **SET-04**: Operator can toggle auto-exposure and manually tune exposure, gain, and brightness with live-apply sliders (via Win32/COM FFI shim — IAMCameraControl/IAMVideoProcAmp)
- [ ] **SET-05**: Operator can edit storage paths (videos, database, logs) with native folder/file pickers
- [ ] **SET-06**: Operator can configure compression: enable toggle, codec (H.264/H.265), CRF quality (18-35), preset (ultrafast→slow), delete-original toggle, process priority — with live FFmpeg found/not-found status
- [ ] **SET-07**: Settings persist to a human-editable `settings.json` beside the executable, deep-merged with defaults on load
- [ ] **SET-08**: Saving settings that affect capture triggers async camera reinitialization with a progress dialog; Reset to Defaults / Cancel / Save & Apply buttons work as in the reference

### Compression

- [ ] **COMP-01**: Completed recordings queue for FFmpeg compression on a serialized background worker that never blocks recording or the next scan
- [ ] **COMP-02**: FFmpeg is auto-discovered (bundled dir, common install paths, then PATH); when missing or disabled, compression is skipped gracefully with a visible warning — recording keeps working
- [ ] **COMP-03**: Compression replaces the original atomically (compress to temp, atomic swap) — a crash mid-compression never loses the original video
- [ ] **COMP-04**: FFmpeg runs with configured Windows process priority, hidden console window, and capped threads; jobs time out after 1 hour with a forced kill
- [ ] **COMP-05**: Compression status (pending/processing/completed with ratio/failed/skipped) persists per-transaction and displays in the UI

### Reliability & Logging

- [ ] **LOG-01**: All significant events (recording start/stop, errors, compression outcomes, settings changes) log to `logs/app.log` and console with timestamps
- [ ] **LOG-02**: Log files rotate (size- or date-based) so long-running kiosk sessions don't grow logs unbounded
- [ ] **REL-01**: App survives a multi-hour soak test (hundreds of scan cycles) with flat memory/handle counts and zero lost videos

### Packaging

- [ ] **PKG-01**: App builds as a self-contained Windows release (`flutter build windows`) that runs without a Python or Flutter runtime installed
- [ ] **PKG-02**: App distributes via an Inno Setup installer (or portable folder) with FFmpeg bundled or its absence clearly surfaced
- [ ] **PKG-03**: App cold-starts noticeably faster than the Python reference app

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Future

- **FUT-01**: Mobile companion app (Android/iOS) for viewing recordings
- **FUT-02**: Cloud storage sync
- **FUT-03**: Multi-camera support

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Web UI (Flask equivalent) | Straight port of desktop GUI only; web UI remains in ecom-py; would reintroduce the orchestration-duplication flaw |
| Windows 7 support | Flutter desktop requires Windows 10+; Win7 stations stay on the Python app |
| User authentication / multi-user | Kiosk-style single-session usage is the validated model; no such concept in the reference |
| Inventory system integration | No integration point exists to design against; barcode stays an opaque string |
| Strict barcode format validation (UPC/EAN/Code128) | Reference deliberately accepts any non-empty string; strict validation would break existing workflows |
| Configurable/free-form barcode prefixes | Dead code in the reference (`is_start_code`/`is_stop_code` never called) — do not port |
| New label categories beyond the fixed 3 | Hardcoded into folder mapping, watermarks, DB semantics, and search; changing breaks archive compatibility |
| Porting `game_scanner.py` / `add_watermark.py` | Dead/one-off utility code, not part of the GUI product |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| REC-01 | Phase 1 | Pending |
| REC-02 | Phase 1 | Pending |
| REC-03 | Phase 1 | Pending |
| REC-04 | Phase 2 | Pending |
| REC-05 | Phase 1 | Pending |
| REC-06 | Phase 2 | Pending |
| REC-07 | Phase 2 | Pending |
| BAR-01 | Phase 1 | Pending |
| BAR-02 | Phase 1 | Pending |
| CAM-01 | Phase 1 | Pending |
| CAM-02 | Phase 1 | Pending |
| CAM-03 | Phase 1 | Pending |
| CAM-04 | Phase 2 | Pending |
| CAM-05 | Phase 2 | Pending |
| STO-01 | Phase 1 | Pending |
| STO-02 | Phase 2 | Pending |
| STO-03 | Phase 2 | Pending |
| DB-01 | Phase 1 | Pending |
| DB-02 | Phase 1 | Pending |
| DB-03 | Phase 2 | Pending |
| UI-01 | Phase 2 | Pending |
| UI-02 | Phase 2 | Pending |
| UI-03 | Phase 2 | Pending |
| UI-04 | Phase 2 | Pending |
| SRCH-01 | Phase 4 | Pending |
| SRCH-02 | Phase 4 | Pending |
| SRCH-03 | Phase 4 | Pending |
| SRCH-04 | Phase 4 | Pending |
| SRCH-05 | Phase 4 | Pending |
| SRCH-06 | Phase 4 | Pending |
| SRCH-07 | Phase 4 | Pending |
| SRCH-08 | Phase 4 | Pending |
| SET-01 | Phase 1 | Pending |
| SET-02 | Phase 4 | Pending |
| SET-03 | Phase 4 | Pending |
| SET-04 | Phase 4 | Pending |
| SET-05 | Phase 4 | Pending |
| SET-06 | Phase 3 | Pending |
| SET-07 | Phase 4 | Pending |
| SET-08 | Phase 4 | Pending |
| COMP-01 | Phase 3 | Pending |
| COMP-02 | Phase 3 | Pending |
| COMP-03 | Phase 3 | Pending |
| COMP-04 | Phase 3 | Pending |
| COMP-05 | Phase 3 | Pending |
| LOG-01 | Phase 1 | Pending |
| LOG-02 | Phase 5 | Pending |
| REL-01 | Phase 5 | Pending |
| PKG-01 | Phase 5 | Pending |
| PKG-02 | Phase 5 | Pending |
| PKG-03 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 51 total
- Mapped to phases: 51
- Unmapped: 0 ✓

---
*Requirements defined: 2026-07-11*
*Last updated: 2026-07-11 after roadmap creation*
