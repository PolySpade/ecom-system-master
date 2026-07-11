# Codebase Concerns

**Analysis Date:** 2026-07-11

**Scope:** Full repository, application code in `ecom-py/` (Python: Tkinter GUI + Flask web app + OpenCV video recording). No separate test suite or `ecom-qt6/` port exists in this checkout at analysis time.

## Tech Debt

**Business logic duplicated between Flask and Tkinter front-ends:**
- Issue: Barcode start/stop/stop-and-start recording flow, transaction creation, and compression queuing are implemented twice with parallel but independently-maintained code paths.
- Files: `ecom-py/app.py` (`process_barcode`, `manual_stop`, lines 123-258) and `ecom-py/app_gui.py` (`process_barcode`, `_stop_recording_with_progress`, lines 680-830)
- Impact: Any bug fix or behavior change (e.g., label-folder mapping, compression trigger conditions) must be made in two places. They have already drifted slightly — the Flask API has no "saving progress" UX pause that the GUI has via `SavingProgressDialog`.
- Fix approach: Extract a shared `RecordingSessionController` (barcode → action → camera/db/compressor orchestration) that both `app.py` and `app_gui.py` call into, leaving each front-end responsible only for its own UI updates.

**No automated test suite:**
- Issue: No `test_*.py`, `pytest`, or any testing framework exists anywhere in `ecom-py/`.
- Files: entire `ecom-py/` tree
- Impact: Every change to `database.py`, `camera_handler.py`, `barcode_handler.py`, or `video_compressor.py` risks silent regressions. Threading/lifecycle code (camera capture thread, recording thread, compression worker thread) is exactly the kind of logic that benefits most from unit/integration tests and currently has none.
- Fix approach: Start with `barcode_handler.py` and `database.py` (pure logic, easy to isolate with an in-memory/temp SQLite file) before tackling harder-to-test camera/threading code.

**Mismatched dependency pins between `requirements.txt` and `pyproject.toml`:**
- Issue: `requirements.txt` pins `Flask==3.0.0`, `opencv-python==4.9.0.80`, `Pillow==10.2.0`; `pyproject.toml` declares `flask>=3.1.2`, `opencv-python>=4.12.0.88`, `pillow>=12.1.0`. `pyinstaller` and `tkcalendar` version constraints also differ (pyinstaller is absent from `pyproject.toml` entirely).
- Files: `ecom-py/requirements.txt`, `ecom-py/pyproject.toml`
- Impact: Depending on which file is used to install (`pip install -r requirements.txt` vs `uv sync` / `pip install -e .`), a developer gets a different OpenCV/Flask major-ish version, which can change camera backend behavior (MSMF quirks) or Flask API behavior. Increases "works on my machine" risk.
- Fix approach: Pick one manifest as source of truth (`pyproject.toml` if using `uv`/modern tooling) and generate/pin `requirements.txt` from it, or delete the redundant file.

**Dead/unrelated utility script committed inside application package:**
- Issue: `game_scanner.py` is a standalone ROM-collection directory scanner/CSV comparator with no relationship to the e-commerce video tracker.
- Files: `ecom-py/game_scanner.py`
- Impact: Confuses newcomers about what belongs to the product; increases surface area scanned by tooling/linters; ships inside any packaging that globs `ecom-py/*.py`.
- Fix approach: Move to a personal-tools repo/folder outside the product codebase, or delete if no longer needed.

**One-off hardcoded watermark-fix script left in production tree:**
- Issue: `add_watermark.py` hardcodes a specific barcode (`MP1431079227`), a specific timestamp (`datetime(2026, 1, 26, 14, 37, 9)`), and local file paths (`to_modify.mp4`, bundled `ffmpeg/bin/ffmpeg.exe`). It was clearly written to manually re-watermark one specific video after the fact.
- Files: `ecom-py/add_watermark.py`
- Impact: Not reusable as-is; risks being run against the wrong video and silently overwriting `to_modify_watermarked.mp4` with wrong timestamps/barcode. No safeguard against accidental execution.
- Fix approach: Parameterize via CLI args (input path, barcode, start time) or move into a `scripts/one-off/` folder clearly marked as non-production, dated, and disposable.

