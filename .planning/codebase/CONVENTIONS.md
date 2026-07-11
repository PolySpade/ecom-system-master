# Coding Conventions

**Analysis Date:** 2026-07-11

## Scope

This document covers `ecom-py/` — the Python application (Tkinter desktop GUI + Flask web app + OpenCV video recording). There is no separate frontend framework; `ecom-py/static/js/script.js` and `ecom-py/templates/index.html` back the Flask web UI only and are not analyzed in depth here.

## Naming Patterns

**Files:**
- `snake_case.py` for all modules: `camera_handler.py`, `barcode_handler.py`, `video_compressor.py`, `settings_manager.py`, `camera_utils.py`.
- Module name mirrors the primary class it exports (e.g., `camera_handler.py` → `CameraHandler`, `settings_manager.py` → `SettingsManager`).
- Two parallel entry points at the root: `app.py` (Flask web server) and `app_gui.py` (Tkinter desktop app). Both wire up the same core modules (`camera_handler`, `barcode_handler`, `database`, `video_compressor`, `config`).

**Classes:**
- `PascalCase` throughout: `CameraHandler`, `BarcodeHandler`, `Database`, `VideoCompressor`, `SettingsManager`, `SavingProgressDialog`, `EcomVideoTrackerApp`, `SearchWindow`, `SettingsDialog` (all in `ecom-py/app_gui.py`).
- Enum classes use `PascalCase` with `UPPER_CASE` string-valued members, e.g. `CompressionStatus(Enum)` in `ecom-py/video_compressor.py:25` (`PENDING = "pending"`, `PROCESSING = "processing"`, etc.).
- `@dataclass` used for simple job/record structs, e.g. `CompressionJob` in `ecom-py/video_compressor.py:34-40` and a duplicate/independent `CompressionJob` in `ecom-py/bulk_compressor.py:27`.

**Functions/Methods:**
- `snake_case` for all functions and methods: `get_available_cameras`, `process_barcode`, `start_recording`, `queue_video_compression`.
- Private/internal helpers prefixed with a single underscore: `_start_capture_thread`, `_stop_capture_thread`, `_capture_frames`, `_try_reinitialize_camera` (`ecom-py/camera_handler.py`), `_deep_merge` (`ecom-py/settings_manager.py:109`), `_worker_loop` (`ecom-py/video_compressor.py`).
- Boolean-returning predicates prefixed `is_`: `is_start_code`, `is_stop_code`, `is_recording` (`ecom-py/barcode_handler.py`, `ecom-py/camera_handler.py`).
- Flask route handlers are plain descriptive verbs matching the resource: `get_status`, `process_barcode`, `manual_stop`, `get_recordings`, `search_recordings` (`ecom-py/app.py`).

**Variables:**
- `snake_case` for locals and instance attributes: `video_filename`, `transaction_id`, `current_label_folder`.
- Module-level "private" config intermediates prefixed with underscore: `_settings`, `_video_path`, `_db_path`, `_log_path` in `ecom-py/config.py`.
- Constants (module-level config values) are `UPPER_SNAKE_CASE`: `VIDEO_CODEC`, `VIDEO_FPS`, `MAX_STORAGE_GB`, `BARCODE_START_PREFIX`, `BARCODE_TIMEOUT_SECONDS` in `ecom-py/config.py`.
- Threading primitives are named for their purpose, not generically: `self.lock`, `self.frame_lock`, `self.buffer_lock`, `self._reinit_lock` (`ecom-py/camera_handler.py`).

**Types:**
- No custom type aliases. Typing relies on `typing.Optional`, `typing.List`, `typing.Dict`, `typing.Callable`, `typing.Tuple` directly at call sites (`ecom-py/database.py:4`, `ecom-py/video_compressor.py:11`).

## Code Style

**Formatting:**
- No formatter config detected (no `.black`, `pyproject.toml` `[tool.black]`, `.ruff.toml`, or `.flake8`). Formatting is manual/by convention, 4-space indentation, no semicolons.
- `ecom-py/pyproject.toml` only declares `[project]` metadata and dependencies — no lint/format tool sections.

**Linting:**
- No linter configured. Do not assume `ruff`/`flake8`/`pylint` will run in CI — there is no CI (`.github/workflows` not present).

