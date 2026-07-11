<!-- GSD:project-start source:PROJECT.md -->
## Project

**Ecom Video Tracker — Flutter Port**

A Flutter for Windows desktop application that ports the existing Python/Tkinter Ecom Video Tracker GUI feature-for-feature. It records barcode-triggered videos of e-commerce products: scan a barcode to start recording, scan the next barcode to stop-and-save the previous video and immediately begin the next — a continuous scanning workflow for packing/tracking stations. The new app lives in `ecom-flutter/`, alongside the reference Python implementation in `ecom-py/`.

**Core Value:** The continuous scan → record → save loop must work flawlessly: every scanned barcode reliably stops the previous recording, saves it under the correct name, and starts a new one without missing frames or losing videos.

### Constraints

- **Platform**: Windows 10/11 desktop — the deployment target; Flutter does not support Win7
- **Tech stack**: Flutter (Dart) — chosen for UI quality, packaging, startup speed, and future mobile reuse
- **Parity**: Behavior must match ecom-py desktop GUI — operators should not need retraining; file naming, folder layout, and DB schema should remain compatible
- **Dependencies**: FFmpeg required at runtime for compression (bundle or document, as in the Python app)
- **Data compatibility**: SQLite schema and video folder structure should match ecom-py so existing archives remain searchable
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Python 3.11+ (declared in `ecom-py/pyproject.toml`, pinned via `ecom-py/.python-version`) - All application logic (Tkinter desktop GUI, Flask web app, video/camera handling, database access)
- README states "Python 3.10 or higher" (`ecom-py/README.md:26`) — slightly looser than `pyproject.toml`'s `>=3.11`; treat 3.11 as the effective floor.
- HTML/CSS/JavaScript (vanilla, no framework/bundler) - Flask web UI in `ecom-py/templates/index.html`, `ecom-py/static/css/style.css`, `ecom-py/static/js/script.js`
- Batch scripting (`.bat`) - Windows install/run/build automation: `ecom-py/install.bat`, `ecom-py/run_gui.bat`, `ecom-py/run_web.bat`, `ecom-py/build_exe.bat`, `ecom-py/install_camera_support.bat`, `ecom-py/install_tkcalendar.bat`
- SQL (embedded in Python strings) - Schema and queries in `ecom-py/database.py`
## Runtime
- CPython 3.11+ (project pins `.python-version` to `3.11`; local dev machine observed running Python 3.12.3)
- Windows is the primary target platform (camera backend selection, process-priority flags, `.bat` launchers, PyInstaller `.exe` packaging all assume Windows); Linux/macOS code paths exist as fallbacks (see `ecom-py/camera_utils.py`, `ecom-py/camera_handler.py`)
- pip (`ecom-py/requirements.txt`, pinned versions) is the primary documented path
- `uv` is offered as a faster alternative (`ecom-py/README.md:39-49`), but no `uv.lock` is committed (`.gitignore` excludes `uv.lock`)
- Lockfile: missing/not committed. `requirements.txt` uses exact `==` pins instead, `pyproject.toml` uses `>=` floors — the two files are not fully synchronized (e.g. `pyproject.toml` requires `opencv-python>=4.12.0.88` and `pillow>=12.1.0`, while `requirements.txt` pins `opencv-python==4.9.0.80` and `Pillow==10.2.0`)
## Frameworks
- Flask 3.0.0 (`requirements.txt`) / `>=3.1.2` (`pyproject.toml`) - Web application framework, serves REST API + HTML UI (`ecom-py/app.py`)
- Tkinter (Python stdlib, no version pin) - Desktop GUI framework, primary/recommended interface (`ecom-py/app_gui.py`, 2491 lines)
- OpenCV (`opencv-python` 4.9.0.80 / `>=4.12.0.88`) - Camera capture, video encoding/writing, frame processing, on-frame watermarking (`ecom-py/camera_handler.py`, `ecom-py/camera_utils.py`)
- None detected. No `pytest`, `unittest` test files, or test configuration found anywhere in `ecom-py/`.
- PyInstaller 6.3.0 (`requirements.txt`) / `>=6.3.0`(unspecified in pyproject, present in requirements only) - Packages `app_gui.py` (and `bulk_compressor.py`) into standalone Windows `.exe` files. See `ecom-py/build_exe.bat` and `ecom-py/build_compressor.py`.
- FFmpeg (external binary, not a Python package) - Invoked via `subprocess`/`Popen` for background video compression (`ecom-py/video_compressor.py`), standalone watermarking (`ecom-py/add_watermark.py`), and bulk compression tool (`ecom-py/bulk_compressor.py`). Not vendored; must be installed separately or placed in common lookup paths.
## Key Dependencies
- `opencv-python` (cv2) - Camera I/O (`cv2.VideoCapture`), video encoding (`cv2.VideoWriter`), JPEG frame encoding for MJPEG streaming, on-frame text/rectangle drawing for watermarks
- `Flask` - HTTP server, routing, JSON API, Jinja2 templating (bundled with Flask) for `templates/index.html`
- `Pillow` (PIL) - Image conversion for Tkinter preview widgets (`ImageTk.PhotoImage`) in `ecom-py/app_gui.py`
- `tkcalendar` 1.6.1 - Calendar date-picker widget (`DateEntry`) used in desktop GUI search dialogs (`ecom-py/app_gui.py`)
- `pygrabber` 0.2 (Windows only, `sys_platform == 'win32'` marker in `requirements.txt`) - DirectShow-based camera name enumeration on Windows (`ecom-py/camera_utils.py`)
- `pyinstaller` 6.3.0 - Executable packaging (build-time only, not a runtime dependency)
- Python stdlib `sqlite3` - Embedded database driver (no external DB dependency)
- Python stdlib `subprocess`, `threading`, `queue` - Process management for FFmpeg calls and background worker threads (compression queue, camera capture thread, recording thread)
- Optional/soft dependencies referenced only in fallback code paths (not declared in `requirements.txt`/`pyproject.toml`, imported defensively with `try/except ImportError`): `winreg` (Windows registry camera name lookup), `wmi` (Windows Management Instrumentation camera lookup) — see `ecom-py/camera_utils.py:240-314`
## Configuration
- No `.env` files or environment-variable-based configuration detected. Configuration is entirely file-based:
- Base directory resolution handles both script mode and PyInstaller-frozen `.exe` mode (`ecom-py/config.py:6-11`) — uses `sys.executable`'s directory when frozen, `__file__`'s directory otherwise
- Key configurable values: `flask_host` (default `127.0.0.1`), `flask_port` (default `5000`), `debug_mode`, video resolution/fps/codec, camera index and exposure/gain/brightness, storage paths, and compression codec/CRF/preset/priority
- `ecom-py/pyproject.toml` - Project metadata and dependency floors (PEP 621 style, no build-backend section — not currently used to build a distributable package, just dependency declaration)
- `ecom-py/requirements.txt` - Pinned dependency versions used by `pip install -r requirements.txt`
- `ecom-py/build_exe.bat` - PyInstaller command for desktop GUI exe (`--onefile --windowed`, bundles `config.py` as data, hidden-imports PIL)
- `ecom-py/build_compressor.py` - Python-driven PyInstaller build for the standalone `BulkVideoCompressor.exe` tool
## Platform Requirements
- Python 3.11+ interpreter
- Webcam (built-in or USB) for camera-dependent features
- FFmpeg binary (optional at dev time; compression silently skips/fails without it, see `ecom-py/video_compressor.py:84-160`)
- Git (for cloning/version control only)
- Windows is the de facto deployment target: `.bat` launch scripts, PyInstaller `--windowed` Windows executables, Windows-specific process-priority flags (`CREATE_NO_WINDOW`, `IDLE_PRIORITY_CLASS`, etc. in `ecom-py/video_compressor.py:17-22`), MSMF camera backend preference, and `pygrabber`/`winreg`/`wmi` camera-name lookups all indicate Windows 10/11 desktop deployment
- No containerization (no `Dockerfile`/`docker-compose.yml` found)
- No cloud hosting configuration — Flask app is designed to run locally (`FLASK_HOST` default `127.0.0.1`) or on a local network (`0.0.0.0`), not behind a reverse proxy or WSGI production server (uses Flask's built-in dev server via `app.run(...)` in `ecom-py/app.py:457-462`, no gunicorn/waitress/uwsgi dependency)
- Local filesystem storage only: videos under `ecom-py/videos/<date>/<label>/`, SQLite file at `ecom-py/database.db`, logs at `ecom-py/logs/app.log` — all paths configurable but default to relative paths beside the executable/script
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Scope
## Naming Patterns
- `snake_case.py` for all modules: `camera_handler.py`, `barcode_handler.py`, `video_compressor.py`, `settings_manager.py`, `camera_utils.py`.
- Module name mirrors the primary class it exports (e.g., `camera_handler.py` → `CameraHandler`, `settings_manager.py` → `SettingsManager`).
- Two parallel entry points at the root: `app.py` (Flask web server) and `app_gui.py` (Tkinter desktop app). Both wire up the same core modules (`camera_handler`, `barcode_handler`, `database`, `video_compressor`, `config`).
- `PascalCase` throughout: `CameraHandler`, `BarcodeHandler`, `Database`, `VideoCompressor`, `SettingsManager`, `SavingProgressDialog`, `EcomVideoTrackerApp`, `SearchWindow`, `SettingsDialog` (all in `ecom-py/app_gui.py`).
- Enum classes use `PascalCase` with `UPPER_CASE` string-valued members, e.g. `CompressionStatus(Enum)` in `ecom-py/video_compressor.py:25` (`PENDING = "pending"`, `PROCESSING = "processing"`, etc.).
- `@dataclass` used for simple job/record structs, e.g. `CompressionJob` in `ecom-py/video_compressor.py:34-40` and a duplicate/independent `CompressionJob` in `ecom-py/bulk_compressor.py:27`.
- `snake_case` for all functions and methods: `get_available_cameras`, `process_barcode`, `start_recording`, `queue_video_compression`.
- Private/internal helpers prefixed with a single underscore: `_start_capture_thread`, `_stop_capture_thread`, `_capture_frames`, `_try_reinitialize_camera` (`ecom-py/camera_handler.py`), `_deep_merge` (`ecom-py/settings_manager.py:109`), `_worker_loop` (`ecom-py/video_compressor.py`).
- Boolean-returning predicates prefixed `is_`: `is_start_code`, `is_stop_code`, `is_recording` (`ecom-py/barcode_handler.py`, `ecom-py/camera_handler.py`).
- Flask route handlers are plain descriptive verbs matching the resource: `get_status`, `process_barcode`, `manual_stop`, `get_recordings`, `search_recordings` (`ecom-py/app.py`).
- `snake_case` for locals and instance attributes: `video_filename`, `transaction_id`, `current_label_folder`.
- Module-level "private" config intermediates prefixed with underscore: `_settings`, `_video_path`, `_db_path`, `_log_path` in `ecom-py/config.py`.
- Constants (module-level config values) are `UPPER_SNAKE_CASE`: `VIDEO_CODEC`, `VIDEO_FPS`, `MAX_STORAGE_GB`, `BARCODE_START_PREFIX`, `BARCODE_TIMEOUT_SECONDS` in `ecom-py/config.py`.
- Threading primitives are named for their purpose, not generically: `self.lock`, `self.frame_lock`, `self.buffer_lock`, `self._reinit_lock` (`ecom-py/camera_handler.py`).
- No custom type aliases. Typing relies on `typing.Optional`, `typing.List`, `typing.Dict`, `typing.Callable`, `typing.Tuple` directly at call sites (`ecom-py/database.py:4`, `ecom-py/video_compressor.py:11`).
## Code Style
- No formatter config detected (no `.black`, `pyproject.toml` `[tool.black]`, `.ruff.toml`, or `.flake8`). Formatting is manual/by convention, 4-space indentation, no semicolons.
- `ecom-py/pyproject.toml` only declares `[project]` metadata and dependencies — no lint/format tool sections.
- No linter configured. Do not assume `ruff`/`flake8`/`pylint` will run in CI — there is no CI (`.github/workflows` not present).
- Standard PEP 8-ish style predominates in most modules (`database.py`, `settings_manager.py`, `barcode_handler.py`, `camera_handler.py`).
- `ecom-py/add_watermark.py` is a standalone utility script with a distinct, more compact style (aligned `=` signs for constant blocks, box-drawing comment separators `# ── Config ────...`). Treat this file as a one-off tool, not representative of core conventions — do not copy its alignment style into core modules.
## Import Organization
- None. All local imports are flat, unqualified module imports (no package structure, no `src/` layout — every module lives directly in `ecom-py/`).
- Local imports occasionally happen mid-function rather than at module top when avoiding overhead or circularity, e.g. `from datetime import datetime` inside `queue_video_compression()` in `ecom-py/app.py:71` even though `datetime` patterns are typically imported at top-of-file elsewhere.
## Error Handling
- `ecom-py/camera_handler.py:178,616,634`
- `ecom-py/app_gui.py:102,610,1069,2386`
- `ecom-py/video_compressor.py:334`
- `ecom-py/camera_utils.py:269,276,296,299`
- `ecom-py/bulk_compressor.py:94,322,431,563`
- `ecom-py/game_scanner.py:38,49,69,79`
- Input validation returns early with a boolean or structured result rather than raising, e.g. `BarcodeHandler.validate_barcode()` (`ecom-py/barcode_handler.py:11-31`) returns `False` for invalid input; `process_barcode()` returns `{'action': 'invalid', 'barcode': barcode}` rather than throwing.
- Flask routes validate request payloads manually and return `400` with a JSON `{'error': '...'}` body for bad input (`ecom-py/app.py:132-133`, `ecom-py/app.py:279-280`).
## Logging
- `logger.info(...)` for normal lifecycle/state-transition events (recording started/stopped, settings saved, DB initialized).
- `logger.warning(...)` for recoverable/unexpected-but-non-fatal conditions (invalid barcode, camera read failures, compression failure).
- `logger.error(...)` inside every `except Exception as e:` block, always with the caught exception interpolated via f-string: `logger.error(f"Error X: {e}")`.
- No `logger.debug()` usage observed in core modules despite `LOG_LEVEL = 'DEBUG'` being the default — debug-level detail is not currently emitted.
## Comments
- Section-divider comments used to group related config/logic blocks, e.g. `# Video Settings (dynamically loaded from settings)`, `# Storage (dynamically loaded from settings) - normalize all paths` in `ecom-py/config.py`.
- Inline comments explain *why*, not *what*, especially around platform-specific or non-obvious tradeoffs: `# MSMF is Microsoft's modern camera API with better performance than DirectShow` (`ecom-py/camera_handler.py:58`), `# Set buffer size to minimum to reduce latency` (`ecom-py/camera_handler.py:76`).
- TODO-style markers are rare; the project instead tracks future work in `ecom-py/README.md` under a "Roadmap" checklist rather than inline `# TODO` comments.
- Every class and public method has a docstring. Short one-liners for simple accessors: `"""Get a database connection."""` (`ecom-py/database.py:16`).
- Multi-line Google-style docstrings with `Args:` / `Returns:` sections for anything with parameters or a non-trivial return value:
- Module-level docstrings used for standalone-purpose files: `"""Settings Manager - Handle application configuration with JSON persistence"""` (`ecom-py/settings_manager.py:1-3`), `"""Video Compressor - Background compression worker using FFmpeg"""` (`ecom-py/video_compressor.py:1-3`), `"""Camera Utilities - Detect and enumerate available cameras"""` (`ecom-py/camera_utils.py:1-3`).
## Function Design
- Type-hinted parameters with defaults for optional values: `def create_transaction(self, barcode: str, video_filename: str, label: str = "Normal (Standard)") -> int`.
- Multi-parameter methods with several optional filters use one parameter per line for readability when the signature is long, e.g. `advanced_search(...)` in `ecom-py/database.py:247-257`.
- Callbacks passed as `Optional[Callable]` with the expected signature documented in the docstring rather than enforced by typing, e.g. `on_complete` in `ecom-py/video_compressor.py:46-53`.
- Read/query methods on `Database` return `List[Dict]` or `Optional[Dict]` (never raise on "not found" — return `None` or `[]`) (`ecom-py/database.py:140,170`).
- Action-processing methods return small structured `dict` results describing what happened, e.g. `{'action': 'start', 'barcode': barcode}` from `BarcodeHandler.process_barcode()` (`ecom-py/barcode_handler.py:57-85`) and `{'action': 'stopped', 'filename': ..., 'duration': ..., ...}` from `camera.stop_recording()` consumers in `ecom-py/app.py`.
- Boolean success/failure returns for operations with no natural payload, e.g. `SettingsManager.save_settings() -> bool` (`ecom-py/settings_manager.py:72-81`).
## Module Design
- No `__all__` declarations; modules export via plain top-level class/function definitions. Consumers import specific names: `from camera_handler import CameraHandler`, `from database import Database`.
- No package (`__init__.py`) structure — `ecom-py/` is a flat directory of top-level modules imported directly by both `app.py` and `app_gui.py`.
- `config.py` acts as an implicit global singleton: it instantiates `_settings = SettingsManager(...)` at import time and exposes both static-looking constants (`VIDEO_CODEC`, `DATABASE_PATH`, etc.) and the live `settings_manager` object for runtime mutation. `config.reload_config()` (`ecom-py/config.py:55-79`) mutates module-level globals via the `global` keyword — be aware config values are re-read, not re-imported, when settings change.
- `ecom-py/app.py` and `ecom-py/app_gui.py` each construct their own `CameraHandler`, `BarcodeHandler`, `Database`, `VideoCompressor` instances at startup/`__init__` — these are not shared singletons across the two entry points (the GUI and the web app are never run in the same process).
- Background work uses raw `threading.Thread(..., daemon=True)` plus `threading.Lock()` / `threading.Event`-style flags, not `asyncio` or `concurrent.futures`. See `CameraHandler._start_capture_thread` (`ecom-py/camera_handler.py:101-109`) and `VideoCompressor.start()` (`ecom-py/video_compressor.py:63-71`), which both spawn a single dedicated worker thread and communicate via a `queue.Queue` (compressor) or locked shared state (camera frame buffer).
- Follow this pattern for new background work: one daemon thread + explicit lock/queue for cross-thread state, not new concurrency primitives.
## Settings & Configuration Pattern
- All user-configurable values live in `ecom-py/settings_manager.py`'s `SettingsManager.DEFAULT_SETTINGS` dict, organized by category (`video`, `camera`, `storage`, `app`, `compression`). New settings should be added as a new key under the appropriate category plus a `get_x()`/`set_x()` convenience method following the existing naming pattern (`get_video_fps`, `get_camera_index`, etc.).
- `ecom-py/config.py` is a thin, import-time-evaluated projection of `SettingsManager` onto module-level constants for convenient `import config; config.VIDEO_FPS` access elsewhere. When adding a new setting that other modules need as a constant, add it to both `SettingsManager.DEFAULT_SETTINGS`/getter and to `config.py`'s constant assignment + `reload_config()`.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## System Overview
```text
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
- No ORM — raw `sqlite3` with hand-written SQL in `database.py`.
- No REST framework beyond Flask's built-in `@app.route` decorators; requests/responses are plain `jsonify()` dicts.
- Threading is used pervasively for non-blocking I/O: camera frame capture, video writing, and FFmpeg compression each run on dedicated background threads.
- Configuration is loaded once at import time into `config.py` module-level globals, backed by `SettingsManager` (JSON file), and can be reloaded at runtime via `config.reload_config()` or `importlib.reload(config)`.
- Business logic (barcode state machine, recording state machine) is duplicated at the call-site in both `app.py` and `app_gui.py` — both call the same `BarcodeHandler.process_barcode()` / `CameraHandler.start_recording()/stop_recording()` API but each re-implements the surrounding orchestration (transaction creation, compression queuing, UI/JSON response building).
## Layers
- Purpose: Renders the Tkinter UI, wires button/keyboard events to handler calls, updates widgets on a Tkinter `after()` polling loop.
- Location: `ecom-py/app_gui.py` (2491 lines; classes `EcomVideoTrackerApp`, `SearchWindow`, `SettingsDialog`, `SavingProgressDialog`)
- Contains: Widget construction (`create_*` methods), event handlers, camera-feed polling (`update_camera_feed`), recording orchestration (`process_barcode`, `_stop_recording_with_progress`).
- Depends on: `camera_handler`, `barcode_handler`, `database`, `video_compressor`, `config`, `settings_manager`, `camera_utils`.
- Used by: End users running `python app_gui.py` (or `run_gui.bat`).
- Purpose: Serves HTML/JS/CSS and exposes a JSON + MJPEG API consumed by `static/js/script.js`.
- Location: `ecom-py/app.py` (Flask routes), `ecom-py/templates/index.html`, `ecom-py/static/js/script.js`, `ecom-py/static/css/style.css`.
- Contains: Route handlers for status, barcode processing, search, settings, camera list, compression status, video streaming/serving.
- Depends on: Same handler layer as the desktop GUI.
- Used by: Browser clients connecting to `http://<FLASK_HOST>:<FLASK_PORT>`.
- Purpose: Encapsulates camera I/O, barcode state transitions, and background video compression — independent of which presentation layer calls it.
- Location: `ecom-py/camera_handler.py`, `ecom-py/barcode_handler.py`, `ecom-py/video_compressor.py`, `ecom-py/camera_utils.py`.
- Contains: Threaded camera capture/record loops, FFmpeg subprocess management, camera enumeration.
- Depends on: `config` (for paths/settings), OpenCV (`cv2`), FFmpeg binary on `PATH` or bundled `ffmpeg/bin/ffmpeg.exe`.
- Used by: Both presentation layers.
- Purpose: Durable storage for transaction history (SQLite) and user-editable settings (JSON).
- Location: `ecom-py/database.py`, `ecom-py/settings_manager.py`, `ecom-py/config.py`.
- Contains: SQL schema/queries, JSON load/save/deep-merge, path normalization (handles PyInstaller frozen-exe base dir).
- Depends on: Filesystem (`database.db`, `settings.json`, `videos/`, `logs/`).
- Used by: Service layer and presentation layer directly (both `app.py` and `app_gui.py` instantiate `Database()` themselves).
## Data Flow
### Primary Request Path (Web — barcode scan)
### Primary Request Path (Desktop GUI — barcode scan)
### Background Compression Flow
### Camera Frame Flow
- Recording state lives entirely inside `CameraHandler` instance attributes (`self.recording`, `self.current_filename`, `self.current_transaction_id` tracked separately in each entry-point module as a module/instance variable — `current_transaction_id` global in `app.py`, `self.current_transaction_id` in `app_gui.py`).
- No shared state store between the Flask process and the Tkinter process — running both simultaneously against the same `database.db` and camera index will conflict (both try to open the same camera index and write to the same SQLite file, though SQLite provides per-connection locking).
- Settings state is process-local: `config.py` loads `SettingsManager` once at import; changes made via one running instance's Settings dialog do not propagate to another already-running instance until it calls `reload_config()`/restarts.
## Key Abstractions
- Purpose: Wrap a single external resource (camera, barcode input) behind a small, presentation-agnostic API.
- Examples: `CameraHandler` (`ecom-py/camera_handler.py`), `BarcodeHandler` (`ecom-py/barcode_handler.py`).
- Pattern: Instantiated once per process (per Flask app / per Tkinter app instance), holds threading primitives internally, exposes synchronous methods (`start_recording`, `stop_recording`, `process_barcode`) that presentation code calls directly (no event bus/observer pattern).
- Purpose: Decouple slow FFmpeg encoding from the request/UI thread.
- Examples: `ecom-py/video_compressor.py`.
- Pattern: `queue.Queue` + dedicated daemon `threading.Thread` running `_worker_loop`; results delivered via an injected `on_complete` callback rather than a return value, since the caller isn't blocking.
- Purpose: Simple data-access layer without an ORM.
- Examples: `ecom-py/database.py`.
- Pattern: Each method opens its own `sqlite3.connect()`, uses `conn.row_factory = sqlite3.Row` to return `dict`-like rows, and closes the connection before returning — no persistent connection pool or context manager reuse.
- Purpose: Typed, defaulted, deep-mergeable JSON config.
- Examples: `ecom-py/settings_manager.py`, `ecom-py/settings.json.example`.
- Pattern: Class-level `DEFAULT_SETTINGS` dict merged with any on-disk `settings.json` via `_deep_merge`; convenience getters (`get_video_resolution()`, `get_camera_index()`, etc.) wrap the generic `get(category, key, default)`.
## Entry Points
- Location: `ecom-py/app_gui.py` (`main()` at line 2483, run via `python app_gui.py` or `run_gui.bat`)
- Triggers: User double-clicks `run_gui.bat` or runs the script directly.
- Responsibilities: Builds the Tkinter root window, instantiates `EcomVideoTrackerApp`, starts the Tkinter mainloop.
- Location: `ecom-py/app.py` (`if __name__ == '__main__':` block at line 452, run via `python app.py` or `run_web.bat`)
- Triggers: User double-clicks `run_web.bat` or runs the script directly; listens on `config.FLASK_HOST:FLASK_PORT` (default `0.0.0.0:5000` per `config.py`, but `127.0.0.1:5000` per `settings_manager.py` defaults/`settings.json.example`).
- Responsibilities: Initializes Flask app, handler singletons (`camera`, `barcode_handler`, `db`, `compressor`), registers routes and `atexit` cleanup, starts the Flask dev server (`threaded=True`).
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
### Per-call SQLite connections without pooling or context managers
## Error Handling
- Service layer (`CameraHandler`, `Database`, `VideoCompressor`) logs and re-raises (or returns a safe default like `[]`/`0.0` for read-only queries) so callers decide user-facing behavior.
- Flask routes catch at the route level and return `jsonify({'error': str(e)}), 500` (`ecom-py/app.py`).
- Tkinter handlers catch at the event-handler level and show `messagebox.showerror(...)` (`ecom-py/app_gui.py`).
- Camera read failures are handled specially with a consecutive-failure counter and automatic reinitialization rather than raising (`ecom-py/camera_handler.py:151-163`).
## Cross-Cutting Concerns
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
