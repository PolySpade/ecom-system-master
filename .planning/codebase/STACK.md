# Technology Stack

**Analysis Date:** 2026-07-11

## Languages

**Primary:**
- Python 3.11+ (declared in `ecom-py/pyproject.toml`, pinned via `ecom-py/.python-version`) - All application logic (Tkinter desktop GUI, Flask web app, video/camera handling, database access)
- README states "Python 3.10 or higher" (`ecom-py/README.md:26`) — slightly looser than `pyproject.toml`'s `>=3.11`; treat 3.11 as the effective floor.

**Secondary:**
- HTML/CSS/JavaScript (vanilla, no framework/bundler) - Flask web UI in `ecom-py/templates/index.html`, `ecom-py/static/css/style.css`, `ecom-py/static/js/script.js`
- Batch scripting (`.bat`) - Windows install/run/build automation: `ecom-py/install.bat`, `ecom-py/run_gui.bat`, `ecom-py/run_web.bat`, `ecom-py/build_exe.bat`, `ecom-py/install_camera_support.bat`, `ecom-py/install_tkcalendar.bat`
- SQL (embedded in Python strings) - Schema and queries in `ecom-py/database.py`

## Runtime

**Environment:**
- CPython 3.11+ (project pins `.python-version` to `3.11`; local dev machine observed running Python 3.12.3)
- Windows is the primary target platform (camera backend selection, process-priority flags, `.bat` launchers, PyInstaller `.exe` packaging all assume Windows); Linux/macOS code paths exist as fallbacks (see `ecom-py/camera_utils.py`, `ecom-py/camera_handler.py`)

**Package Manager:**
- pip (`ecom-py/requirements.txt`, pinned versions) is the primary documented path
- `uv` is offered as a faster alternative (`ecom-py/README.md:39-49`), but no `uv.lock` is committed (`.gitignore` excludes `uv.lock`)
- Lockfile: missing/not committed. `requirements.txt` uses exact `==` pins instead, `pyproject.toml` uses `>=` floors — the two files are not fully synchronized (e.g. `pyproject.toml` requires `opencv-python>=4.12.0.88` and `pillow>=12.1.0`, while `requirements.txt` pins `opencv-python==4.9.0.80` and `Pillow==10.2.0`)

## Frameworks

**Core:**
- Flask 3.0.0 (`requirements.txt`) / `>=3.1.2` (`pyproject.toml`) - Web application framework, serves REST API + HTML UI (`ecom-py/app.py`)
- Tkinter (Python stdlib, no version pin) - Desktop GUI framework, primary/recommended interface (`ecom-py/app_gui.py`, 2491 lines)
- OpenCV (`opencv-python` 4.9.0.80 / `>=4.12.0.88`) - Camera capture, video encoding/writing, frame processing, on-frame watermarking (`ecom-py/camera_handler.py`, `ecom-py/camera_utils.py`)

**Testing:**
- None detected. No `pytest`, `unittest` test files, or test configuration found anywhere in `ecom-py/`.

**Build/Dev:**
- PyInstaller 6.3.0 (`requirements.txt`) / `>=6.3.0`(unspecified in pyproject, present in requirements only) - Packages `app_gui.py` (and `bulk_compressor.py`) into standalone Windows `.exe` files. See `ecom-py/build_exe.bat` and `ecom-py/build_compressor.py`.
- FFmpeg (external binary, not a Python package) - Invoked via `subprocess`/`Popen` for background video compression (`ecom-py/video_compressor.py`), standalone watermarking (`ecom-py/add_watermark.py`), and bulk compression tool (`ecom-py/bulk_compressor.py`). Not vendored; must be installed separately or placed in common lookup paths.

## Key Dependencies

**Critical:**
- `opencv-python` (cv2) - Camera I/O (`cv2.VideoCapture`), video encoding (`cv2.VideoWriter`), JPEG frame encoding for MJPEG streaming, on-frame text/rectangle drawing for watermarks
- `Flask` - HTTP server, routing, JSON API, Jinja2 templating (bundled with Flask) for `templates/index.html`
- `Pillow` (PIL) - Image conversion for Tkinter preview widgets (`ImageTk.PhotoImage`) in `ecom-py/app_gui.py`
- `tkcalendar` 1.6.1 - Calendar date-picker widget (`DateEntry`) used in desktop GUI search dialogs (`ecom-py/app_gui.py`)

