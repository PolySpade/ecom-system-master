<!-- refreshed: 2026-07-11 -->
# Architecture

**Analysis Date:** 2026-07-11

## System Overview

The application is a barcode-triggered video recording system with two independent front-end entry points (Desktop GUI and Web app) that share the same backend service modules. All application code lives in `ecom-py/`.

```text
┌─────────────────────────────────────────────────────────────┐
│                     Presentation Layer                       │
├──────────────────────────────┬────────────────────────────────┤
│  Desktop GUI (Tkinter)        │  Web UI (Flask + HTML/JS)      │
│  `ecom-py/app_gui.py`         │  `ecom-py/app.py`              │
│  (EcomVideoTrackerApp,        │  (Flask routes)                │
│   SearchWindow, SettingsDialog│  `ecom-py/templates/index.html`│
│   SavingProgressDialog)       │  `ecom-py/static/js/script.js` │
└───────────────┬────────────────┴──────────────┬────────────────┘
                │                                │
                ▼                                ▼
┌─────────────────────────────────────────────────────────────┐
│                      Service / Handler Layer                 │
│  `ecom-py/camera_handler.py`   - CameraHandler (capture/record)│
│  `ecom-py/barcode_handler.py`  - BarcodeHandler (scan logic)  │
│  `ecom-py/video_compressor.py` - VideoCompressor (FFmpeg queue)│
│  `ecom-py/camera_utils.py`     - camera enumeration utilities │
└───────────────┬────────────────┬──────────────┬────────────────┘
                │                │                │
                ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────┐
│                     Persistence / Config Layer                │
│  `ecom-py/database.py`         - Database (SQLite access)     │
│  `ecom-py/settings_manager.py` - SettingsManager (JSON persist)│
│  `ecom-py/config.py`           - module-level config constants│
└───────────────┬─────────────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────────────┐
│  Filesystem / OS Resources                                    │
│  `videos/YYYY-MM-DD/<Label>/*.mp4`, `database.db`,             │
│  `logs/app.log`, `settings.json`, OpenCV camera device,       │
│  FFmpeg subprocess                                             │
└─────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| `EcomVideoTrackerApp` | Desktop GUI main window: camera preview, barcode input, recording controls, recent recordings list | `ecom-py/app_gui.py` |
| `SearchWindow` | Desktop GUI advanced search dialog (filters, cards) | `ecom-py/app_gui.py` |
| `SettingsDialog` | Desktop GUI tabbed settings editor (video/camera/compression/storage/app) | `ecom-py/app_gui.py` |
| `SavingProgressDialog` | Modal progress indicator while a recording is being finalized | `ecom-py/app_gui.py` |
| Flask routes (`app`) | Web UI: renders `index.html`, exposes JSON REST API, MJPEG video stream, video file serving | `ecom-py/app.py` |
| `CameraHandler` | Owns the OpenCV `VideoCapture`/`VideoWriter`, background capture thread, frame buffer, watermarking, start/stop recording | `ecom-py/camera_handler.py` |
| `BarcodeHandler` | Validates barcode strings and decides `start` / `stop_and_start` / `stop` / `invalid` actions | `ecom-py/barcode_handler.py` |
| `VideoCompressor` | Background FFmpeg-based compression worker with a queue and completion callback | `ecom-py/video_compressor.py` |
| `Database` | All SQLite reads/writes against the `transactions` table (CRUD, search, compression status) | `ecom-py/database.py` |
| `SettingsManager` | Loads/saves `settings.json`, deep-merges with defaults, typed getters/setters | `ecom-py/settings_manager.py` |
| `config` module | Computes runtime paths (`BASE_DIR`, `VIDEO_STORAGE_PATH`, `DATABASE_PATH`, `LOG_PATH`) from `SettingsManager`, exposes module-level constants, `reload_config()` | `ecom-py/config.py` |
| `camera_utils` | Cross-platform camera enumeration (DirectShow/pygrabber on Windows, v4l2 on Linux, `system_profiler` on macOS) with a 30s cache | `ecom-py/camera_utils.py` |
| Standalone utility scripts | Not wired into the app: bulk offline video compression tool, one-off watermarking script, ROM/game directory scanner | `ecom-py/bulk_compressor.py`, `ecom-py/add_watermark.py`, `ecom-py/game_scanner.py` |

## Pattern Overview

**Overall:** Layered, script-style monolith with two parallel presentation layers (Tkinter desktop app and Flask web app) sharing one set of backend "handler" classes. There is no MVC framework, dependency-injection container, or web framework abstraction beyond Flask's routing — each entry point directly instantiates `CameraHandler`, `BarcodeHandler`, `Database`, and `VideoCompressor` as module-level (Flask) or instance-level (Tkinter) objects.

**Key Characteristics:**
- No ORM — raw `sqlite3` with hand-written SQL in `database.py`.
- No REST framework beyond Flask's built-in `@app.route` decorators; requests/responses are plain `jsonify()` dicts.
- Threading is used pervasively for non-blocking I/O: camera frame capture, video writing, and FFmpeg compression each run on dedicated background threads.
- Configuration is loaded once at import time into `config.py` module-level globals, backed by `SettingsManager` (JSON file), and can be reloaded at runtime via `config.reload_config()` or `importlib.reload(config)`.
- Business logic (barcode state machine, recording state machine) is duplicated at the call-site in both `app.py` and `app_gui.py` — both call the same `BarcodeHandler.process_barcode()` / `CameraHandler.start_recording()/stop_recording()` API but each re-implements the surrounding orchestration (transaction creation, compression queuing, UI/JSON response building).

## Layers

**Presentation (Desktop):**
- Purpose: Renders the Tkinter UI, wires button/keyboard events to handler calls, updates widgets on a Tkinter `after()` polling loop.
- Location: `ecom-py/app_gui.py` (2491 lines; classes `EcomVideoTrackerApp`, `SearchWindow`, `SettingsDialog`, `SavingProgressDialog`)
- Contains: Widget construction (`create_*` methods), event handlers, camera-feed polling (`update_camera_feed`), recording orchestration (`process_barcode`, `_stop_recording_with_progress`).
- Depends on: `camera_handler`, `barcode_handler`, `database`, `video_compressor`, `config`, `settings_manager`, `camera_utils`.
- Used by: End users running `python app_gui.py` (or `run_gui.bat`).

**Presentation (Web):**
- Purpose: Serves HTML/JS/CSS and exposes a JSON + MJPEG API consumed by `static/js/script.js`.
- Location: `ecom-py/app.py` (Flask routes), `ecom-py/templates/index.html`, `ecom-py/static/js/script.js`, `ecom-py/static/css/style.css`.
- Contains: Route handlers for status, barcode processing, search, settings, camera list, compression status, video streaming/serving.
- Depends on: Same handler layer as the desktop GUI.
- Used by: Browser clients connecting to `http://<FLASK_HOST>:<FLASK_PORT>`.

**Service / Handler:**
- Purpose: Encapsulates camera I/O, barcode state transitions, and background video compression — independent of which presentation layer calls it.
- Location: `ecom-py/camera_handler.py`, `ecom-py/barcode_handler.py`, `ecom-py/video_compressor.py`, `ecom-py/camera_utils.py`.
- Contains: Threaded camera capture/record loops, FFmpeg subprocess management, camera enumeration.
- Depends on: `config` (for paths/settings), OpenCV (`cv2`), FFmpeg binary on `PATH` or bundled `ffmpeg/bin/ffmpeg.exe`.
- Used by: Both presentation layers.

**Persistence / Config:**
- Purpose: Durable storage for transaction history (SQLite) and user-editable settings (JSON).
- Location: `ecom-py/database.py`, `ecom-py/settings_manager.py`, `ecom-py/config.py`.
- Contains: SQL schema/queries, JSON load/save/deep-merge, path normalization (handles PyInstaller frozen-exe base dir).
- Depends on: Filesystem (`database.db`, `settings.json`, `videos/`, `logs/`).
- Used by: Service layer and presentation layer directly (both `app.py` and `app_gui.py` instantiate `Database()` themselves).

## Data Flow

### Primary Request Path (Web — barcode scan)

1. Browser POSTs `{barcode}` to `/api/barcode` (`ecom-py/app.py:123`).
2. `barcode_handler.process_barcode(barcode, camera.is_recording())` determines the action (`ecom-py/barcode_handler.py:57`).
3. On `start`: `camera.start_recording(barcode)` opens a `cv2.VideoWriter`, spawns a `_record_frames` thread that drains `frame_buffer` (`ecom-py/camera_handler.py:349`, `:464`); `db.create_transaction()` inserts a row (`ecom-py/database.py:72`).
4. On `stop_and_start`: `camera.stop_recording()` flushes the buffer, releases the writer, returns duration/size (`ecom-py/camera_handler.py:491`); `db.complete_transaction()` updates the row (`ecom-py/database.py:103`); `queue_video_compression()` enqueues the finished file (`ecom-py/app.py:67`); a new recording starts immediately.
5. Response JSON is returned to the browser; `static/js/script.js` updates the UI (recording indicator, recent list).

### Primary Request Path (Desktop GUI — barcode scan)

1. User types/scans into the barcode `Entry` widget and presses Enter → `process_barcode()` (`ecom-py/app_gui.py:680`).
2. Same `BarcodeHandler.process_barcode()` call determines the action.
3. `stop`/`stop_and_start` actions route through `_stop_recording_with_progress()` (`ecom-py/app_gui.py:763`), which runs `camera.stop_recording()` on a background thread while a modal `SavingProgressDialog` keeps the Tkinter mainloop responsive.
4. `db.create_transaction()` / `db.complete_transaction()` update SQLite directly (same `Database` class, separate instance from the Flask app's).
5. `self.queue_video_compression()` enqueues the file with the GUI's own `VideoCompressor` instance (`ecom-py/app_gui.py:1033`).
6. `load_recordings()` refreshes the on-screen recent-recordings list from `db.get_recent_transactions()`.

### Background Compression Flow

1. `queue_video_compression()` (in `app.py` or `app_gui.py`) calls `compressor.queue_compression(video_path, transaction_id, settings)`.
2. `VideoCompressor._worker_loop` (dedicated daemon thread) pulls `CompressionJob`s off a `queue.Queue` one at a time and shells out to `ffmpeg` via `subprocess` with Windows priority flags applied (`ecom-py/video_compressor.py:17`, `:43`).
3. On completion, the registered `on_complete(transaction_id, success, result_data)` callback is invoked, which calls `db.update_compression_status()` (`ecom-py/database.py:342`) to persist compression outcome.

### Camera Frame Flow

1. `CameraHandler.initialize_camera()` opens `cv2.VideoCapture` (MSMF backend on Windows) and starts `_capture_frames` as a daemon thread (`ecom-py/camera_handler.py:54`, `:101`).
2. `_capture_frames` continuously reads frames, updates `self.latest_frame` under `frame_lock`, tracks measured FPS, and — only while `self.recording` is true — appends `(frame, timestamp)` to a bounded `deque` (`frame_buffer`, maxlen 60) under `buffer_lock`.
3. UI polling (`get_preview_frame`) and MJPEG streaming (`generate_frames`) read `latest_frame` independently of recording state, so live preview keeps working even when idle.
4. While recording, `_record_frames` (separate thread, started in `start_recording`) drains `frame_buffer`, resizes/watermarks each frame, and writes it to `cv2.VideoWriter`.
5. Camera failures trigger automatic reinitialization with a cooldown (`_try_reinitialize_camera`) to recover from disconnects.

**State Management:**
- Recording state lives entirely inside `CameraHandler` instance attributes (`self.recording`, `self.current_filename`, `self.current_transaction_id` tracked separately in each entry-point module as a module/instance variable — `current_transaction_id` global in `app.py`, `self.current_transaction_id` in `app_gui.py`).
- No shared state store between the Flask process and the Tkinter process — running both simultaneously against the same `database.db` and camera index will conflict (both try to open the same camera index and write to the same SQLite file, though SQLite provides per-connection locking).
- Settings state is process-local: `config.py` loads `SettingsManager` once at import; changes made via one running instance's Settings dialog do not propagate to another already-running instance until it calls `reload_config()`/restarts.

## Key Abstractions

**Handler classes (`*Handler`):**
- Purpose: Wrap a single external resource (camera, barcode input) behind a small, presentation-agnostic API.
- Examples: `CameraHandler` (`ecom-py/camera_handler.py`), `BarcodeHandler` (`ecom-py/barcode_handler.py`).
- Pattern: Instantiated once per process (per Flask app / per Tkinter app instance), holds threading primitives internally, exposes synchronous methods (`start_recording`, `stop_recording`, `process_barcode`) that presentation code calls directly (no event bus/observer pattern).

**Background worker with queue + callback (`VideoCompressor`):**
- Purpose: Decouple slow FFmpeg encoding from the request/UI thread.
- Examples: `ecom-py/video_compressor.py`.
- Pattern: `queue.Queue` + dedicated daemon `threading.Thread` running `_worker_loop`; results delivered via an injected `on_complete` callback rather than a return value, since the caller isn't blocking.

**Row-dict database access (`Database`):**
- Purpose: Simple data-access layer without an ORM.
- Examples: `ecom-py/database.py`.
- Pattern: Each method opens its own `sqlite3.connect()`, uses `conn.row_factory = sqlite3.Row` to return `dict`-like rows, and closes the connection before returning — no persistent connection pool or context manager reuse.

**Settings persistence (`SettingsManager`):**
- Purpose: Typed, defaulted, deep-mergeable JSON config.
- Examples: `ecom-py/settings_manager.py`, `ecom-py/settings.json.example`.
- Pattern: Class-level `DEFAULT_SETTINGS` dict merged with any on-disk `settings.json` via `_deep_merge`; convenience getters (`get_video_resolution()`, `get_camera_index()`, etc.) wrap the generic `get(category, key, default)`.

## Entry Points

**Desktop GUI:**
- Location: `ecom-py/app_gui.py` (`main()` at line 2483, run via `python app_gui.py` or `run_gui.bat`)
- Triggers: User double-clicks `run_gui.bat` or runs the script directly.
- Responsibilities: Builds the Tkinter root window, instantiates `EcomVideoTrackerApp`, starts the Tkinter mainloop.

**Web Application:**
- Location: `ecom-py/app.py` (`if __name__ == '__main__':` block at line 452, run via `python app.py` or `run_web.bat`)
- Triggers: User double-clicks `run_web.bat` or runs the script directly; listens on `config.FLASK_HOST:FLASK_PORT` (default `0.0.0.0:5000` per `config.py`, but `127.0.0.1:5000` per `settings_manager.py` defaults/`settings.json.example`).
- Responsibilities: Initializes Flask app, handler singletons (`camera`, `barcode_handler`, `db`, `compressor`), registers routes and `atexit` cleanup, starts the Flask dev server (`threaded=True`).

**Standalone Tools (not part of the two apps above):**
- `ecom-py/bulk_compressor.py` — separate Tkinter app for batch-compressing arbitrary video files (`main()`-style, run directly or via `build_compressor.py` → PyInstaller exe).
- `ecom-py/add_watermark.py` — one-off script that rotates and watermarks a single hardcoded input file (`to_modify.mp4`).
- `ecom-py/game_scanner.py` — unrelated CLI utility for scanning/comparing ROM directories; shares no imports with the video tracker modules.

## Architectural Constraints

- **Threading:** Each `CameraHandler` instance runs at least two long-lived daemon threads (`_capture_frames`, and `_record_frames` while recording); `VideoCompressor` runs one worker thread per instance; Tkinter itself is single-threaded and must only be touched from the main thread — `app_gui.py` uses `dialog.update()` calls and background `threading.Thread` + polling (not `after()` callbacks) to avoid freezing the UI during stop/save (`_stop_recording_with_progress`, `ecom-py/app_gui.py:763`).
- **Global/module state:** `config.py` holds process-wide mutable globals (`VIDEO_STORAGE_PATH`, `DATABASE_PATH`, `CAMERA_INDEX`, etc.) re-assigned by `reload_config()`; `app.py` has a module-level `current_transaction_id` global. `camera_utils.py` has a module-level `_camera_cache` protected by `_cache_lock`.
- **Dual, un-synchronized instances:** `app.py` and `app_gui.py` each construct their own `CameraHandler`, `Database`, and `VideoCompressor`. Running both processes concurrently against the same camera index and `database.db` is unsupported (camera device contention; no cross-process locking beyond SQLite's own).
- **Frozen-exe path handling:** `config.py` detects `sys.frozen` (PyInstaller) and rebases `BASE_DIR` to the executable's directory instead of the script's — any new path-dependent code must follow this same `getattr(sys, 'frozen', False)` check rather than hardcoding `os.path.dirname(__file__)`.
- **No circular imports observed** — dependency direction is strictly presentation → handler → config/database, with `config.py` importing only `settings_manager`.

## Anti-Patterns

### Duplicated orchestration logic between `app.py` and `app_gui.py`

**What happens:** The barcode-scan orchestration (create transaction → start recording → on stop, complete transaction → queue compression → start next recording) is implemented twice, once in Flask route handlers (`ecom-py/app.py:123-218`) and once in Tkinter's `process_barcode`/`_stop_recording_with_progress` (`ecom-py/app_gui.py:680-830`).
**Why it's wrong:** Any change to the recording/transaction/compression workflow (e.g., new compression trigger condition, new transaction field) must be updated in two places; the two implementations have already drifted (e.g., Web `queue_video_compression` is a bare function, GUI version is a bound method with slightly different signature defaults).
**Do this instead:** Extract a single `RecordingSession`/`RecordingOrchestrator` class in a shared module that both `app.py` and `app_gui.py` call, keeping only UI-specific glue (JSON serialization vs. widget updates) in each entry point.

### Per-call SQLite connections without pooling or context managers

**What happens:** Every method in `Database` (`ecom-py/database.py`) opens a fresh `sqlite3.connect(self.db_path)`, executes, and manually calls `conn.close()` — with no `try/finally` guaranteeing closure if an exception occurs mid-method (some paths do `except Exception` and return early without closing).
**Why it's wrong:** Under bursty write load (rapid consecutive barcode scans) this creates connection churn overhead and risks leaking open file handles/locks if a query throws after `get_connection()` but before `conn.close()`.
**Do this instead:** Use `with sqlite3.connect(...) as conn:` or a small context-manager wrapper to guarantee cleanup, and consider a single long-lived connection with `check_same_thread=False` plus an explicit lock if cross-thread access is required.

## Error Handling

**Strategy:** Broad `try/except Exception` blocks at nearly every method boundary, logged via the module-level `logger` and either re-raised (handler layer, so callers can react) or converted to a JSON `{'error': ...}` / `messagebox.showerror` (presentation layer). There is no custom exception hierarchy — generic `Exception` is raised for domain errors like "Already recording" (`ecom-py/camera_handler.py:362`) and "Not currently recording" (`:500`).

**Patterns:**
- Service layer (`CameraHandler`, `Database`, `VideoCompressor`) logs and re-raises (or returns a safe default like `[]`/`0.0` for read-only queries) so callers decide user-facing behavior.
- Flask routes catch at the route level and return `jsonify({'error': str(e)}), 500` (`ecom-py/app.py`).
- Tkinter handlers catch at the event-handler level and show `messagebox.showerror(...)` (`ecom-py/app_gui.py`).
- Camera read failures are handled specially with a consecutive-failure counter and automatic reinitialization rather than raising (`ecom-py/camera_handler.py:151-163`).

## Cross-Cutting Concerns

**Logging:** Standard library `logging`, configured identically (and independently) in both `app.py` and `app_gui.py` via `logging.basicConfig(..., handlers=[FileHandler(config.LOG_FILE), StreamHandler()])`. Every module obtains its own `logger = logging.getLogger(__name__)`. Log level is fixed at `DEBUG` (`config.LOG_LEVEL`), not user-configurable through the Settings UI.

**Validation:** Minimal and ad hoc — `BarcodeHandler.validate_barcode()` only checks non-empty/string; `Database.advanced_search()` whitelists `sort_by` against a hardcoded column list to avoid SQL injection via ORDER BY; no request schema validation library is used for Flask JSON bodies (`request.get_json()` is trusted directly).

**Authentication:** None. Flask has no auth/session layer; README explicitly documents this as a known limitation (`FLASK_HOST` defaults differ between `config.py` — `0.0.0.0` — and `settings_manager.py` defaults/`settings.json.example` — `127.0.0.1` — worth reconciling since `0.0.0.0` exposes the unauthenticated API to the network).

---

*Architecture analysis: 2026-07-11*
