# Feature Research

**Domain:** Barcode-triggered warehouse video-recording station (desktop kiosk app) — Flutter Windows port of `ecom-py/app_gui.py`
**Researched:** 2026-07-11
**Confidence:** HIGH (all findings sourced directly from reading the reference implementation line-by-line: `app_gui.py`, `camera_handler.py`, `barcode_handler.py`, `video_compressor.py`, `database.py`, `settings_manager.py`, `README.md`)

## How to Read This Document

Unlike a typical greenfield "what does this market expect" features doc, this is a **port-parity spec**: the feature set is fixed by the working Python app. "Table Stakes" here means *"required for operators to accept the port as a replacement"* — not competitive necessity. "Differentiators" are parity-plus polish Flutter enables for free or cheap. "Anti-Features" are things to deliberately exclude from v1, including features present in the *web* interface but not needed in a desktop-only port, and things the reference app itself does poorly that should not be copied.

## Feature Landscape

### Table Stakes (Required for Parity — v1 Must Have)

Operators currently use `app_gui.py` daily. Any regression here breaks their workflow or their data.

#### Recording Workflow

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Continuous scan → record → save loop | This is the Core Value from PROJECT.md; the entire product exists for this loop | HIGH | Barcode state machine: not-recording + scan → `start`; recording + scan → `stop_and_start` (stop previous, save, immediately start new with new barcode); explicit stop button → `stop`. Source: `barcode_handler.py:57-85`. |
| Barcode validation | Prevents empty/garbage input from corrupting the recording state | LOW | Reference validation is minimal: non-empty string only (`barcode_handler.py:11-31`). Barcode is uppercased and stripped before use. Do not over-engineer format validation — the reference doesn't. |
| Video Label / category selector (Normal / Return and Refund Unboxing / Return Parcel Unboxing) | Determines storage subfolder and is burned into the watermark and DB record; operators actively use this to categorize footage | MEDIUM | Dropdown next to barcode entry, default "Normal (Standard)". Maps to folder names: `Normal`, `Return and Refund`, `Return Parcel` (`camera_handler.py:340-347`). **This is a real, load-bearing feature — not mentioned in PROJECT.md's requirement list, must be added.** |
| Manual "Stop Recording" button | Operator needs to end a session without scanning a new barcode (e.g., end of shift, no more items) | LOW | Disabled when idle, enabled while recording (`app_gui.py:429-443`). |
| Non-blocking stop/save with progress indication | Flushing the frame buffer to disk on stop can take noticeable time; freezing the UI here breaks the continuous-scan feel | MEDIUM | Reference runs `stop_recording()` on a background thread and polls every 50ms while showing a modal "Saving Recording..." dialog with indeterminate progress bar that cannot be dismissed (`app_gui.py:763-828`, `SavingProgressDialog` class). In Flutter: async stop off the UI isolate/thread with a non-dismissible progress dialog. |
| Recording indicator overlay on preview | Operator must see at a glance whether the camera is actively recording, and what file/label it's tied to | LOW | Red banner overlay reading "RECORDING: {filename} [{label}]" shown over the camera feed only while recording (`app_gui.py:852-884`). |
| Live status panel: state, current filename, duration timer, storage used, compression status | Operators use this to sanity-check the system is working without opening logs | LOW | Updates on a ~1s tick. Duration is computed from `time.time() - recording_start_time`, formatted `MM:SS` (`app_gui.py:638-678`). |
| Auto-clearing status bar messages | Gives transient feedback ("Recording started: X") without needing user dismissal | LOW | Message shown, auto-reverts to "Ready" after 5s (`app_gui.py:989-994`). |
| Confirm-before-exit while recording | Prevents accidental data loss if operator closes the window mid-recording | LOW | `messagebox.askokcancel` on window close if `camera.is_recording()`; stops and saves if confirmed (`app_gui.py:1063-1078`). |