**Infrastructure:**
- `pygrabber` 0.2 (Windows only, `sys_platform == 'win32'` marker in `requirements.txt`) - DirectShow-based camera name enumeration on Windows (`ecom-py/camera_utils.py`)
- `pyinstaller` 6.3.0 - Executable packaging (build-time only, not a runtime dependency)
- Python stdlib `sqlite3` - Embedded database driver (no external DB dependency)
- Python stdlib `subprocess`, `threading`, `queue` - Process management for FFmpeg calls and background worker threads (compression queue, camera capture thread, recording thread)
- Optional/soft dependencies referenced only in fallback code paths (not declared in `requirements.txt`/`pyproject.toml`, imported defensively with `try/except ImportError`): `winreg` (Windows registry camera name lookup), `wmi` (Windows Management Instrumentation camera lookup) — see `ecom-py/camera_utils.py:240-314`

## Configuration

**Environment:**
- No `.env` files or environment-variable-based configuration detected. Configuration is entirely file-based:
  - `ecom-py/settings.json` (git-ignored, user-editable, created at runtime from `ecom-py/settings.json.example`) - video, camera, storage, app (Flask host/port/debug), and compression settings
  - `ecom-py/config.py` - Loads `SettingsManager` at import time, exposes module-level constants (`VIDEO_CODEC`, `VIDEO_FPS`, `VIDEO_RESOLUTION`, `VIDEO_STORAGE_PATH`, `DATABASE_PATH`, `LOG_PATH`, `FLASK_HOST`, `FLASK_PORT`, `DEBUG_MODE`, `CAMERA_INDEX`), with a `reload_config()` function to refresh values at runtime
  - `ecom-py/settings_manager.py` - `SettingsManager` class handles JSON load/save/merge with `DEFAULT_SETTINGS`, deep-merges user overrides over defaults
- Base directory resolution handles both script mode and PyInstaller-frozen `.exe` mode (`ecom-py/config.py:6-11`) — uses `sys.executable`'s directory when frozen, `__file__`'s directory otherwise
- Key configurable values: `flask_host` (default `127.0.0.1`), `flask_port` (default `5000`), `debug_mode`, video resolution/fps/codec, camera index and exposure/gain/brightness, storage paths, and compression codec/CRF/preset/priority

**Build:**
- `ecom-py/pyproject.toml` - Project metadata and dependency floors (PEP 621 style, no build-backend section — not currently used to build a distributable package, just dependency declaration)
- `ecom-py/requirements.txt` - Pinned dependency versions used by `pip install -r requirements.txt`
- `ecom-py/build_exe.bat` - PyInstaller command for desktop GUI exe (`--onefile --windowed`, bundles `config.py` as data, hidden-imports PIL)
- `ecom-py/build_compressor.py` - Python-driven PyInstaller build for the standalone `BulkVideoCompressor.exe` tool

## Platform Requirements

**Development:**
- Python 3.11+ interpreter
- Webcam (built-in or USB) for camera-dependent features
- FFmpeg binary (optional at dev time; compression silently skips/fails without it, see `ecom-py/video_compressor.py:84-160`)
- Git (for cloning/version control only)

**Production:**
- Windows is the de facto deployment target: `.bat` launch scripts, PyInstaller `--windowed` Windows executables, Windows-specific process-priority flags (`CREATE_NO_WINDOW`, `IDLE_PRIORITY_CLASS`, etc. in `ecom-py/video_compressor.py:17-22`), MSMF camera backend preference, and `pygrabber`/`winreg`/`wmi` camera-name lookups all indicate Windows 10/11 desktop deployment
- No containerization (no `Dockerfile`/`docker-compose.yml` found)
- No cloud hosting configuration — Flask app is designed to run locally (`FLASK_HOST` default `127.0.0.1`) or on a local network (`0.0.0.0`), not behind a reverse proxy or WSGI production server (uses Flask's built-in dev server via `app.run(...)` in `ecom-py/app.py:457-462`, no gunicorn/waitress/uwsgi dependency)
- Local filesystem storage only: videos under `ecom-py/videos/<date>/<label>/`, SQLite file at `ecom-py/database.db`, logs at `ecom-py/logs/app.log` — all paths configurable but default to relative paths beside the executable/script

---

*Stack analysis: 2026-07-11*