**Line length / style quirks:**
- Standard PEP 8-ish style predominates in most modules (`database.py`, `settings_manager.py`, `barcode_handler.py`, `camera_handler.py`).
- `ecom-py/add_watermark.py` is a standalone utility script with a distinct, more compact style (aligned `=` signs for constant blocks, box-drawing comment separators `# ── Config ────...`). Treat this file as a one-off tool, not representative of core conventions — do not copy its alignment style into core modules.

## Import Organization

**Order (observed, not enforced by tooling):**
1. Standard library imports first (`os`, `sys`, `logging`, `sqlite3`, `threading`, `time`, `datetime`, `typing`).
2. Third-party imports next (`cv2`, `flask`, `PIL`, `tkcalendar`).
3. Local/project imports last (`config`, `database`, `camera_handler`, `barcode_handler`, `settings_manager`, `camera_utils`, `video_compressor`).

Example from `ecom-py/app_gui.py:1-19`:
```python
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext, filedialog
import cv2
from PIL import Image, ImageTk
import threading
import time
import logging
import os
import subprocess
import platform
from datetime import datetime
from tkcalendar import DateEntry
from camera_handler import CameraHandler
from barcode_handler import BarcodeHandler
from database import Database
from video_compressor import VideoCompressor
import config
from settings_manager import SettingsManager
from camera_utils import get_available_cameras, get_available_cameras_fast, refresh_cameras_async
```

**Path Aliases:**
- None. All local imports are flat, unqualified module imports (no package structure, no `src/` layout — every module lives directly in `ecom-py/`).
- Local imports occasionally happen mid-function rather than at module top when avoiding overhead or circularity, e.g. `from datetime import datetime` inside `queue_video_compression()` in `ecom-py/app.py:71` even though `datetime` patterns are typically imported at top-of-file elsewhere.

## Error Handling

**Dominant pattern — broad try/except with logging and safe fallback:**
Nearly every public method in `ecom-py/database.py`, `ecom-py/camera_handler.py`, `ecom-py/video_compressor.py`, and Flask routes in `ecom-py/app.py` wraps its body in `try/except Exception as e:`, logs via `logger.error(f"...: {e}")`, and either re-raises (write/mutating operations) or returns a safe default (read operations).

Read operation returning safe default on failure (`ecom-py/database.py:194-212`):
```python
def get_total_storage_used(self) -> float:
    try:
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT SUM(file_size_mb) FROM transactions WHERE file_size_mb IS NOT NULL')
        result = cursor.fetchone()[0]
        conn.close()
        return result if result else 0.0
    except Exception as e:
        logger.error(f"Error calculating total storage: {e}")
        return 0.0
```

Write operation re-raising after logging (`ecom-py/database.py:72-101`, `create_transaction`):
```python
try:
    ...
    logger.info(f"Created transaction {transaction_id} for barcode {barcode} (Label: {label})")
    return transaction_id
except Exception as e:
    logger.error(f"Error creating transaction: {e}")
    raise
```

**Flask routes** always catch `Exception`, log, and return a JSON error body with an HTTP status code — never let an exception propagate to a 500 with a stack trace (`ecom-py/app.py:107-120`):
```python
@app.route('/api/status', methods=['GET'])
def get_status():
    try:
        status = {...}
        return jsonify(status), 200
    except Exception as e:
        logger.error(f"Error getting status: {e}")
        return jsonify({'error': str(e)}), 500
```
Follow this pattern for any new Flask route in `ecom-py/app.py`: wrap body in try/except, log the error, `return jsonify({'error': str(e)}), 500`.

**Bare `except:` usage (anti-pattern, but present):**
Bare `except:` (no exception type) appears in cleanup/best-effort code paths where failure is intentionally ignored — mostly around resource release and optional-feature probing:
- `ecom-py/camera_handler.py:178,616,634`
- `ecom-py/app_gui.py:102,610,1069,2386`
- `ecom-py/video_compressor.py:334`
- `ecom-py/camera_utils.py:269,276,296,299`
- `ecom-py/bulk_compressor.py:94,322,431,563`
- `ecom-py/game_scanner.py:38,49,69,79`