**No connection pooling / connections not guaranteed to close on exception:**
- Issue: Every method in `Database` follows the pattern `conn = self.get_connection(); ...; conn.close()` inside a single `try` block, with `conn.close()` only reached on the success path. There is no `finally` or context manager (`with sqlite3.connect(...)`).
- Files: `ecom-py/database.py` (all methods, e.g. `create_transaction` lines 84-101, `advanced_search` lines 274-340)
- Impact: If an exception occurs between opening the connection and the `conn.close()` call (e.g., a malformed query, disk I/O error), the connection is leaked. Under Flask running with `threaded=True` (`ecom-py/app.py` line 461) this can accumulate leaked SQLite connections/file handles over a long-running kiosk session.
- Fix approach: Wrap each method body in `with self.get_connection() as conn:` or a `try/finally` that always calls `conn.close()`.

**Global mutable state for "current transaction" in Flask app:**
- Issue: `current_transaction_id` is a module-level global reassigned across three separate route handlers (`process_barcode`, `manual_stop`) with no locking.
- Files: `ecom-py/app.py` (line 64, and `global current_transaction_id` in lines 126, 224)
- Impact: Flask runs `threaded=True`; two concurrent requests (e.g., a barcode POST and a manual stop POST arriving close together) can race on this global, corrupting which transaction gets completed. In a single-scanner kiosk setup this is low-probability but not impossible (e.g., double-scan, network retry from a flaky browser).
- Fix approach: Move the "current recording session" state into `CameraHandler` (which already tracks `self.recording`/`self.current_filename` under `self.lock`) or protect `current_transaction_id` mutations with an explicit lock.

**Broad bare `except:` clauses swallow all errors including `KeyboardInterrupt`/`SystemExit`:**
- Issue: Twenty bare `except:` blocks across the codebase silently suppress all exceptions, including ones a developer would want to see during debugging.
- Files: `ecom-py/game_scanner.py:38,49,69,79`, `ecom-py/bulk_compressor.py:94,322,431,563`, `ecom-py/camera_handler.py:178,616,634`, `ecom-py/camera_utils.py:269,276,296,299`, `ecom-py/app_gui.py:102,610,1069,2386`, `ecom-py/video_compressor.py:334`
- Impact: Makes root-causing camera reinit failures, UI frame-render errors, and FFmpeg cleanup issues harder — errors vanish with no log line. Some of these are cleanup/best-effort code (acceptable), but several are not (e.g., `app_gui.py:102`, `app_gui.py:1069`).
- Fix approach: Replace with `except Exception:` at minimum, and add a `logger.debug`/`logger.warning` call even in "best effort" cleanup paths so failures are visible when diagnosing field issues.

## Known Bugs

**`DEBUG_MODE` and `FLASK_HOST` code-level defaults contradict documented security posture:**
- Symptoms: If `settings.json` is missing the `app.debug_mode` or `app.flask_host` keys under conditions where `SettingsManager`'s own `DEFAULT_SETTINGS` merge is bypassed, `config.py` falls back to `flask_host = '0.0.0.0'` and `debug_mode = True` (see the third argument of `_settings.get('app', 'flask_host', '0.0.0.0')` and `_settings.get('app', 'debug_mode', True)`).
- Files: `ecom-py/config.py` lines 40-42
- Trigger: `SettingsManager.DEFAULT_SETTINGS['app']` (in `ecom-py/settings_manager.py` lines 34-38) correctly defaults to `127.0.0.1` / `False`, and `settings.json.example` also ships safe defaults, so in the normal flow this fallback is never hit. It only activates if `_settings.get()` is called on a settings dict where the `'app'` category exists but is missing these specific keys (e.g., a hand-edited or corrupted `settings.json` with a partial `"app": {}` block) or if `SettingsManager` is used standalone without going through `config.py`'s merge.
- Workaround: None currently; the fallback values are just latent — a corrupted/partial settings file is the trigger. Given the `CHANGELOG.md` "Security" section explicitly documents "Default localhost binding" and "No hardcoded credentials" as intentional decisions, these hardcoded `0.0.0.0`/`True` fallbacks in `config.py` are inconsistent with stated intent and should be aligned to safe defaults (`127.0.0.1` / `False`).

