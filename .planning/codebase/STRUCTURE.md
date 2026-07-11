# Codebase Structure

**Analysis Date:** 2026-07-11

## Directory Layout

```
ecom-system-master/                    # repo root
├── .claude/                           # Claude Code project config (empty of skills at analysis time)
├── .planning/                         # GSD planning artifacts
│   └── codebase/                      # This directory — generated codebase maps
└── ecom-py/                           # ALL application code lives here
    ├── app.py                         # Flask web app entry point + REST/streaming routes
    ├── app_gui.py                     # Tkinter desktop app entry point (main UI, 2491 lines)
    ├── camera_handler.py              # CameraHandler: OpenCV capture/recording engine
    ├── camera_utils.py                # Cross-platform camera enumeration helpers
    ├── barcode_handler.py             # BarcodeHandler: barcode validation/state logic
    ├── database.py                    # Database: SQLite access layer (transactions table)
    ├── settings_manager.py            # SettingsManager: JSON settings persistence
    ├── config.py                      # Runtime config constants, derived from settings + BASE_DIR
    ├── video_compressor.py            # VideoCompressor: background FFmpeg compression worker
    ├── bulk_compressor.py             # Standalone Tkinter tool: batch video compression (not wired to main app)
    ├── add_watermark.py               # Standalone one-off script: rotate + watermark a single video
    ├── build_compressor.py            # PyInstaller build script for bulk_compressor.py
    ├── game_scanner.py                # Unrelated CLI utility: ROM directory scanner/comparator
    ├── templates/
    │   └── index.html                 # Web UI single-page HTML (375 lines)
    ├── static/
    │   ├── css/
    │   │   └── style.css              # Web UI styling (1231 lines, purple theme)
    │   └── js/
    │       └── script.js              # Web UI frontend logic (824 lines) — calls /api/* routes
    ├── requirements.txt                # pip dependency list
    ├── pyproject.toml                  # Project metadata (uv/PEP 621), Python >=3.11
    ├── .python-version                 # Pinned Python version for pyenv/uv
    ├── settings.json.example           # Template for user-generated settings.json
    ├── run_gui.bat                     # Windows launcher: activates venv, runs app_gui.py
    ├── run_web.bat                     # Windows launcher: activates venv, runs app.py
    ├── build_exe.bat                   # Windows launcher: builds standalone .exe (PyInstaller)
    ├── install.bat                     # Windows setup script
    ├── install_camera_support.bat      # Installs pygrabber for Windows camera names
    ├── install_tkcalendar.bat          # Installs tkcalendar for GUI date pickers
    ├── README.md                       # Primary project documentation
    ├── QUICKSTART.md                   # Condensed setup guide
    ├── CHANGELOG.md                    # Version history
    ├── implementation.md               # Technical implementation notes
    └── .gitignore                      # Excludes videos/, logs/, database.db, settings.json, .venv/, ffmpeg/
```

**Auto-generated at runtime (not committed, created on first run):**
```
ecom-py/
├── videos/YYYY-MM-DD/<Label>/*.mp4    # Recorded videos, organized by date then label folder
├── logs/app.log                       # Application log file
├── database.db                        # SQLite database (transactions table)
└── settings.json                      # User settings (created from DEFAULT_SETTINGS on first run)
```

## Directory Purposes

**`ecom-py/` (root of the application):**
- Purpose: Contains every Python module for both the Desktop GUI and Web app, plus their shared config/docs. There is no `src/` layout — all modules are flat, top-level `.py` files imported by simple `import module_name` (relies on CWD/script directory being on `sys.path`).
- Contains: Entry-point scripts, handler/service classes, persistence classes, standalone utility tools, batch files, documentation.
- Key files: `app.py`, `app_gui.py`, `camera_handler.py`, `database.py`, `config.py`.

**`ecom-py/templates/`:**
- Purpose: Jinja2/Flask HTML templates for the web UI.
- Contains: Single file, `index.html`, rendered by `app.py`'s `index()` route.
- Key files: `templates/index.html`.