New code should prefer `except Exception:` over bare `except:` to avoid swallowing `KeyboardInterrupt`/`SystemExit`, but be aware existing code uses bare `except:` liberally for "best effort, ignore failure" cleanup (e.g. releasing a camera handle, closing a dialog). Match this narrow usage only for truly non-critical cleanup — do not use bare `except` for business logic.

**Validation pattern:**
- Input validation returns early with a boolean or structured result rather than raising, e.g. `BarcodeHandler.validate_barcode()` (`ecom-py/barcode_handler.py:11-31`) returns `False` for invalid input; `process_barcode()` returns `{'action': 'invalid', 'barcode': barcode}` rather than throwing.
- Flask routes validate request payloads manually and return `400` with a JSON `{'error': '...'}` body for bad input (`ecom-py/app.py:132-133`, `ecom-py/app.py:279-280`).

## Logging

**Framework:** Standard library `logging`, module-level logger in every file:
```python
logger = logging.getLogger(__name__)
```
This exact line appears at the top of every core module (`ecom-py/barcode_handler.py:4`, `ecom-py/database.py:7`, `ecom-py/settings_manager.py:9`, `ecom-py/camera_handler.py:12`, `ecom-py/camera_utils.py:14`, `ecom-py/video_compressor.py:15`, `ecom-py/app.py:23`, `ecom-py/app_gui.py:32`).

**Configuration (both entry points configure logging identically):**
```python
os.makedirs(config.LOG_PATH, exist_ok=True)
logging.basicConfig(
    level=getattr(logging, config.LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(config.LOG_FILE),
        logging.StreamHandler()
    ]
)
```
See `ecom-py/app.py:12-21` and `ecom-py/app_gui.py:21-30`. `config.LOG_LEVEL` is `'DEBUG'` (`ecom-py/config.py:45`); log file path is `logs/app.log` under the storage-configured `LOG_PATH`.

**Level usage:**
- `logger.info(...)` for normal lifecycle/state-transition events (recording started/stopped, settings saved, DB initialized).
- `logger.warning(...)` for recoverable/unexpected-but-non-fatal conditions (invalid barcode, camera read failures, compression failure).
- `logger.error(...)` inside every `except Exception as e:` block, always with the caught exception interpolated via f-string: `logger.error(f"Error X: {e}")`.
- No `logger.debug()` usage observed in core modules despite `LOG_LEVEL = 'DEBUG'` being the default — debug-level detail is not currently emitted.

**Message style:** Always an f-string, always starts with a short present-tense description, ends with the interpolated exception or key values: `f"Created transaction {transaction_id} for barcode {barcode} (Label: {label})"`, `f"Error initializing database: {e}"`.

## Comments

**When to comment:**
- Section-divider comments used to group related config/logic blocks, e.g. `# Video Settings (dynamically loaded from settings)`, `# Storage (dynamically loaded from settings) - normalize all paths` in `ecom-py/config.py`.
- Inline comments explain *why*, not *what*, especially around platform-specific or non-obvious tradeoffs: `# MSMF is Microsoft's modern camera API with better performance than DirectShow` (`ecom-py/camera_handler.py:58`), `# Set buffer size to minimum to reduce latency` (`ecom-py/camera_handler.py:76`).
- TODO-style markers are rare; the project instead tracks future work in `ecom-py/README.md` under a "Roadmap" checklist rather than inline `# TODO` comments.

**Docstrings:**
- Every class and public method has a docstring. Short one-liners for simple accessors: `"""Get a database connection."""` (`ecom-py/database.py:16`).
- Multi-line Google-style docstrings with `Args:` / `Returns:` sections for anything with parameters or a non-trivial return value:
```python
def create_transaction(self, barcode: str, video_filename: str, label: str = "Normal (Standard)") -> int:
    """
    Create a new transaction record.

    Args:
        barcode: The barcode that triggered the recording
        video_filename: The filename of the video being recorded
        label: The video label/category

    Returns:
        The ID of the newly created transaction
    """
```
(`ecom-py/database.py:72-83`). This pattern is consistent across `ecom-py/database.py`, `ecom-py/barcode_handler.py`, `ecom-py/video_compressor.py`, `ecom-py/camera_utils.py`.
- Module-level docstrings used for standalone-purpose files: `"""Settings Manager - Handle application configuration with JSON persistence"""` (`ecom-py/settings_manager.py:1-3`), `"""Video Compressor - Background compression worker using FFmpeg"""` (`ecom-py/video_compressor.py:1-3`), `"""Camera Utilities - Detect and enumerate available cameras"""` (`ecom-py/camera_utils.py:1-3`).