**Video file overwrite risk when `stop_and_start` racing with slow disk I/O:**
- Symptoms: `CameraHandler.start_recording` raises `Exception("Already recording")` if called while `self.recording` is `True`, but the Flask `stop_and_start` handler (`ecom-py/app.py` lines 155-187) calls `camera.stop_recording()` then immediately `camera.start_recording()` without awaiting compression queuing completion or confirming the video writer fully flushed to disk on slow storage (e.g., a network share or slow USB drive configured via `storage.video_path`).
- Files: `ecom-py/app.py` lines 155-187, `ecom-py/camera_handler.py` lines 491-561
- Trigger: High-frequency barcode scans on slow storage devices.
- Workaround: None built in; `stop_recording` does join the recording thread with a 2-second timeout (`ecom-py/camera_handler.py` line 507) but does not verify the file write actually completed before returning.

## Security Considerations

**No authentication on any Flask route:**
- Risk: Every API endpoint (`/api/settings` GET/POST, `/api/settings/reset`, `/api/camera/restart`, `/api/barcode`, `/videos/<date_folder>/<filename>`, etc.) is unauthenticated. Anyone who can reach the Flask server can view/download all recorded videos, change camera exposure/resolution settings, reset settings to defaults, or restart the camera.
- Files: `ecom-py/app.py` (all `@app.route` handlers)
- Current mitigation: `FLASK_HOST` defaults to `127.0.0.1` in `settings_manager.py`/`settings.json.example`, limiting exposure to localhost unless explicitly reconfigured to `0.0.0.0` for LAN access (documented as an intentional trade-off in `CHANGELOG.md`).
- Recommendations: If LAN/network access is ever enabled (the settings UI explicitly supports switching to `0.0.0.0`), add at minimum a shared-secret header or basic auth before exposing `/api/settings` and `/videos/*` beyond localhost — currently there is no code path that adds auth even when binding is widened.

**Path traversal risk on video serving routes:**
- Risk: `serve_video` and `download_video` build a directory path from a user-supplied `date_folder` URL segment and pass a user-supplied `filename` to `send_from_directory`. Flask's `send_from_directory` normally blocks `../` in the `filename` argument, but `date_folder` is concatenated with `os.path.join` before that safety check applies, so a crafted `date_folder` value (e.g., `..%2f..%2fetc`) needs to be verified against Flask/Werkzeug's current path-normalization guarantees for the *directory* argument, not just the filename.
- Files: `ecom-py/app.py` lines 317-336 (`serve_video`, `download_video`)
- Current mitigation: Relies entirely on Werkzeug's internal `safe_join` behavior inside `send_from_directory`; there is no explicit application-level validation that `date_folder` matches a `YYYY-MM-DD` pattern.
- Recommendations: Validate `date_folder` against a strict `^\d{4}-\d{2}-\d{2}$` regex before using it in `os.path.join`, and validate `filename` has no path separators, before calling `send_from_directory`.

**`.env`-equivalent secrets file not present, but `settings.json` (with camera/storage config) is gitignored — verify no real deployment settings get committed accidentally:**
- Risk: `ecom-py/.gitignore` correctly excludes `settings.json`, `database.db`, `videos/`, and `logs/` from version control. No secrets were found in tracked files during this audit.
- Files: `ecom-py/.gitignore`
- Current mitigation: Proper `.gitignore` entries already in place.
- Recommendations: None required now; keep this pattern as new config surfaces are added (e.g., if cloud storage/API keys are introduced later, ensure they route through `settings.json` rather than being hardcoded).

