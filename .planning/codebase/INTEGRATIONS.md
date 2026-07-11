# External Integrations

**Analysis Date:** 2026-07-11

## APIs & External Services

**None.** This application has no outbound calls to third-party web APIs, cloud services, payment providers, or SaaS platforms. It is a fully offline, locally-run system. The only "external" dependency is a locally-installed command-line binary (FFmpeg) and locally-attached hardware (webcam/barcode scanner).

**Video Compression (local binary, not a network service):**
- FFmpeg - Invoked as a subprocess for H.264/H.265 video re-encoding
  - Integration point: `ecom-py/video_compressor.py` (background worker, queue-based), `ecom-py/add_watermark.py` (standalone script), `ecom-py/bulk_compressor.py` (standalone Tkinter tool)
  - Discovery: checks local project folder (`ffmpeg.exe`, `ffmpeg/ffmpeg.exe`, `ffmpeg/bin/ffmpeg.exe`), common Windows install paths (`C:\ffmpeg\bin\ffmpeg.exe`, Program Files variants), then falls back to `PATH` (`ecom-py/video_compressor.py:97-160`)
  - Invocation: `subprocess.run(["ffmpeg", "-version"], ...)` for availability check; `subprocess.Popen([...], stdout=DEVNULL, stderr=DEVNULL)` for actual compression with Windows priority flags (`ecom-py/video_compressor.py:394-417`)
  - Not vendored/bundled with the app — must be installed separately by the end user; app degrades gracefully (marks compression "skipped") if not found
  - User-facing download link: `https://ffmpeg.org/download.html` (`ecom-py/templates/index.html:305`)

## Data Storage

**Databases:**
- SQLite (single file, no server) - `sqlite3` stdlib module, no ORM
  - Connection: file path resolved via `config.DATABASE_PATH`, default `database.db` relative to app directory, configurable via `settings.json` → `storage.database_path`
  - Client: raw `sqlite3.connect()` calls per-operation (no connection pooling) in `ecom-py/database.py`
  - Schema: single `transactions` table (barcode, video_filename, start_time, end_time, duration_seconds, file_size_mb, stop_method, label, compression_status, compressed_file_size_mb, compression_ratio, compressed_filename, created_at) — see `ecom-py/database.py:19-70` for `CREATE TABLE` and additive `ALTER TABLE` migration-on-boot pattern (best-effort, swallows `OperationalError` if columns already exist)
  - No migration framework (e.g. Alembic) — schema evolution is handled by defensive `ALTER TABLE` attempts inside `Database.init_database()`

**File Storage:**
- Local filesystem only. Video files stored under `<VIDEO_STORAGE_PATH>/<YYYY-MM-DD>/<label_folder>/<timestamp>_<barcode>.mp4` (`ecom-py/camera_handler.py:365-374`). Label folders map to `Normal`, `Return and Refund`, or `Return Parcel` (`ecom-py/camera_handler.py:340-347`). Path configurable via `settings.json` → `storage.video_path`. No cloud/object storage (S3, GCS, Azure Blob) integration — README lists "Cloud storage sync (AWS S3, Google Drive)" only as a future roadmap item, not implemented (`ecom-py/README.md:397`).

**Caching:**
- In-process only: a simple time-based cache (30 second TTL) for camera enumeration results held in a module-level global (`ecom-py/camera_utils.py:16-20`, `_camera_cache`/`_cache_time`). No Redis/Memcached or other external cache.

## Authentication & Identity

**Auth Provider:**
- None. The Flask web app and all API routes (`ecom-py/app.py`) are unauthenticated — no login, session, API key, or token checks anywhere in the codebase. README explicitly documents this: "No authentication built-in - add if deploying to production" and recommends keeping `FLASK_HOST` at `127.0.0.1` (localhost-only) unless network access is explicitly desired (`ecom-py/README.md:378-383`).

## Monitoring & Observability

**Error Tracking:**
- None. No Sentry, Rollbar, or similar error-tracking SDK integrated.

**Logs:**
- Local file + console logging via Python stdlib `logging` module. Configured identically in both `ecom-py/app.py:12-23` and `ecom-py/app_gui.py` (near top of file): `logging.basicConfig()` with `FileHandler` writing to `config.LOG_FILE` (default `logs/app.log`) and a `StreamHandler` for console output. Log level controlled by `config.LOG_LEVEL` (hardcoded `'DEBUG'` in `ecom-py/config.py:45`). No log aggregation/shipping to external services.

## CI/CD & Deployment

**Hosting:**
- None (self-hosted / run locally). No deployment target configuration (no Dockerfile, no cloud provider config, no `Procfile`). Distribution model is a standalone Windows `.exe` built via PyInstaller (`ecom-py/build_exe.bat`) that end users run directly on their own machine.

**CI Pipeline:**
- None detected. No `.github/workflows/`, `.gitlab-ci.yml`, `azure-pipelines.yml`, or similar CI configuration found in the repository.

## Environment Configuration

**Required env vars:**
- None. All configuration is via `ecom-py/settings.json` (JSON file, git-ignored) with `ecom-py/settings.json.example` as the template, merged with in-code defaults in `ecom-py/settings_manager.py` (`SettingsManager.DEFAULT_SETTINGS`). No `os.environ` reads for app configuration anywhere in the codebase (one exception: temporarily setting `OPENCV_LOG_LEVEL` env var to suppress OpenCV's own C++ logging during camera enumeration, `ecom-py/camera_utils.py:61-62`, which is not user/deployment configuration).

**Secrets location:**
- Not applicable — the application has no API keys, tokens, passwords, or other secrets to manage (no external services requiring credentials).

## Webhooks & Callbacks

**Incoming:**
- None. The barcode scanner integration is not a webhook — it works as an HID (keyboard-emulation) device typed directly into a text input field in the UI, then POSTed to `/api/barcode` as a normal form/JSON submission (`ecom-py/app.py:123-218`, `ecom-py/static/js/script.js`). No webhook endpoints are exposed.

**Outgoing:**
- None.

## Local Hardware Integrations (non-network)

Although not "external integrations" in the networked sense, these are the system's actual external touchpoints and are relevant for planning:

- **Webcam / USB camera** - via OpenCV `cv2.VideoCapture`, using MSMF backend on Windows and default backend elsewhere (`ecom-py/camera_handler.py:54-99`, `ecom-py/camera_utils.py`). Camera name resolution on Windows tries `pygrabber` (DirectShow) first, then Windows Registry (`winreg`), then WMI (`wmi`) as successive fallbacks (`ecom-py/camera_utils.py:218-319`). Linux uses `v4l2-ctl` subprocess call; macOS uses `system_profiler` subprocess call.
- **Barcode scanner** - Treated purely as a keyboard-input (HID) device; no direct serial/USB SDK integration. Input is validated/parsed in `ecom-py/barcode_handler.py` (prefix-based START_/STOP_ conventions defined in `config.py`, though the primary workflow in `app.py`/`app_gui.py` uses a simpler "any barcode toggles stop-and-start" model).

---

*Integration audit: 2026-07-11*
