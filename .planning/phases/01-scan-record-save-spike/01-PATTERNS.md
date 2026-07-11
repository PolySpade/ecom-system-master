# Phase 1: Scan-Record-Save Spike - Pattern Map

**Mapped:** 2026-07-11
**Files analyzed:** 9 (new Dart files, `ecom-flutter/` does not exist yet)
**Analogs found:** 9 / 9 (all analogs are Python files in `ecom-py/` — the behavioral reference implementation; there is no prior Dart/Flutter code in this repo to copy structural conventions from)

**Important framing for the planner:** This is a cross-language port, not a same-codebase pattern match. Every "analog" below is a Python file whose *behavior* (state transitions, schema, naming/folder conventions, log format) the new Dart file must reproduce exactly, not a Dart file whose *syntax* can be copied. Language-idiom patterns (error handling style, class shape, threading model) come from RESEARCH.md's Architecture Patterns section (already Dart-native), not from these Python analogs. Use the Python excerpts below for **exact values/formats/schemas/transitions** — use RESEARCH.md Patterns 1-4 for **Dart syntax**.

## File Classification

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|-----------------|----------------|
| `ecom-flutter/lib/core/barcode_handler.dart` | service (state machine) | event-driven | `ecom-py/barcode_handler.py` | exact (behavioral) |
| `ecom-flutter/lib/core/camera_service.dart` | service | streaming + event-driven | `ecom-py/camera_handler.py` | exact (behavioral), adapted to plugin-owned capture thread |
| `ecom-flutter/lib/core/database.dart` | model / data-access | CRUD | `ecom-py/database.py` | exact (schema must be byte-identical) |
| `ecom-flutter/lib/core/config.dart` | config | request-response (read-only) | `ecom-py/config.py` + `ecom-py/settings_manager.py` | exact (behavioral), reduced scope for Phase 1 |
| `ecom-flutter/lib/core/file_paths.dart` | utility | file-I/O | `ecom-py/camera_handler.py` (folder/filename logic within `start_recording`/`_get_label_folder_name`) | exact (behavioral) |
| `ecom-flutter/lib/models/transaction.dart` | model | transform | `ecom-py/database.py` (row shape via `sqlite3.Row`/`dict(row)`) | role-match |
| `ecom-flutter/lib/ui/main_screen.dart` | component (UI) | request-response (UI events) | `ecom-py/app_gui.py` (`EcomVideoTrackerApp.create_camera_panel`, `create_control_panel`, `process_barcode`, `_stop_recording_with_progress`, `manual_stop`) | role-match |
| `ecom-flutter/lib/main.dart` | entry point / provider wiring | event-driven | `ecom-py/app_gui.py` (module-level logging setup + `main()`) | role-match |
| Logging (cross-cutting, likely `ecom-flutter/lib/core/logger.dart` or inline) | utility | event-driven | `ecom-py/app_gui.py` lines 21-32 (`logging.basicConfig`) | role-match |

## Pattern Assignments

### `ecom-flutter/lib/core/barcode_handler.dart` (service, event-driven)

**Analog:** `ecom-py/barcode_handler.py`

**Full reference implementation** (`ecom-py/barcode_handler.py:1-90`) — this is the *entire* file since it's small; the Dart port must reproduce this exact logic, not the richer 4-action (`start`/`stopAndStart`/`stop`/`invalid`) version sketched in RESEARCH.md Pattern 1, which invents a `stop` action that **does not exist** in the actual Python source:

```python
class BarcodeHandler:
    def __init__(self):
        self.last_barcode = None

    def validate_barcode(self, barcode: str) -> bool:
        if not barcode or not isinstance(barcode, str):
            return False
        barcode = barcode.strip()
        if len(barcode) < 1:
            return False
        return True

    def process_barcode(self, barcode: str, is_recording: bool = False) -> dict:
        if not self.validate_barcode(barcode):
            logger.warning(f"Invalid barcode: {barcode}")
            return {'action': 'invalid', 'barcode': barcode}

        barcode = barcode.strip().upper()

        if is_recording:
            logger.info(f"Recording in progress - will stop current and start new recording: {barcode}")
            self.last_barcode = barcode
            return {'action': 'stop_and_start', 'barcode': barcode}

        logger.info(f"Barcode detected - starting recording: {barcode}")
        self.last_barcode = barcode
        return {'action': 'start', 'barcode': barcode}

    def get_last_barcode(self) -> str:
        return self.last_barcode
```