#### Live Preview

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Real-time camera preview, independent of recording state | Operators frame/aim the camera before scanning; preview must work when idle too | HIGH | This is the hardest technical problem flagged in PROJECT.md. Reference: dedicated background capture thread continuously reads frames into `latest_frame` regardless of recording state; a separate downscaled "preview frame" (`get_preview_frame`, nearest-neighbor resize, no upscaling) is polled by the UI every 33ms (~30fps display cap) (`camera_handler.py:119-244`, `app_gui.py:582-636`). |
| Preview scales to container / window resize | App window is resizable (min 800x600); users resize to fit their station monitor | MEDIUM | Debounced resize handling (100ms) recalculates container size only when needed, not every frame (`app_gui.py:144-166`). |
| Camera auto-reinitialization on failure/disconnect | USB webcams at warehouse stations get bumped/unplugged; app must recover without a restart | HIGH | Consecutive-failure counter (100 failed reads) triggers reinit with a 5s cooldown between attempts (`camera_handler.py:151-203`). |

#### Barcode Capture Behavior

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Keyboard-wedge scanner input via a focused text field + Enter-to-submit | USB barcode scanners emit fast keystrokes + Enter; this is the only integration the reference supports and it works reliably | LOW | Reference: single `Entry` widget bound to `<Return>`, auto-focused on load and refocused after every submit (`app_gui.py:388-397`, `:713`, `:737`, `:754`, `:848`). No special debounce/rate-limiting beyond what Tkinter's event loop naturally provides. |
| Global/always-available focus for barcode entry ("keyboard-wedge input capture regardless of focus") | Per milestone context: operators must not have to click into a field before every scan; a stray click elsewhere must not eat the next scan | MEDIUM | **This is an implicit requirement, not literally coded this way in the reference** — the Python app relies on `.focus()` calls after each action to keep the Entry focused, which is fragile if the user clicks another widget. The Flutter port should do this more robustly (e.g., a global keyboard listener/shortcut handler that routes digit+Enter bursts to the barcode handler regardless of which widget has focus), which is a **legitimate differentiator opportunity**, not just parity. |
| Submit via button OR Enter key | Some operators may want a manual "type + click" fallback path (testing, non-scanner input) | LOW | `Submit Barcode` button calls the same `process_barcode()` as Enter (`app_gui.py:414-427`). |

#### Storage & File Organization

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Date-organized storage: `videos/YYYY-MM-DD/<LabelFolder>/<timestamp>_<BARCODE>.mp4` | Existing archives must remain discoverable; PROJECT.md requires DB/folder compatibility with ecom-py | LOW | Folder auto-created via `os.makedirs(exist_ok=True)` at recording start (`camera_handler.py:365-369`). Filename: `YYYYMMDD_HHMMSS_BARCODE.mp4`. Label folder mapping is fixed 3-way (`Normal`, `Return and Refund`, `Return Parcel`). |
| Timestamp + label + barcode watermark burned into video frames | Recorded video is the audit trail; metadata must be visible in the video itself, not just the DB, in case files get separated from the database | MEDIUM | Per-frame overlay: timestamp top-left, label top-right (purple background), barcode bottom-left — drawn via OpenCV `putText`/`rectangle` on every frame before writing (`camera_handler.py:421-462`). This must be reproduced pixel-equivalent-ish in the Flutter port's video pipeline (native encoder, not a Dart-side redraw after the fact). |
| SQLite transaction log matching existing schema | PROJECT.md explicitly requires DB schema compatibility so existing archives stay searchable across both apps | MEDIUM | Table `transactions`: id, barcode, video_filename, start_time, end_time, duration_seconds, file_size_mb, stop_method, label, created_at, plus compression columns (`compression_status`, `compressed_file_size_mb`, `compression_ratio`, `compressed_filename`). See `database.py:26-63`. |
| Total storage-used display | Operators/managers monitor disk usage informally during shifts | LOW | `SUM(file_size_mb)` over all transactions, refreshed every ~1s (`database.py:194-212`, `app_gui.py:651-653`). |
| Recent recordings list (last 10) with compression status | Immediate feedback loop — operator can verify the last few scans actually saved | LOW | Text list showing barcode, label, start time, duration, size, and a compression-status glyph (queued/compressing/compressed w/ ratio/failed/skipped) (`app_gui.py:886-935`). |
| Open video file / show-in-folder actions | Operators/QA occasionally need to review a specific recording immediately | LOW | Uses OS file-open (`os.startfile` equivalent) and reveal-in-explorer. Windows-only in the port, so simplifies to one code path (`app_gui.py:941-987`). |

