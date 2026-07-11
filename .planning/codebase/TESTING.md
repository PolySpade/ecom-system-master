# Testing Patterns

**Analysis Date:** 2026-07-11

## Test Framework

**Runner:**
- None. No `pytest`, `unittest`, `nose`, or any other test runner is installed, configured, or invoked anywhere in the repository.

**Evidence:**
- No `tests/` directory, no `test_*.py` / `*_test.py` files anywhere under `ecom-py/` or the repo root.
- `grep -rl "import pytest\|import unittest\|from unittest"` across the entire `ecom-py/` tree returns zero matches.
- `ecom-py/pyproject.toml` declares only runtime dependencies (`flask`, `opencv-python`, `pillow`, `pygrabber`, `tkcalendar`) — no `[tool.pytest.ini_options]`, no `[dependency-groups.dev]`/`[project.optional-dependencies]` test group.
- `ecom-py/requirements.txt` similarly lists only runtime packages plus `pyinstaller` (for building the `.exe`) — no `pytest`, `pytest-cov`, `pytest-mock`, `coverage`, `tox`, or `nox`.
- No `pytest.ini`, `setup.cfg`, `tox.ini`, `.coveragerc`, or CI workflow files (`.github/workflows/`) exist in the repo.

**Assertion Library:**
- Not applicable — no test framework present.

**Run Commands:**
```bash
# No test command exists. There is nothing to run.
```

## Test File Organization

Not applicable. No test files exist.

## Test Structure

Not applicable.

## Mocking

Not applicable. No mocking framework (`unittest.mock`, `pytest-mock`, `unittest.mock.patch`) is used anywhere in the codebase.

## Fixtures and Factories

Not applicable.

## Coverage

**Requirements:** None enforced. No coverage tooling is configured.

**View Coverage:**
```bash
# Not applicable — no coverage tool installed
```

## Manual / Informal Verification Observed Instead of Automated Tests

The codebase relies entirely on manual verification. Evidence of this approach:

- `ecom-py/README.md` documents a "Troubleshooting" section (camera not working, port in use, dependency issues, database locked, video files not saving) as the primary quality-assurance mechanism — problems are diagnosed by a human reading logs, not by automated regression tests.
- `ecom-py/game_scanner.py` and `ecom-py/build_compressor.py` appear to be standalone diagnostic/build utility scripts run manually rather than test suites (`ecom-py/game_scanner.py` is 187 lines with bare `except:` blocks used for best-effort hardware probing, consistent with an interactive diagnostic tool, not a test).
- Extensive `logging` (see `ecom-py/CONVENTIONS.md` equivalent — `logger.info`/`logger.error` on nearly every method) is the primary tool for post-hoc debugging in place of assertions or automated checks. Logs are written to `logs/app.log` (`ecom-py/config.py:46`) and are the documented first troubleshooting step (`ecom-py/README.md` "Support" section: "Check the logs").
- `ecom-py/CHANGELOG.md` describes "Phase 1 MVP Complete" with a large feature list and no mention of a test suite or QA process.

## Test Types

**Unit Tests:** None exist.

**Integration Tests:** None exist.

**E2E Tests:** None exist.

## Recommendations for Introducing Tests

If a future phase adds testing to this codebase, these are the natural seams given the current architecture:

**Good candidates for pure unit tests (no I/O mocking needed):**
- `BarcodeHandler` (`ecom-py/barcode_handler.py`) — `validate_barcode()`, `is_start_code()`, `is_stop_code()`, `process_barcode()` are pure functions/methods operating on strings and simple state (`self.last_barcode`). No file, network, or camera I/O.
- `SettingsManager._deep_merge()` (`ecom-py/settings_manager.py:109-116`) — pure dict-merging static method, trivially testable.
- `Database.advanced_search()` sort-column/sort-order validation logic (`ecom-py/database.py:301-307`) — the whitelist validation (`valid_sort_columns`) is a pure branch worth covering in isolation, though it's currently embedded inside a method that also does I/O.

**Candidates requiring a test double / temp resource:**
- `Database` (`ecom-py/database.py`) — accepts `db_path` in its constructor (`__init__(self, db_path: str = config.DATABASE_PATH)`), so tests can instantiate it against a temporary SQLite file (e.g. `tempfile.NamedTemporaryFile` or `:memory:` after adjusting `get_connection()`) rather than mocking `sqlite3` directly. This is the most testable I/O boundary in the codebase today.
- `VideoCompressor.check_ffmpeg_installed()` (`ecom-py/video_compressor.py:84-140`) — shells out via `subprocess.run`; would need `subprocess.run` mocked/patched to test path-resolution logic without requiring FFmpeg installed.

**Hard to test without significant refactoring:**
- `CameraHandler` (`ecom-py/camera_handler.py`) — tightly coupled to `cv2.VideoCapture`, real threading, and `time.sleep` for camera warmup; would need dependency injection of the OpenCV capture object or a hardware abstraction layer before meaningful unit tests are feasible.
- `EcomVideoTrackerApp` and dialogs in `ecom-py/app_gui.py` — Tkinter UI classes with side-effecting `__init__` (creates real widgets, starts real threads); testing would require either a headless Tk environment or extracting business logic out of the UI classes first.
- Flask routes in `ecom-py/app.py` are thin wrappers around `camera`, `barcode_handler`, `db`, and `compressor` module-level globals initialized at import time (`ecom-py/app.py:29-31`) — introducing `pytest` + Flask's test client would require refactoring these globals into an app factory pattern (`create_app()`) to allow test isolation, since currently importing `app.py` immediately opens the camera and starts the compressor worker thread as a side effect of import.

---

*Testing analysis: 2026-07-11*