**Critical behavioral facts the Dart port must match:**
- **Only 3 actions exist**: `invalid`, `start`, `stop_and_start`. There is NO standalone `stop` action returned by `process_barcode()` — manual stop is a completely separate code path (`manual_stop()` / `_stop_recording_with_progress()` in `app_gui.py`, not routed through `BarcodeHandler`). RESEARCH.md's `BarcodeAction` enum (`start`, `stopAndStart`, `invalid`) is actually correct on this point — do not add a `stop` enum value for barcode-triggered actions.
- Validation is trivial: non-null, non-empty after `.strip()`. No format/checksum validation (matches REC-05).
- Normalization: `barcode.strip().upper()` — trim then uppercase, applied only *after* validation passes, and only in `process_barcode`, not in `validate_barcode`.
- `is_start_code`/`is_stop_code` (lines 33-55, using `config.BARCODE_START_PREFIX`/`BARCODE_STOP_PREFIX` = `'START_'`/`'STOP_'`) exist in the Python file but are **dead code** — `process_barcode()` never calls them. Do not port this prefix-based logic into Dart; it is not part of the real behavior despite being defined in the module. `config.BARCODE_TIMEOUT_SECONDS = 60` is similarly defined but unused by `barcode_handler.py` itself.
- Logging: `logger.warning` for invalid, `logger.info` for both start and stop_and_start, always with an f-string embedding the barcode.

---

### `ecom-flutter/lib/core/camera_service.dart` (service, streaming + event-driven)

**Analog:** `ecom-py/camera_handler.py`