#### Search Dialog

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Search by barcode (partial, case-insensitive) | Core lookup use case — "find the video for barcode X" | LOW | `UPPER(barcode) LIKE UPPER('%term%')` (`database.py:283-285`). |
| Filter by label/category | Operators filter by "Return Parcel Unboxing" etc. for QA review batches | LOW | Exact match against the `label` column, with an "All Labels" default (`database.py:295-297`). |
| Date range filter with calendar date pickers | Per milestone context, this is a documented, actively-used capability ("searchable transaction log") | MEDIUM | Reference uses `tkcalendar.DateEntry` widgets, clearable (optional filter), purple-themed to match app (`app_gui.py:1251-1295`). Flutter needs an equivalent native-feeling date-picker widget; this is a straightforward Material/Fluent date picker in Flutter, likely *easier* than the Tkinter version. |
| Sort by: Date (Newest/Oldest), Barcode, Duration, File Size | Lets operators triage by size (find bloated files) or duration (find abnormal scans) | LOW | Whitelisted column list prevents SQL injection via ORDER BY (`database.py:301-303`). |
| Result cards: barcode, label badge (color-coded), timestamp, duration, size, filename, Play + Show-in-Folder actions | Visual, scannable results list is how operators currently triage search results | MEDIUM | Cards with hover effect, color-coded label badges (red/orange/green per label) (`app_gui.py:1503-1638`). Video path resolution falls back to the pre-label-folder layout for legacy files — **the Flutter port should preserve this backward-compatible path resolution** since existing archives may predate the label-folder feature. |
| Result count / "Showing X of Y" stats footer | Confirms whether a search was too broad/narrow at a glance | LOW | `results_label` + `stats_label` (`app_gui.py:1391-1404`, `:1492-1493`). |
| Keyboard shortcuts: Esc to close, Ctrl+F to focus search, F5 to refresh | Power-user affordances already trained into daily users | LOW | `app_gui.py:1103-1105`. Cheap to replicate in Flutter via `Shortcuts`/`Actions` widgets. |

#### Settings Dialog

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Camera selection by human-readable name (not just index) | README explicitly markets this ("Shows real camera names like 'Logitech C920' instead of 'Camera 0'") — a UX regression to "Camera 0/1/2" would be noticed immediately | HIGH | Windows: DirectShow enumeration via `pygrabber`. Reference has both a "fast" (cached) and full enumeration path with a 30s cache and async refresh so the dialog doesn't lag (`camera_utils.py`, referenced from `app_gui.py:1839`, `:2304-2350`). Flutter/Windows equivalent needs native camera enumeration (likely via `camera_windows` plugin or a Win32/Media Foundation FFI call) — **flag for phase-specific research**, this is the single hardest settings feature to port. |
| Resolution presets (640x480 up to 4K) | Documented, user-facing setting | LOW | Fixed list of 5 presets, not free-form (`app_gui.py:1644-1650`). |
| FPS selection (15/24/30/60) | Documented, user-facing setting | LOW | Radio buttons, fixed set (`app_gui.py:1659`, `:1774-1791`). |
| Codec selection (MP4V/H264/XVID/MJPEG) | Documented, user-facing setting | MEDIUM | These map to OpenCV FourCC codes in the reference (`mp4v`, `avc1`, `XVID`, `MJPG`). In Flutter's native-encoder pipeline, the equivalent codec options depend entirely on which capture/encode approach is chosen (research flag — see PROJECT.md's "hard technical problem" note) — the *setting* is table stakes, but the underlying implementation is a phase-specific research item. |
| Manual exposure/gain/brightness controls with live-apply | Warehouse lighting varies by station; operators actively tune this to avoid over/under-exposed video | MEDIUM | Auto-exposure checkbox toggles between camera auto mode and 3 sliders (exposure -13..-1, gain 0-255, brightness 0-255), throttled to apply 100ms after the last slider change, with a "Live Preview" toggle (`app_gui.py:1897-2022`). Maps to `cv2.CAP_PROP_*` in the reference — Flutter/Windows equivalent depends on the chosen capture backend's exposed camera controls. |
| Refresh Cameras button (background, non-blocking) | Operators plug in a different webcam without restarting the app | MEDIUM | Async detection with callback-based UI update (`app_gui.py:2304-2350`). |
| Storage paths: video path, database path, log path (editable, with folder/file browse dialogs) | Documented setting; multi-station deployments may need custom paths (e.g., a mapped network drive) | LOW | Simple text entry + native file/folder picker (`app_gui.py:2165-2241`). |
| FFmpeg compression settings: enable toggle, codec (H.264/H.265), CRF quality slider (18-35), encoding preset (ultrafast/fast/medium/slow), delete-original toggle, process priority (low/below_normal/normal) | Documented, actively used in production per PROJECT.md ("Keep FFmpeg compression at parity") | MEDIUM | Full settings surface in `app_gui.py:2024-2163`. FFmpeg-status label shown live (found/not found) via a throwaway `VideoCompressor` instance's `check_ffmpeg_installed()`. |
| Reset to Defaults / Cancel / Save & Apply buttons | Standard settings-dialog affordances users expect | LOW | Reset re-applies `SettingsManager.DEFAULT_SETTINGS` (`settings_manager.py:15-47`) and closes the dialog with a note that camera will auto-restart. |
| Save triggers async camera reinitialization with progress dialog | Changing resolution/FPS/codec/camera index requires restarting the capture pipeline; blocking the UI here is unacceptable | MEDIUM | Same `SavingProgressDialog` pattern reused for "Applying Settings..." (`app_gui.py:2444-2480`). |
| Settings persisted as JSON, deep-merged with defaults on load | Ensures forward-compatible settings files as new keys are added, and that a partial/hand-edited file doesn't crash the app | LOW | `SettingsManager._deep_merge` (`settings_manager.py:109-116`). Categories: `video`, `camera`, `storage`, `app`, `compression`. |