## Function Design

**Size:** Methods are generally short (10-40 lines), one clear responsibility per method — most database methods follow the exact shape "open connection → execute → format result → close connection → return". Background-thread and camera-loop methods (`_capture_frames` in `ecom-py/camera_handler.py`) are longer due to inherent loop/state-machine complexity but still single-purpose.

**Parameters:**
- Type-hinted parameters with defaults for optional values: `def create_transaction(self, barcode: str, video_filename: str, label: str = "Normal (Standard)") -> int`.
- Multi-parameter methods with several optional filters use one parameter per line for readability when the signature is long, e.g. `advanced_search(...)` in `ecom-py/database.py:247-257`.
- Callbacks passed as `Optional[Callable]` with the expected signature documented in the docstring rather than enforced by typing, e.g. `on_complete` in `ecom-py/video_compressor.py:46-53`.

**Return Values:**
- Read/query methods on `Database` return `List[Dict]` or `Optional[Dict]` (never raise on "not found" — return `None` or `[]`) (`ecom-py/database.py:140,170`).
- Action-processing methods return small structured `dict` results describing what happened, e.g. `{'action': 'start', 'barcode': barcode}` from `BarcodeHandler.process_barcode()` (`ecom-py/barcode_handler.py:57-85`) and `{'action': 'stopped', 'filename': ..., 'duration': ..., ...}` from `camera.stop_recording()` consumers in `ecom-py/app.py`.
- Boolean success/failure returns for operations with no natural payload, e.g. `SettingsManager.save_settings() -> bool` (`ecom-py/settings_manager.py:72-81`).

## Module Design

**Exports:**
- No `__all__` declarations; modules export via plain top-level class/function definitions. Consumers import specific names: `from camera_handler import CameraHandler`, `from database import Database`.
- No package (`__init__.py`) structure — `ecom-py/` is a flat directory of top-level modules imported directly by both `app.py` and `app_gui.py`.

**Singletons / shared state:**
- `config.py` acts as an implicit global singleton: it instantiates `_settings = SettingsManager(...)` at import time and exposes both static-looking constants (`VIDEO_CODEC`, `DATABASE_PATH`, etc.) and the live `settings_manager` object for runtime mutation. `config.reload_config()` (`ecom-py/config.py:55-79`) mutates module-level globals via the `global` keyword — be aware config values are re-read, not re-imported, when settings change.
- `ecom-py/app.py` and `ecom-py/app_gui.py` each construct their own `CameraHandler`, `BarcodeHandler`, `Database`, `VideoCompressor` instances at startup/`__init__` — these are not shared singletons across the two entry points (the GUI and the web app are never run in the same process).

**Threading model:**
- Background work uses raw `threading.Thread(..., daemon=True)` plus `threading.Lock()` / `threading.Event`-style flags, not `asyncio` or `concurrent.futures`. See `CameraHandler._start_capture_thread` (`ecom-py/camera_handler.py:101-109`) and `VideoCompressor.start()` (`ecom-py/video_compressor.py:63-71`), which both spawn a single dedicated worker thread and communicate via a `queue.Queue` (compressor) or locked shared state (camera frame buffer).
- Follow this pattern for new background work: one daemon thread + explicit lock/queue for cross-thread state, not new concurrency primitives.

## Settings & Configuration Pattern

- All user-configurable values live in `ecom-py/settings_manager.py`'s `SettingsManager.DEFAULT_SETTINGS` dict, organized by category (`video`, `camera`, `storage`, `app`, `compression`). New settings should be added as a new key under the appropriate category plus a `get_x()`/`set_x()` convenience method following the existing naming pattern (`get_video_fps`, `get_camera_index`, etc.).
- `ecom-py/config.py` is a thin, import-time-evaluated projection of `SettingsManager` onto module-level constants for convenient `import config; config.VIDEO_FPS` access elsewhere. When adding a new setting that other modules need as a constant, add it to both `SettingsManager.DEFAULT_SETTINGS`/getter and to `config.py`'s constant assignment + `reload_config()`.

---

*Convention analysis: 2026-07-11*