**`ecom-py/static/`:**
- Purpose: Flask static asset serving (`css/`, `js/`) for the web UI.
- Contains: `css/style.css` (theme/layout), `js/script.js` (fetches `/api/*` endpoints, manages MJPEG `<img>` stream, renders recordings list/search results).
- Key files: `static/css/style.css`, `static/js/script.js`.

**`ecom-py/videos/` (generated):**
- Purpose: Video output storage.
- Structure: `videos/<YYYY-MM-DD>/<LabelFolder>/<YYYYMMDD_HHMMSS>_<BARCODE>.mp4`. Label folders are one of `Normal`, `Return and Refund`, `Return Parcel` (mapped in `CameraHandler._get_label_folder_name`, `ecom-py/camera_handler.py:340`).
- Generated: Yes, on first recording.
- Committed: No (`.gitignore`d).

**`ecom-py/logs/` (generated):**
- Purpose: Rotating-free single log file (`app.log`) shared by whichever entry point is running.
- Generated: Yes, on app startup (`os.makedirs(config.LOG_PATH, exist_ok=True)`).
- Committed: No.

## Key File Locations

**Entry Points:**
- `ecom-py/app_gui.py`: Desktop GUI entry point — `main()` at line 2483; run via `python app_gui.py` or `run_gui.bat`.
- `ecom-py/app.py`: Web app entry point — `if __name__ == '__main__':` block at line 452; run via `python app.py` or `run_web.bat`.
- `ecom-py/bulk_compressor.py`: Separate standalone Tkinter tool, independently launched (not linked from the main apps).

**Configuration:**
- `ecom-py/config.py`: Computes/exposes runtime constants (`VIDEO_STORAGE_PATH`, `DATABASE_PATH`, `LOG_PATH`, `FLASK_HOST/PORT`, `CAMERA_INDEX`, etc.) by reading `SettingsManager` at import time; provides `reload_config()`.
- `ecom-py/settings_manager.py`: `SettingsManager` class — JSON load/save, `DEFAULT_SETTINGS` schema (video/camera/storage/app/compression categories), typed convenience getters.
- `ecom-py/settings.json.example`: Template showing the settings.json shape (note: lacks the `compression` category present in `DEFAULT_SETTINGS`, and `camera` block omits `auto_exposure`/`exposure`/`gain`/`brightness` present in code defaults — treat `SettingsManager.DEFAULT_SETTINGS` as the source of truth over this example file).
- `ecom-py/pyproject.toml` / `ecom-py/requirements.txt`: Python dependency declarations (Flask, opencv-python, pillow, pygrabber, tkcalendar).

**Core Logic:**
- `ecom-py/camera_handler.py`: Camera capture, recording, watermarking, auto-reinit — the most complex/stateful module.
- `ecom-py/database.py`: All SQL for the `transactions` table (create/complete/search/advanced_search/compression status).
- `ecom-py/barcode_handler.py`: Small, stateless-ish barcode validation/action logic — safest module to unit test.
- `ecom-py/video_compressor.py`: FFmpeg subprocess queue/worker.
- `ecom-py/camera_utils.py`: Platform-specific camera name detection (DirectShow/pygrabber on Windows, `v4l2-ctl` on Linux, `system_profiler` on macOS), 30s result cache.

**Testing:**
- No test files or test framework present anywhere in the repository (no `tests/` directory, no `pytest`/`unittest` files, no test config in `pyproject.toml`).

## Naming Conventions

**Files:**
- Lowercase snake_case module names matching their primary class in singular/handler form: `camera_handler.py` → `CameraHandler`, `barcode_handler.py` → `BarcodeHandler`, `database.py` → `Database`, `settings_manager.py` → `SettingsManager`, `video_compressor.py` → `VideoCompressor`.
- Entry-point files are named for their surface: `app.py` (web), `app_gui.py` (desktop).
- Batch scripts use `verb_noun.bat` (`run_gui.bat`, `install_camera_support.bat`, `build_exe.bat`).

**Directories:**
- Lowercase, plural for asset/content folders (`templates/`, `static/`, `videos/`, `logs/`).
- `static/css`, `static/js` follow conventional Flask static subfolder naming.