#### Storage Stats

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Total storage used (MB), live-refreshed | Already covered above under Storage & File Organization — listed here for completeness against the question's explicit ask | LOW | Same feature as above. |

#### FFmpeg Compression Flow

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Background compression queue, one job at a time, non-blocking to recording | Compression must not stall the next barcode scan | HIGH | Dedicated worker thread pulling from a `queue.Queue`; `queue_compression()` returns immediately (`video_compressor.py:43-270`). |
| FFmpeg auto-discovery (bundled path, common install paths, then PATH) | App must work whether FFmpeg is bundled, system-installed, or missing | MEDIUM | Checks local script dir, `ffmpeg/bin/`, then `C:\ffmpeg\bin\`, `C:\Program Files\ffmpeg\bin\`, `~\ffmpeg\bin\`, then falls back to plain `ffmpeg` on PATH (`video_compressor.py:100-121`). PROJECT.md requires FFmpeg be bundled or documented for the port — same discovery pattern should be preserved for backward-compat with existing station setups. |
| Graceful skip (not failure) when FFmpeg missing or compression disabled | Recording must keep working even if compression is unavailable — this is a soft dependency | LOW | `CompressionStatus.SKIPPED` with a callback, not an exception (`video_compressor.py:184-212`). |
| Windows process-priority flags + hidden console window for the FFmpeg subprocess | Compression must not visibly steal focus or noticeably degrade the live recording/preview experience | MEDIUM | `CREATE_NO_WINDOW` + `IDLE_PRIORITY_CLASS`/`BELOW_NORMAL_PRIORITY_CLASS`/`NORMAL_PRIORITY_CLASS`, `-threads 2` cap on FFmpeg itself (`video_compressor.py:17-22`, `:394-417`, `:377-388`). |
| Compression status persisted per-transaction and displayed in UI (pending/processing/completed w/ ratio/failed/skipped) | Operators/managers need to verify compression actually ran, not just trust it silently happened | LOW | `compression_status`, `compression_ratio`, `compressed_file_size_mb`, `compressed_filename` columns; live queue-size/is-processing polling in the main window (`database.py:342-395`, `app_gui.py:655-672`). |
| 1-hour compression timeout with forced process kill | Prevents a hung FFmpeg process from blocking the queue indefinitely | LOW | `video_compressor.py:419-438`. |

#### Logging

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| File + console logging of all significant events (recording start/stop, errors, compression outcomes, settings changes) | Only diagnostic tool available to non-technical operators/support when something goes wrong ("Check logs/app.log" is the README's #1 troubleshooting step) | LOW | Standard `logging` to `logs/app.log` + stdout, DEBUG level, one logger per module (`app_gui.py:21-32`). Flutter equivalent: a file logger (e.g., `logging` package + `path_provider` for a `logs/` dir) writing structured, timestamped entries mirroring the same events. |

### Differentiators (Parity-Plus, Enabled by Flutter)

These aren't required for parity but are natural wins given the technology switch — cheap to include, and directly address flaws noted in `.planning/codebase/CONCERNS.md`.

| Feature | Value Proposition | Complexity | Notes |
|---------|--------------------|------------|-------|
| Smoother, higher-frame-rate live preview | Tkinter's `PhotoImage` + `after()` polling loop caps effective preview at ~30fps display with visible tearing/lag potential under load; Flutter's compositor-driven rendering can be materially smoother | MEDIUM | Directly serves PROJECT.md's "Faster startup than the Python app" and general polish goals. |
| Modern theming (keep purple identity, upgrade visuals) | PROJECT.md explicitly calls for "Modern, polished UI (upgrade from Tkinter's dated look; keep the purple theme identity)" | LOW-MEDIUM | Reuse the existing color palette (`#667eea` primary purple, `#10b981` success green, `#dc2626` danger red, `#f0f4f8` background) as a Material/Fluent theme seed — gives immediate visual continuity for operators while looking current. |
| Robust global barcode-scanner capture (not dependent on widget focus tracking) | Removes a fragile parity behavior (reference relies on manually re-calling `.focus()` after every UI action) | MEDIUM | A global raw-keyboard-event listener that buffers fast keystrokes ending in Enter and routes them to the barcode handler regardless of which control currently has focus — turns an implicit requirement into a more resilient implementation than the source. |
| Atomic compress-then-swap instead of delete-then-rename | Reference has a real data-loss bug: `os.remove()` before `os.rename()` in the compression "replace original" step (`video_compressor.py:305-315`, flagged in CONCERNS.md) — a crash between the two calls permanently loses the video | LOW | Use `os.replace()`/`File.rename()` with atomic same-filesystem semantics, or compress to a temp file and only delete the original after the swap succeeds. Explicitly called out in PROJECT.md as a known flaw the port should NOT replicate. |
| Disk-space guard before starting a recording | Reference has no check for available disk space (`config.MAX_STORAGE_GB` is defined but never enforced, per CONCERNS.md); `cv2.VideoWriter` fails silently/corrupts on a full disk | LOW-MEDIUM | Check free disk space via platform API before `start_recording`; warn/block if below a threshold. Explicitly called out in PROJECT.md. |
| Single source of truth for recording orchestration (no duplicated business logic) | Reference duplicates barcode→record→compress orchestration between `app.py` (Flask) and `app_gui.py` (Tkinter), already drifted (CONCERNS.md) | LOW | Not really applicable since the port has no web frontend to duplicate against — but worth structuring the Flutter port's own architecture (a single `RecordingController`/service layer feeding the UI) so this class of bug can't reappear if a second frontend (e.g., future mobile companion) is ever added. |
| Faster cold start | PROJECT.md explicit goal | MEDIUM | Native compiled Flutter Windows binary vs. Python interpreter + Tkinter + OpenCV import chain; largely a byproduct of the platform choice rather than a feature to build. |
| SQLite WAL mode | Reference uses default rollback-journal mode with no WAL and per-call connections with leak risk on exception (CONCERNS.md); WAL reduces lock contention risk if the port ever needs concurrent readers (e.g., a reporting tool reading `database.db` while the app is recording) | LOW | Enable `PRAGMA journal_mode=WAL` at connection open. Cheap insurance even though single-writer usage is the common case. |
| Log rotation | Reference has no rotation on `logs/app.log`, which grows unbounded at DEBUG level over long kiosk uptime (CONCERNS.md) | LOW | Size- or date-based rotation in the Flutter logging setup. |