**Folder/filename generation — exact port target** (`ecom-py/camera_handler.py:340-380`):
```python
def _get_label_folder_name(self, label: str) -> str:
    label_folder_map = {
        "Return and Refund Unboxing": "Return and Refund",
        "Return Parcel Unboxing": "Return Parcel",
        "Normal (Standard)": "Normal"
    }
    return label_folder_map.get(label, "Normal")

def start_recording(self, barcode: str, label: str = "Normal (Standard)") -> str:
    with self.lock:
        if self.recording:
            raise Exception("Already recording")
        date_folder = datetime.now().strftime('%Y-%m-%d')
        label_folder = self._get_label_folder_name(label)
        video_folder = os.path.join(config.VIDEO_STORAGE_PATH, date_folder, label_folder)
        os.makedirs(video_folder, exist_ok=True)

        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        self.current_filename = f"{timestamp}_{barcode}.mp4"
        video_path = os.path.join(video_folder, self.current_filename)
        ...
```
Phase 1 only needs the `"Normal (Standard)"` → `"Normal"` mapping (per RESEARCH.md, label routing is Phase 2's REC-06) — but implement the map/lookup shape now (default-to-`"Normal"` fallback for unknown labels) so Phase 2 only adds map entries.

**Recording lifecycle state** (`ecom-py/camera_handler.py:17-52`, `349-419`, `491-561`):
- Instance-held state: `self.recording` (bool), `self.current_filename`, `self.recording_start_time`, `self.current_label`, `self.current_barcode`, `self.current_label_folder`, `self.frame_count`.
- `start_recording()` raises/errors if already recording (`"Already recording"`) — Dart equivalent: throw a `StateError` or similar if `CameraController` reports it's already recording. Same guard needed in reverse for `stop_recording()` (`"Not currently recording"`).
- `stop_recording()` returns a result dict: `{'filename', 'duration', 'file_size_mb', 'label_folder', 'fps', 'frame_count'}` — the Dart `camera_service.dart` should return an equivalent typed result object; `duration` is `int(time.time() - self.recording_start_time)` (whole seconds), `file_size_mb` is `os.path.getsize(...) / (1024*1024)` rounded to 2 decimals.
- Log format on stop (`camera_handler.py:551`): `f"Stopped recording: {filename} ({duration}s, {file_size_mb:.2f}MB, {frame_count} frames at {fps:.1f}fps) in {label_folder}"` — replicate this exact message shape in Dart's `logs/app.log` for LOG-01 parity.

**Threading model note for the Dart port:** `camera_handler.py`'s dedicated capture thread (`_capture_frames`, lines 119-163) + frame-buffer + separate recording thread (`_record_frames`, lines 464-489) exists because OpenCV requires manual frame-by-frame `VideoWriter.write()`. In Flutter, `camera_windows`'s native Media Foundation `CaptureEngine` owns this entirely — `camera_service.dart` should be a thin wrapper around `CameraController.startVideoRecording()`/`stopVideoRecording()` (per RESEARCH.md Anti-Patterns), NOT a reimplementation of the manual frame-buffer/thread machinery. Copy the *lifecycle semantics* (state flags, guard exceptions, result shape, logging) from `camera_handler.py`, not its *threading implementation*.

**Watermark reference** (`ecom-py/camera_handler.py:421-462`, `_add_timestamp_watermark`) — out of scope for Phase 1 per RESEARCH.md (watermarking isn't listed in Phase 1 requirements REC/CAM/STO), but noted here for awareness: timestamp top-left (`%Y-%m-%d %H:%M:%S`), label top-right, barcode bottom-left (`f"Barcode: {barcode}"`), each with a solid background rectangle behind white text.

---

### `ecom-flutter/lib/core/database.dart` (model/data-access, CRUD)

**Analog:** `ecom-py/database.py`

**Exact schema to replicate** (`ecom-py/database.py:26-63`, the `CREATE TABLE` plus incrementally-added columns):
```sql
CREATE TABLE IF NOT EXISTS transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    barcode TEXT NOT NULL,
    video_filename TEXT NOT NULL,
    start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    end_time TIMESTAMP,
    duration_seconds INTEGER,
    file_size_mb REAL,
    stop_method TEXT,
    label TEXT DEFAULT 'Normal (Standard)',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- added via ALTER TABLE, guarded by try/except OperationalError:
    compression_status TEXT DEFAULT 'pending',
    compressed_file_size_mb REAL,
    compression_ratio REAL,
    compressed_filename TEXT
)
```
This matches RESEARCH.md's Pattern 3 code example exactly — confirmed correct against the live source in this session. `compression_status` default is the string `'pending'` (note: Python uses double-quoted SQL literal `DEFAULT "pending"` in the `ALTER TABLE`, vs single-quoted in the initial `CREATE TABLE` — SQLite treats both as string literals; use standard single-quote SQL string literals in the Dart raw SQL for clarity, value is identical either way).

**Create transaction (INSERT) pattern** (`ecom-py/database.py:72-101`):
```python
def create_transaction(self, barcode: str, video_filename: str, label: str = "Normal (Standard)") -> int:
    conn = self.get_connection()
    cursor = conn.cursor()
    cursor.execute('''
        INSERT INTO transactions (barcode, video_filename, start_time, label)
        VALUES (?, ?, ?, ?)
    ''', (barcode, video_filename, datetime.now(), label))
    transaction_id = cursor.lastrowid
    conn.commit()
    conn.close()
    logger.info(f"Created transaction {transaction_id} for barcode {barcode} (Label: {label})")
    return transaction_id
```
Note: `start_time` is explicitly passed as `datetime.now()` at INSERT time (not relying on the column's `DEFAULT CURRENT_TIMESTAMP`), and default label parameter is the literal string `"Normal (Standard)"` — same string used in `_get_label_folder_name`'s map key. Dart's `insert()` call should pass an explicit ISO8601 (or SQLite-compatible datetime string) for `start_time` rather than depending on `sqflite`'s default handling, to keep values comparable to Python-written rows if a `database.db` is ever shared.

**Complete transaction (UPDATE) pattern** (`ecom-py/database.py:103-138`):
```python
def complete_transaction(self, transaction_id, duration_seconds, file_size_mb, stop_method):
    cursor.execute('''
        UPDATE transactions
        SET end_time = ?, duration_seconds = ?, file_size_mb = ?, stop_method = ?
        WHERE id = ?
    ''', (datetime.now(), duration_seconds, file_size_mb, stop_method, transaction_id))
```
`stop_method` values used elsewhere in `app_gui.py`: the literal strings `'barcode'` and `'manual'` (see `_stop_recording_with_progress(stop_type='manual', ...)` and `self._stop_recording_with_progress('barcode', on_stop_complete)` calls at `app_gui.py:739,757` and the `manual_stop()` method at `app_gui.py:830`). Phase 1's Dart port needs at minimum these two `stop_method` string values for DB-01 parity.

**Connection pattern (what Phase 1 must NOT copy):** Every `Database` method in `database.py` opens (`sqlite3.connect()`), uses, and closes its own connection per call (lines 15-17, repeated throughout). RESEARCH.md's Anti-Patterns section and DB-02 explicitly require the Dart port to diverge here — open **one** long-lived `sqflite_common_ffi` `Database` at startup with WAL mode, not per-call connections. Copy the *SQL* and *schema* from `database.py`, not its *connection-lifecycle pattern*.

**Error handling pattern** (consistent across all methods, e.g. lines 68-70, 99-101): try/except wrapping the SQL, `logger.error(f"Error <doing x>: {e}")`, then either `raise` (for write operations: `init_database`, `create_transaction`, `complete_transaction`, `update_compression_status`) or return a safe default (`[]` or `None` or `0.0`, for read operations: `get_recent_transactions`, `get_transaction`, `get_total_storage_used`, `search_by_barcode`). Dart port: writes should throw, reads should return `null`/empty list on failure — matches Dart idiom naturally.

---

### `ecom-flutter/lib/core/config.dart` (config, request-response read-only)

**Analog:** `ecom-py/config.py` + `ecom-py/settings_manager.py`

**Settings categories/keys relevant to Phase 1** (`ecom-py/settings_manager.py:15-47`, `DEFAULT_SETTINGS`):
```python
DEFAULT_SETTINGS = {
    'video': {'resolution_width': 1280, 'resolution_height': 720, 'fps': 30, 'codec': 'mp4v'},
    'camera': {'index': 0, 'auto_exposure': True, 'exposure': -4, 'gain': 0, 'brightness': 128},
    'storage': {'video_path': 'videos', 'database_path': 'database.db', 'log_path': 'logs'},
    'app': {'flask_host': '127.0.0.1', 'flask_port': 5000, 'debug_mode': False},
    'compression': {...}  # out of scope, Phase 3
}
```
Phase 1 needs: `video.resolution_width/height`, `video.fps`, `camera.index`, `storage.video_path`, `storage.database_path`, `storage.log_path`. `video.codec` (`'mp4v'`) and camera exposure/gain/brightness are lower priority for Phase 1 (no Settings UI yet per RESEARCH.md SET-01 scoping) but should still be read so `camera_service.dart` can apply sane defaults if the plugin's recording API accepts them.

**Path resolution pattern — must be ported for parity** (`ecom-py/config.py:1-30`):
```python
if getattr(sys, 'frozen', False):
    BASE_DIR = os.path.dirname(sys.executable)
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

_video_path = _settings.get_video_storage_path()
VIDEO_STORAGE_PATH = os.path.normpath(_video_path if os.path.isabs(_video_path) else os.path.join(BASE_DIR, _video_path))
```
Dart equivalent: base directory should resolve relative to the built `.exe`'s directory (`Platform.resolvedExecutable`'s directory), matching "beside the executable" default noted in RESEARCH.md's `path_provider` entry — this is the "prefer `Platform.resolvedExecutable`-relative resolution" strategy RESEARCH.md flags as still-to-decide; this config.py excerpt confirms the exact behavior to match: relative settings paths (`'videos'`, `'database.db'`, `'logs'`) resolve relative to the base dir, absolute paths pass through unchanged via `os.path.normpath`.

**JSON settings file shape** (`ecom-py/settings.json.example`):
```json
{
  "video": {"resolution_width": 1280, "resolution_height": 720, "fps": 30, "codec": "mp4v"},
  "camera": {"index": 0},
  "storage": {"video_path": "videos", "database_path": "database.db", "log_path": "logs"},
  "app": {"flask_host": "127.0.0.1", "flask_port": 5000, "debug_mode": false}
}
```
Note this example file omits several `DEFAULT_SETTINGS` keys (camera exposure/gain/brightness, compression) — confirms the deep-merge-with-defaults pattern (`_deep_merge`, `settings_manager.py:109-116`) is load-bearing: a partial `settings.json` must merge over full defaults, not replace them. Dart's config loader should do the same (deep-merge partial JSON over a full default map) rather than requiring every key present on disk.

---

### `ecom-flutter/lib/core/file_paths.dart` (utility, file-I/O)

**Analog:** `ecom-py/camera_handler.py` (folder/filename construction embedded in `start_recording`, lines 365-374) — see full excerpt under `camera_service.dart` above. This logic is factored out as a standalone helper in the Dart port (RESEARCH.md's `buildVideoPath()`), whereas Python inlines it in `CameraHandler.start_recording()`. Match exactly:
- Date folder format: `%Y-%m-%d` → Dart `DateFormat('yyyy-MM-dd')`.
- Timestamp format: `%Y%m%d_%H%M%S` → Dart `DateFormat('yyyyMMdd_HHmmss')`.
- Filename: `f"{timestamp}_{barcode}.mp4"` — barcode is already uppercased/trimmed by this point (from `barcode_handler.py`'s `process_barcode`).
- Folder creation: `os.makedirs(video_folder, exist_ok=True)` → Dart `Directory(folder).createSync(recursive: true)` (RESEARCH.md Pattern 4 already has this right).
- Label-to-folder-name map (`_get_label_folder_name`, lines 340-347) — reproduce the exact 3-entry map with `"Normal"` as the fallback default for any unrecognized label string.

---

### `ecom-flutter/lib/models/transaction.dart` (model, transform)

**Analog:** `ecom-py/database.py` row shape (via `conn.row_factory = sqlite3.Row` + `dict(row)`, e.g. lines 152-165, 182-189)

No single "model class" exists in Python — rows are returned as plain dicts. The Dart `Transaction` class should have one field per schema column (see database.dart section above for the full column list) with nullable types for columns that are `NULL` until a recording completes (`end_time`, `duration_seconds`, `file_size_mb`, `stop_method`, and all four compression columns). `label` defaults to `'Normal (Standard)'` matching the SQL column default and the Python method parameter defaults consistently used throughout `database.py` and `app_gui.py`.

---

### `ecom-flutter/lib/ui/main_screen.dart` (component, request-response/UI events)

**Analog:** `ecom-py/app_gui.py` (`EcomVideoTrackerApp` class — `create_camera_panel` lines 262-305, `process_barcode` lines 680-761, `_stop_recording_with_progress` lines 763-828, `manual_stop` lines 830+)

**Camera panel structure** (`app_gui.py:262-305`) — establishes the widget layout Phase 1's minimal UI should mirror conceptually (not pixel-for-pixel, since this is Tkinter, but structurally): a camera display area, a recording indicator overlay (initially hidden, shown red when recording — matches CAM-03's "RECORDING" overlay requirement), positioned via a container frame. Key structural fact: `self.recording_indicator` is created but not packed/gridded until recording starts (`# Will be shown when recording starts`) — Dart equivalent: conditionally render the overlay `Container` in the `Stack` based on `isRecording` state, not always-present-but-hidden.

**Barcode processing orchestration — the core control flow to port** (`app_gui.py:680-761`):
```python
def process_barcode(self):
    barcode_input = self.barcode_entry.get().strip()
    if not barcode_input:
        messagebox.showwarning("Input Required", "Please enter a barcode")
        return
    try:
        selected_label = self.label_var.get()
        result = self.barcode_handler.process_barcode(barcode_input, self.camera.is_recording())

        if result['action'] == 'invalid':
            messagebox.showerror("Invalid Barcode", "The barcode entered is invalid")
            return

        if result['action'] == 'start':
            filename = self.camera.start_recording(result['barcode'], selected_label)
            self.current_transaction_id = self.db.create_transaction(result['barcode'], filename, selected_label)
            self.recording_start_time = time.time()
            self.update_ui_recording(True, filename, selected_label)
            self.set_status_bar(f"Recording started: {result['barcode']} ({selected_label})", "success")
            self.barcode_entry.delete(0, tk.END)
            self.barcode_entry.focus()

        elif result['action'] == 'stop_and_start':
            def on_stop_complete(recording_info):
                if recording_info:
                    new_filename = self.camera.start_recording(result['barcode'], selected_label)
                    self.current_transaction_id = self.db.create_transaction(result['barcode'], new_filename, selected_label)
                    self.recording_start_time = time.time()
                    self.update_ui_recording(True, new_filename, selected_label)
                    self.set_status_bar(f"Switched to: {result['barcode']} ({selected_label}) (Saved: {recording_info['duration']}s)", "success")
                    self.load_recordings()
                self.barcode_entry.delete(0, tk.END)
                self.barcode_entry.focus()
            self._stop_recording_with_progress('barcode', on_stop_complete)
    except Exception as e:
        logger.error(f"Error processing barcode: {e}")
        messagebox.showerror("Error", f"Failed to process barcode: {str(e)}")
```
**This is the exact sequence REC-02 must reproduce in Dart:** stop the old recording (async, awaited) → THEN start the new recording with the new barcode → THEN create the new transaction row → THEN update UI. The new recording does not start until the stop completes and its `recording_info` is available — confirms the workflow is genuinely sequential (stop-then-start), not "start new in parallel with stop old." This directly informs Pitfall 1's spike: whatever latency exists between `stopVideoRecording()` resolving and `startVideoRecording()` being called is inherent to this sequential design, matching the existing Python app's behavior (which also does not overlap stop/start).

**Stop-with-progress async pattern** (`app_gui.py:763-828`, `_stop_recording_with_progress`) — runs the (potentially slow) `camera.stop_recording()` call on a background thread while polling every 50ms (`self.root.after(50, check_complete)`) rather than blocking the UI thread, then on completion: updates the DB (`complete_transaction`), queues compression (out of scope Phase 1), and invokes the callback with `recording_info`. Dart equivalent: `await` the async `CameraController.stopVideoRecording()` call directly (Flutter's async/await naturally avoids the polling-thread workaround Tkinter needs) inside a `Future`-returning method, then update DB and invoke `setState`.

**Manual stop button — enablement rule** (per RESEARCH.md REC-03, confirmed by `manual_stop()` guard at `app_gui.py:830-834`):
```python
def manual_stop(self):
    if not self.camera.is_recording():
        messagebox.showwarning("Not Recording", "No recording in progress")
        return
```
Dart: `ElevatedButton(onPressed: isRecording ? stop : null)` (RESEARCH.md's own suggested pattern) is the correct idiom — disable at the widget level rather than guard-and-warn, since Flutter buttons support a `null` onPressed to visually/functionally disable. `stop_method` passed to `complete_transaction` for this path is the literal string `'manual'`.

**Status/error messaging pattern:** Tkinter uses `messagebox.showwarning`/`showerror` (modal dialogs) for invalid input and failures, plus a separate non-modal `set_status_bar(message, "success")` for success feedback. Dart/Flutter equivalent: `showDialog` for warnings/errors matching the modal cases (invalid barcode, "not recording" on manual stop), and a `SnackBar` or persistent status text widget for the success-path status bar messages (`"Recording started: ..."`, `"Switched to: ..."`, `"Recording stopped: ..."`).

---

### `ecom-flutter/lib/main.dart` (entry point)

**Analog:** `ecom-py/app_gui.py` lines 21-32 (logging setup) + implicit `main()` composition root pattern (each entry point in `ecom-py` builds its own handler instances at startup — see database/camera_service below).

**Logging setup — format to replicate for LOG-01** (`ecom-py/app_gui.py:21-32`):
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
Dart equivalent for LOG-01 ("Significant events log to `logs/app.log` and console with timestamps"): ensure `logs/` directory exists before first write (`Directory(logPath).createSync(recursive: true)`), then on every log call append to file **and** print to console — matching the dual `FileHandler` + `StreamHandler` behavior. Format string equivalent: `"$timestamp - $loggerName - $level - $message"` (ISO8601 or similar timestamp, module/class name as logger name, level as `INFO`/`WARNING`/`ERROR` matching Python's level names for grep-compatibility with existing `ecom-py` log files if they're ever compared side-by-side).

**Composition-root pattern** (`ecom-py/app_gui.py` `__init__`, and both `app.py`/`app_gui.py` each independently instantiate `CameraHandler()`, `BarcodeHandler()`, `Database()`, per Component Responsibilities in CLAUDE.md) — Dart `main.dart` should construct the single-process singletons (config load → database open → camera service init → barcode handler) once at startup and pass them down, consistent with "one process, no cross-process sharing" architecture already established by the Python app.

---

## Shared Patterns

### Error handling: fail-loud on writes, fail-safe on reads
**Source:** `ecom-py/database.py` (all methods), `ecom-py/camera_handler.py` (`start_recording`/`stop_recording`)
**Apply to:** `database.dart`, `camera_service.dart`
```python
# Write operations: log then re-raise
except Exception as e:
    logger.error(f"Error creating transaction: {e}")
    raise
# Read operations: log then return safe default
except Exception as e:
    logger.error(f"Error fetching recent transactions: {e}")
    return []
```
Dart: writes should `throw`/propagate exceptions (caller shows a dialog, per `main_screen.dart`'s `catch (e) { showDialog(...) }` pattern mirroring `except Exception as e: messagebox.showerror(...)`); reads should return `null`/`[]` rather than throwing.

### Logging: always log the caught exception inline
**Source:** Every `except Exception as e:` block across `ecom-py/*.py` (per CLAUDE.md Error Handling conventions)
**Apply to:** All new Dart files
```python
logger.error(f"Error <doing x>: {e}")
```
Dart: `logger.error('Error <doing x>: $e')` — same message shape (`"Error <verb-ing>: <exception>"`), applied consistently so `logs/app.log` output is comparable in style to the existing Python app's logs even though the two apps' log files are never merged.

### Barcode normalization: trim then uppercase, at the point of action, not at input
**Source:** `ecom-py/barcode_handler.py:74` (`barcode = barcode.strip().upper()`)
**Apply to:** `barcode_handler.dart`, and anywhere a barcode is displayed/stored (filenames, DB rows, watermark text)
Applies uniformly to both scanner-sourced and manually-typed barcodes (BAR-02's "same code path" requirement) since normalization happens inside `process_barcode()`, after validation, regardless of input source.

### Label string conventions (exact literals, must match verbatim)
**Source:** `ecom-py/settings_manager.py` default label `"Normal (Standard)"`; `ecom-py/camera_handler.py:342-346` label-folder map
**Apply to:** `file_paths.dart`, `database.dart`, `main_screen.dart` (label selector default)
```python
label_folder_map = {
    "Return and Refund Unboxing": "Return and Refund",
    "Return Parcel Unboxing": "Return Parcel",
    "Normal (Standard)": "Normal"
}
```
Phase 1 only exercises the `"Normal (Standard)"` → `"Normal"` case (single-label spike scope), but the map/lookup shape (dict with string-literal keys, `"Normal"` fallback) should be built now for Phase 2 to extend without reshaping.

## No Analog Found

None — every planned Phase 1 file has a clear behavioral analog in `ecom-py/`. The only genuinely novel pieces (no Python analog because they don't exist in the reference app) are:

| File/Concern | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `GlobalBarcodeListener` (top-level `HardwareKeyboard` handler, likely inside `main.dart` or a new `core/barcode_listener.dart`) | event-driven input capture | event-driven | `ecom-py` reads barcodes via a focused Tkinter `Entry` widget (`self.barcode_entry`) — a fundamentally different, focus-dependent input model. BAR-01's focus-independent requirement has no Python precedent; RESEARCH.md's Pattern 2 (`HardwareKeyboard.instance.addHandler` + debounce buffer) is the only available reference, sourced from Flutter's own API docs, not this codebase. Treat as new architecture, spike-validated per Pitfall 2. |
| `window_manager` minimum-size enforcement | config/lifecycle | request-response | Tkinter's desktop GUI does not enforce a minimum window size in the reviewed code — this is a new Phase 1 requirement (CAM-02) with no Python precedent. Use RESEARCH.md's `window_manager.setMinimumSize()` pattern directly. |

## Metadata

**Analog search scope:** `ecom-py/` (all 13 top-level `.py` modules); confirmed no `.dart`/`ecom-flutter/` files exist yet via `find`.
**Files scanned:** `barcode_handler.py` (full, 90 lines), `database.py` (full, 425 lines), `config.py` (full, 80 lines), `camera_handler.py` (full, 642 lines), `settings_manager.py` (full, 183 lines), `camera_utils.py` (partial, lines 1-60), `app_gui.py` (targeted: lines 1-40 imports/logging, lines 262-326 camera/control panel construction, lines 680-840 barcode processing/stop/manual-stop orchestration), `ecom-py/settings.json.example` (full).
**Pattern extraction date:** 2026-07-11