**`DEBUG_MODE` enabling Flask's interactive debugger (Werkzeug) would expose a remote code execution console if ever left on and bound to `0.0.0.0`:**
- Risk: Flask's debug mode, when `debug=True`, enables the Werkzeug interactive debugger, which allows arbitrary Python code execution from any client able to trigger an unhandled exception and reach the debugger PIN prompt. Combined with the latent `config.py` fallback default of `debug_mode=True` (see Known Bugs above) and a widened `flask_host`, this is a severe risk if both defaults are ever simultaneously active.
- Files: `ecom-py/config.py` line 42, `ecom-py/app.py` line 460 (`app.run(..., debug=config.DEBUG_MODE, ...)`)
- Current mitigation: Default settings files ship with `debug_mode: false`.
- Recommendations: Remove the `True` fallback in `config.py` entirely (see Known Bugs) so there is no code path, however unlikely, that enables debug mode by default.

## Performance Bottlenecks

**FFmpeg compression runs strictly serially, one job at a time:**
- Problem: `VideoCompressor._worker_loop` (single background thread) processes one `CompressionJob` at a time from a `queue.Queue`, with each job blocking on `process.poll()` in a `while` loop with `time.sleep(2)` for up to 1 hour (`ecom-py/video_compressor.py` lines 419-438).
- Files: `ecom-py/video_compressor.py` lines 239-270, 394-438
- Cause: Single worker thread by design (to limit CPU/priority impact on the recording app), but during bursts of rapid barcode scanning (many short videos queued back-to-back), the compression backlog can grow unbounded since `get_queue_status` only reports `queue_size` without any backpressure or queue-depth limit.
- Improvement path: Add a max-queue-depth warning/alert surfaced to the UI (partial support exists via `compression_label` in `app_gui.py`), and consider a configurable second worker for multi-core kiosk machines, gated by total CPU budget.

**Video preview downscaling happens on every displayed frame, even when the container size hasn't changed, and again independently for GUI vs. web streaming:**
- Problem: `CameraHandler.get_preview_frame` performs a `cv2.resize` on every call, both for the Tkinter preview loop (`app_gui.py.update_camera_feed`, scheduled every 33ms via `self.root.after`) and separately for the Flask MJPEG stream (`generate_frames`, also ~30 FPS). If both UIs run concurrently against the same `CameraHandler` instance, two independent resize+encode pipelines run against the same source frames.
- Files: `ecom-py/camera_handler.py` lines 212-244, 318-338; `ecom-py/app_gui.py` lines 590-636
- Cause: No shared/cached "preview frame" — each consumer resizes from `self.latest_frame` independently.
- Improvement path: Since Tkinter GUI and Flask web app appear to be alternative front-ends (not typically run simultaneously against the same camera instance per `run_gui.bat` / `run_web.bat`), this is lower priority, but if simultaneous operation is ever supported, cache a single downscaled frame per capture cycle for reuse by both consumers.

**Frame buffer sized for 2 seconds at 30fps regardless of configured FPS:**
- Problem: `self.frame_buffer = deque(maxlen=60)` is a fixed size comment-documented as "Buffer up to 2 seconds at 30fps," but `VIDEO_FPS` is configurable up to 60fps per `settings_manager.py`. At 60fps, the buffer only holds 1 second of frames.
- Files: `ecom-py/camera_handler.py` line 38
- Cause: Hardcoded `maxlen=60` not derived from `config.VIDEO_FPS`.
- Improvement path: Compute `maxlen` dynamically as `int(config.VIDEO_FPS * 2)` at camera init/reinit time so buffer depth scales with configured FPS, reducing frame drops during I/O stalls at higher frame rates.

## Fragile Areas