### Anti-Features (Deliberately NOT to Build in v1)

| Feature | Why It Seems Appealing | Why Problematic for This Port | Alternative |
|---------|-------------------------|-------------------------------|-------------|
| Web UI / Flask-equivalent REST+MJPEG interface | The reference has a whole parallel web app (`app.py`, `templates/`, `static/`); "why not port both?" | PROJECT.md explicitly scopes this out — straight port of the desktop GUI only; doubles the surface area and reintroduces the exact orchestration-duplication bug flagged in CONCERNS.md. Also brings unauthenticated-network-API risk (CONCERNS.md security section) into a new codebase for no requested benefit. | Web UI stays on `ecom-py`; if remote access is ever needed later, design it as a thin client against a single shared service layer, not a duplicate reimplementation. |
| Mobile (Android/iOS) build in v1 | Flutter's whole pitch includes "write once, run anywhere," and PROJECT.md names future mobile reuse as a motivation for choosing Flutter at all | v1 is explicitly Windows-only per PROJECT.md; camera/recording behavior, keyboard-wedge scanning, and file paths are all desktop-specific assumptions that would need separate design work for mobile (e.g., there's no USB keyboard-wedge scanner on a phone). Building it now is scope creep against a fixed parity target. | Structure the service/data layer (models, DB schema, settings schema) in a platform-agnostic way now so a future mobile viewer/companion app is easier, but do not build UI or camera capture for mobile in this milestone. |
| Cloud sync (S3/Google Drive) | README's own "Roadmap → Phase 2" lists this; feels like a natural "while we're rewriting it" addition | Explicitly out of scope per PROJECT.md ("New features beyond parity"). Adds auth, network reliability, and conflict-resolution problems with zero validated demand — the reference app has never shipped this. | Leave local-storage-only; revisit only after the port itself is validated in production. |
| User authentication / multi-user accounts | README's roadmap lists this too; feels "more professional" | No such concept exists in the reference (single shared kiosk session, no login). Adding it now increases scope without a stated requirement and changes the operational model (who "owns" a recording) with no design input from actual station operators. | None needed — kiosk-style single-session usage is the validated model. |
| Multi-camera support | Roadmap item in README; warehouse stations conceivably could use 2 angles | Explicitly out of scope per PROJECT.md. The reference's entire camera/recording pipeline (buffer, watermark, writer) assumes exactly one active camera; supporting N cameras multiplies the hardest technical problem (Windows camera capture in Flutter) by N before it's even solved once. | Ship v1 with single-camera parity; revisit only if a station genuinely needs it after the port is stable. |
| Inventory system integration | Roadmap item in README | Explicitly out of scope per PROJECT.md. No integration point (API, file format) currently exists to design against — would be speculative. | None — barcode is treated as an opaque string identifier, exactly as today. |
| Real barcode format validation / checksum verification (UPC/EAN/Code128 parsing) | Feels like "proper" input validation a modern app should have | The reference deliberately treats any non-empty string as a valid "barcode" (`barcode_handler.py:11-31`) because operators sometimes type labels manually or use non-standard codes; adding strict format validation would reject inputs the current system accepts and break workflows without warning. | Keep validation to "non-empty, trimmed, uppercased" exactly as the reference does. |
| New video label/category options beyond the fixed 3 (Normal / Return and Refund Unboxing / Return Parcel Unboxing) | Seems easy to make this a free-text or admin-configurable list while porting | These 3 values are hardcoded into folder-name mapping, watermark rendering, DB `label` column semantics, and search filters throughout the reference; changing the set breaks folder compatibility with existing archives that PROJECT.md requires to remain searchable. | Port the exact same 3 fixed options; if configurability is wanted later, it's a deliberate follow-up milestone with a migration plan for existing folders/DB rows. |
| Porting `bulk_compressor.py`, `add_watermark.py`, `game_scanner.py` | They exist in the same repo and touch related concerns (compression, watermarking) | PROJECT.md explicitly excludes `game_scanner.py`/`add_watermark.py` as dead/one-off code. `bulk_compressor.py` is a separate standalone Tkinter tool not wired into `app_gui.py` at all — not part of "the desktop GUI product" this milestone targets. | Leave all three in `ecom-py/` untouched; do not port. |
| Real-time collaborative / networked multi-station view | Nothing currently requests this, but "modernizing" invites scope creep toward it | No such capability exists in the reference (each station is a fully independent process/DB/camera). Building shared-state infrastructure now is unvalidated, high-complexity work far outside a parity port. | Each Flutter installation remains a fully independent, single-station app, exactly like each `ecom-py` installation today. |
| Configurable/free-form barcode-scanner "start code" / "stop code" prefixes | `config.BARCODE_START_PREFIX` / `BARCODE_STOP_PREFIX` and `is_start_code()`/`is_stop_code()` exist in `barcode_handler.py` | These methods are defined but **never called** anywhere in `process_barcode()` — dead code in the reference; the actual state machine only cares whether a recording is currently in progress, not barcode prefixes. Porting this unused mechanism would add complexity with no behavioral basis in the working app. | Port only the actual behavior: presence/absence of an in-progress recording determines `start` vs `stop_and_start`. Do not add prefix-based routing. |