**Python identifiers (observed pattern, not enforced by linter — no `.flake8`/`ruff`/`pyproject` lint config present):**
- Classes: PascalCase (`CameraHandler`, `EcomVideoTrackerApp`, `SearchWindow`, `SettingsDialog`, `CompressionJob`).
- Functions/methods/variables: snake_case (`start_recording`, `process_barcode`, `video_storage_path`).
- Private/internal methods prefixed with a single underscore (`_capture_frames`, `_record_frames`, `_try_reinitialize_camera`, `_deep_merge`).
- Module-level constants: UPPER_SNAKE_CASE (`VIDEO_RESOLUTION`, `BARCODE_START_PREFIX`, `PRIORITY_FLAGS`).

## Where to Add New Code

**New Feature (e.g., new recording metadata, new workflow step):**
- Shared/business logic: add to the relevant handler module (`camera_handler.py` for capture/recording concerns, `database.py` for new columns/queries, `barcode_handler.py` for scan-action logic).
- Wire into both entry points: update the orchestration in `app.py` (Flask route) AND `app_gui.py` (Tkinter event handler) — the codebase has no shared orchestration layer, so new workflow logic must currently be duplicated in both (see ARCHITECTURE.md Anti-Patterns; consider extracting a shared orchestrator instead of duplicating further).
- Tests: none exist; if adding a test suite, a `tests/` directory at `ecom-py/tests/` with `pytest` would be a natural, unprecedented addition (see `pyproject.toml`, which currently declares no test dependencies).

**New Web API Route:**
- Add a `@app.route(...)` handler function directly in `ecom-py/app.py`, following the existing pattern of a `try/except` wrapping `jsonify(...)` returns with matching HTTP status codes.
- If it needs frontend wiring, add a `fetch()` call in `ecom-py/static/js/script.js` and any DOM/markup in `ecom-py/templates/index.html`.

**New Desktop GUI Panel/Dialog:**
- Add a new `create_*` method to `EcomVideoTrackerApp` (`ecom-py/app_gui.py`) for panels embedded in the main window, or a new top-level class (following the `SearchWindow`/`SettingsDialog` pattern: `__init__(self, parent, ...)`, `setup_ui()`, `create_*` sub-methods) for separate windows.

**New Setting:**
- Add the key with a default value to `SettingsManager.DEFAULT_SETTINGS` (`ecom-py/settings_manager.py`), add a typed getter/setter convenience method if it's accessed frequently, expose it in `config.py` (both the initial load block and `reload_config()`), and add a UI control in `SettingsDialog` (`app_gui.py`) and/or the web Settings tab (`templates/index.html` + `static/js/script.js`) plus the `/api/settings` route in `app.py`.

**Utilities:**
- Cross-cutting helpers that don't belong to a specific handler (e.g., platform detection, path helpers) currently live inline in `camera_utils.py` or `config.py` — there is no dedicated `utils.py`; if one is warranted, place it at `ecom-py/utils.py` alongside the other flat modules to match the existing no-package, no-`src/` layout.

## Special Directories

**`ecom-py/videos/`:**
- Purpose: Recorded video output, organized `videos/<date>/<label>/`.
- Generated: Yes.
- Committed: No.

**`ecom-py/logs/`:**
- Purpose: Application log file (`app.log`).
- Generated: Yes.
- Committed: No.

**`ecom-py/ffmpeg/` (referenced but not present at analysis time):**
- Purpose: Optional bundled FFmpeg binary location checked by `VideoCompressor.check_ffmpeg_installed()` and hardcoded in `add_watermark.py` (`ffmpeg/bin/ffmpeg.exe`) for portable/offline deployment on Windows.
- Generated: No — must be manually placed by the developer/deployer.
- Committed: No (`.gitignore`d).

**`.claude/`:**
- Purpose: Claude Code project-level configuration directory.
- Generated: No.
- Committed: Yes (present in repo root, contents not explored as out of scope for architecture).

**`.planning/`:**
- Purpose: GSD (Get Stuff Done) planning artifacts, including this `codebase/` map directory.
- Generated: By GSD tooling.
- Committed: Typically yes (planning history).

---

*Structure analysis: 2026-07-11*