**Camera reinitialization and thread lifecycle (`CameraHandler`):**
- Files: `ecom-py/camera_handler.py` lines 101-203, 573-618
- Why fragile: Multiple interacting mutable flags (`self.recording`, `self.capture_running`, `self._reinit_lock`, `self._last_reinit_time`) coordinate camera capture thread, recording thread, and manual reinit (triggered via `/api/camera/restart` or Settings dialog). The reinit path in `reinitialize()` calls `importlib.reload(config)` (line 599) which reloads the entire `config` module — a broad, side-effect-heavy operation that also re-executes `SettingsManager(...)` instantiation logic in `config.py` module scope, indirectly affecting `DATABASE_PATH`/`VIDEO_STORAGE_PATH` globals used elsewhere.
- Safe modification: Avoid `importlib.reload(config)` — call `config.reload_config()` (already defined for this exact purpose in `ecom-py/config.py` lines 55-79) instead, since it selectively reassigns only the intended globals rather than re-executing the whole module.
- Test coverage: None. Any change to camera lifecycle should be manually tested against camera disconnect/reconnect scenarios (per the `_max_failures_before_reinit` / `_reinit_cooldown` logic) before shipping.

**`SearchWindow`, `SettingsDialog`, and `EcomVideoTrackerApp` in `app_gui.py` (2491 lines, 4 classes, no separation of concerns):**
- Files: `ecom-py/app_gui.py`
- Why fragile: A single file mixes UI construction, business logic (barcode processing, recording orchestration), and direct database/camera calls across `EcomVideoTrackerApp` (lines 90-1080), `SearchWindow` (1081-1640), and `SettingsDialog` (1641-2491). At this size, locating and safely modifying any one feature (e.g., label folder mapping, which is duplicated from `camera_handler.py`'s `_get_label_folder_name`) requires reading large portions of unrelated UI code.
- Safe modification: When adding features, prefer extracting new logic into `camera_handler.py`/`database.py`/a new controller module rather than adding more methods to `EcomVideoTrackerApp`.
- Test coverage: None (Tkinter UI code is inherently harder to unit test, but the orchestration logic it contains currently has zero coverage even conceptually).

**Compression "replace original" step performs delete-then-rename without atomic safety net:**
- Files: `ecom-py/video_compressor.py` lines 305-315
- Why fragile: `os.remove(job.video_path)` executes before `os.rename(output_path, job.video_path)`. If the process crashes or is killed between these two lines (e.g., power loss on a kiosk PC, forced app termination), the original video is deleted and the compressed replacement is never renamed into place — resulting in permanent data loss for that transaction's video, while the database `compressed_filename` may already reference a suffix-named file that no longer matches expectations.
- Safe modification: Reorder to rename-then-delete semantics, or use `os.replace()` (atomic on the same filesystem) to swap the compressed file into the original's path without an intermediate delete step.
- Test coverage: None; this path only exercises during real FFmpeg runs, not covered by any automated test.

## Scaling Limits

**Single SQLite database file, no WAL mode configured:**
- Current capacity: `sqlite3.connect(self.db_path)` in `ecom-py/database.py` line 17 uses default SQLite journal mode, not WAL. Combined with Flask's `threaded=True` (`ecom-py/app.py` line 461) and the GUI potentially running its own `Database` instance concurrently (if both GUI and web app run against the same `database.db`), default rollback-journal mode can produce `database is locked` errors under concurrent writes.
- Limit: Any scenario with simultaneous writes from GUI + web app, or from web app's Flask worker threads writing at the same moment (e.g., `create_transaction` and `update_compression_status` from the compressor callback firing concurrently), risks lock contention.
- Scaling path: Enable WAL mode (`PRAGMA journal_mode=WAL;`) at connection time in `Database.get_connection()`, and consider a single shared connection with a lock (or a connection-per-thread pattern) rather than opening a new connection per call.

**500GB storage ceiling defined but not enforced anywhere in code:**
- Current capacity: `MAX_STORAGE_GB = 500` is defined in `ecom-py/config.py` line 32 but is not referenced anywhere else in the codebase (`grep` for `MAX_STORAGE_GB` usage outside its definition finds no consumers).
- Limit: The application will continue recording and accumulating video files indefinitely, with `db.get_total_storage_used()` only used for display purposes (`/api/status`, GUI storage label) — there is no check that stops recording or warns proactively when approaching the 500GB ceiling, risking disk-full failures on the recording machine mid-transaction.
- Scaling path: Add a storage-check step before `start_recording` (in both `app.py` and `app_gui.py`, or better, centralized in `CameraHandler.start_recording`) that compares `db.get_total_storage_used()` (or actual disk free space via `shutil.disk_usage`) against `config.MAX_STORAGE_GB` and blocks/warns accordingly.

## Dependencies at Risk

**`opencv-python` version drift between manifests:**
- Risk: See Tech Debt section above — `requirements.txt` pins `4.9.0.80` while `pyproject.toml` allows `>=4.12.0.88`. OpenCV's camera backend behavior (MSMF/DirectShow quirks referenced throughout `camera_handler.py` and `camera_utils.py` comments) has historically changed between minor versions on Windows.
- Impact: A developer installing via `pyproject.toml` may get materially different camera enumeration/exposure behavior than what was tested against `requirements.txt`'s pin, especially relevant given the extensive Windows-specific MSMF/DirectShow handling in this codebase.
- Migration plan: Standardize on one manifest, pin exact versions matching what was last validated on the target Windows deployment machines, and document the validated OpenCV version in `README.md`.

**FFmpeg is an external, unmanaged runtime dependency with soft-fail behavior:**
- Risk: `VideoCompressor.check_ffmpeg_installed()` searches several hardcoded Windows paths and falls back to PATH lookup; if FFmpeg is missing, compression is silently skipped (`CompressionStatus.SKIPPED`) rather than failing loudly, per `queue_compression` lines 193-202 in `ecom-py/video_compressor.py`.
- Impact: On a fresh deployment machine without FFmpeg installed, all videos will silently remain uncompressed indefinitely with no user-facing error beyond a queue-status label — administrators may not notice storage is filling up faster than expected because compression never actually ran.
- Migration plan: Surface a persistent, hard-to-miss warning in both UIs (GUI status bar / web dashboard banner) when `check_ffmpeg_installed()` returns `False`, rather than only reflecting it in the on-demand `/api/compression/check-ffmpeg` endpoint and per-job skip logs.

## Missing Critical Features

**No storage-full / low-disk-space handling:**
- Problem: As noted under Scaling Limits, there is no active check for available disk space before or during recording. `cv2.VideoWriter` will typically fail silently or produce a corrupt/truncated file if the disk fills mid-write, and `stop_recording()`'s `os.path.getsize(video_path)` call (`ecom-py/camera_handler.py` line 537) would raise `FileNotFoundError` if the writer never successfully created the file, propagating as a generic 500 error to the UI.
- Blocks: Reliable unattended kiosk operation over long periods without an operator manually monitoring disk usage.

**No log rotation for `logs/app.log`:**
- Problem: `logging.FileHandler(config.LOG_FILE)` in `ecom-py/app.py` lines 14-21 uses a plain `FileHandler`, not `RotatingFileHandler`/`TimedRotatingFileHandler`. With `LOG_LEVEL = 'DEBUG'` (`ecom-py/config.py` line 45) logging every camera frame error and detailed operational info, this file grows unbounded over the lifetime of a long-running kiosk deployment.
- Blocks: Long-term unattended deployments without manual log cleanup; risks disk space consumption purely from logs on top of video storage.

## Test Coverage Gaps

**Entire codebase — no tests exist:**
- What's not tested: All modules (`database.py`, `barcode_handler.py`, `camera_handler.py`, `video_compressor.py`, `settings_manager.py`, `app.py` routes, `app_gui.py` logic).
- Files: `ecom-py/*.py`
- Risk: Any refactor (e.g., addressing the connection-leak or global-state issues above) has no regression safety net; correctness currently depends entirely on manual testing.
- Priority: High for `database.py` and `barcode_handler.py` (pure, easily testable logic with no hardware dependency); Medium for `video_compressor.py` (can be tested with a mocked/fake `ffmpeg` binary); Low for `camera_handler.py`/`app_gui.py` (hardware- and UI-dependent, harder to test but could benefit from extracting pure logic like `_get_label_folder_name` into testable units).

---

*Concerns audit: 2026-07-11*