## Feature Dependencies

```
Live Camera Preview (independent thread/pipeline)
    └──required by──> Recording Workflow (start/stop_and_start/stop)
                           └──required by──> Video watermarking (needs active recording frames)
                           └──required by──> SQLite transaction log (create/complete transaction)
                                                  └──required by──> Search Dialog (queries the same table)
                                                  └──required by──> Recent Recordings list
                                                  └──required by──> Storage stats (SUM file_size_mb)

Recording Workflow (stop event)
    └──required by──> FFmpeg Compression Queue (queues on stop, not on start)
                           └──required by──> Compression status display (reads back into transaction log)

Settings Dialog: Camera tab (enumeration + selection)
    └──required by──> Live Camera Preview (must select working camera device first)
    └──enhances──> Exposure/gain/brightness live-tuning (operates on the already-selected camera)

Settings Dialog: Video tab (resolution/FPS/codec)
    └──conflicts with──> an in-progress Recording (reference blocks reinit while recording — "Cannot reinitialize camera while recording")

Video Label selector
    └──required by──> Storage folder structure (date/label/file layout)
    └──required by──> Watermark rendering (label text drawn on frame)
    └──required by──> Search Dialog label filter

Keyboard-wedge barcode capture
    └──required by──> Recording Workflow (the only trigger mechanism)
```

### Dependency Notes

- **Recording Workflow requires Live Camera Preview to exist first (architecturally, not sequentially in the UI):** the reference's capture thread produces `latest_frame`/`frame_buffer` continuously; recording is just "start draining the buffer to a `VideoWriter`" — there's no separate capture path for recording vs. preview. The Flutter port's camera-capture research spike (flagged as the hardest technical problem in PROJECT.md) blocks nearly everything else and should be the first phase.
- **FFmpeg Compression Queue requires the Recording Workflow's stop event, not its start event:** compression is queued only after `stop_recording()` succeeds and the transaction is completed in the DB (`app_gui.py:813-818`). It has no dependency on Search or Settings, so it can be built/tested in relative isolation once recording works.
- **Settings Dialog: Video tab conflicts with an in-progress Recording:** the reference explicitly raises "Cannot reinitialize camera while recording" (`camera_handler.py:579-581`) rather than queuing the change — the Flutter port should preserve this constraint (disable/warn in Settings while `is_recording()` is true) rather than attempting a live hot-swap.
- **Video Label selector is upstream of three other features (folder layout, watermark, search filter):** because it's undocumented in PROJECT.md's requirement list but deeply threaded through the reference's storage/search/watermark code, it must be scoped into the very first phase that touches storage layout — retrofitting it later would mean reworking file paths and DB assumptions already built.

## MVP Definition

### Launch With (v1) — Full Parity Set

This *is* the MVP per PROJECT.md ("Full feature parity with the ecom-py desktop GUI"). Every item in the Table Stakes section above is v1, not deferrable, because operators are switching wholesale from the Python app and any missing capability blocks adoption. Priority order for phased delivery (not feature cuts):

- [ ] Camera capture + live preview pipeline on Windows (the hard technical spike — must be de-risked first)
- [ ] Barcode-triggered recording state machine (start / stop_and_start / stop) with continuous-scan UX
- [ ] Video Label selector wired into folder structure and watermark
- [ ] Frame watermarking (timestamp, label, barcode)
- [ ] SQLite transaction log matching existing schema
- [ ] Main window: preview panel, barcode input, status panel, recent recordings list
- [ ] Search dialog: barcode/label/date-range filters, sort, result cards, play/show-in-folder
- [ ] Settings dialog: video, camera (incl. enumeration + exposure), compression, storage, tabs
- [ ] FFmpeg compression queue with status tracking and settings
- [ ] File + console logging
- [ ] Storage stats display

### Add After Validation (v1.x)

Nothing from the reference app is deferred — parity is the whole point of v1. The only "add after" items are the Differentiator-tier improvements that are safe to layer on once parity is confirmed working in the field:

- [ ] Atomic compress-then-swap (data-loss fix) — should ideally land in the *same* milestone as the compression feature itself since it's a correctness fix, not new scope; listed here only if the initial port intentionally ports the reference's exact (flawed) behavior first for a byte-for-byte comparison, then hardens it
- [ ] Disk-space guard before recording — trigger: after first successful parity validation in a real station, add before wider rollout
- [ ] Global keyboard-wedge capture independent of widget focus — trigger: if field testing surfaces any "scan didn't register" incidents traceable to focus loss

### Future Consideration (v2+)

Explicitly out of scope per PROJECT.md; revisit only after the Windows desktop port is shipped and validated:

- [ ] Web interface — defer indefinitely; `ecom-py`'s Flask app remains the web option
- [ ] Mobile targets — defer until there's a validated need beyond "Flutter makes it possible"
- [ ] Cloud sync, multi-camera, inventory integration, user auth — all explicitly named out-of-scope in PROJECT.md; no current demand signal beyond an aspirational README roadmap section

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|----------------------|----------|
| Camera capture + live preview (Windows) | HIGH | HIGH | P1 |
| Barcode recording state machine | HIGH | MEDIUM | P1 |
| Video Label selector + folder/watermark wiring | HIGH | MEDIUM | P1 |
| Frame watermarking | HIGH | MEDIUM | P1 |
| SQLite transaction log (schema-compatible) | HIGH | LOW | P1 |
| Search dialog (filters, sort, cards) | HIGH | MEDIUM | P1 |
| Settings: camera enumeration by name | HIGH | HIGH | P1 |
| Settings: resolution/FPS/codec | MEDIUM | LOW | P1 |
| Settings: exposure/gain/brightness live-tune | MEDIUM | MEDIUM | P1 |
| Settings: storage paths | MEDIUM | LOW | P1 |
| FFmpeg compression queue + settings | HIGH | MEDIUM | P1 |
| Compression status display | MEDIUM | LOW | P1 |
| Recent recordings list | MEDIUM | LOW | P1 |
| Storage stats | LOW | LOW | P1 |
| Logging (file + console) | MEDIUM | LOW | P1 |
| Modern theming / smoother preview polish | MEDIUM | LOW | P2 |
| Atomic compress-then-swap fix | HIGH (data safety) | LOW | P2 |
| Disk-space guard | MEDIUM (data safety) | LOW | P2 |
| Global keyboard-wedge capture robustness | MEDIUM | MEDIUM | P2 |
| SQLite WAL mode | LOW | LOW | P3 |
| Log rotation | LOW | LOW | P3 |
| Web UI, mobile, cloud sync, auth, multi-camera, inventory integration | N/A (out of scope) | N/A | Excluded |

**Priority key:**
- P1: Must have for launch (parity requirement)
- P2: Should have, add once P1 parity is field-validated (mostly correctness/robustness hardening over the reference)
- P3: Nice to have, low-risk hardening with no user-visible behavior change

## Sources

- `ecom-py/app_gui.py` (2491 lines) — primary parity spec; read in full across 6 passes (lines 1-300, 300-750, 750-1150, 1150-1600, 1600-1800, 1800-2250, 2250-2491)
- `ecom-py/barcode_handler.py` — barcode validation and state-machine logic
- `ecom-py/camera_handler.py` — capture thread, recording thread, watermarking, exposure controls, camera lifecycle/reinit
- `ecom-py/video_compressor.py` — FFmpeg queue, discovery, process-priority handling, delete-then-rename bug confirmed at lines 305-315
- `ecom-py/database.py` — SQLite schema and query surface (transactions table, advanced_search, compression status)
- `ecom-py/settings_manager.py` — settings schema/defaults (video, camera, storage, app, compression categories)
- `ecom-py/README.md` — documented feature list, roadmap (source of anti-feature candidates), troubleshooting section (source of logging/FFmpeg-missing UX expectations)
- `.planning/PROJECT.md` — scope boundaries (Validated/Active/Out of Scope), core value statement, known flaws not to replicate
- `.planning/codebase/ARCHITECTURE.md` — component responsibilities, data flow, dual-frontend duplication pattern
- `.planning/codebase/CONCERNS.md` — confirmed pitfalls: delete-then-rename data loss, no disk-space guard, no WAL mode, no log rotation, orchestration duplication

---
*Feature research for: Barcode-triggered video recording desktop kiosk app (Flutter Windows port)*
*Researched: 2026-07-11*
