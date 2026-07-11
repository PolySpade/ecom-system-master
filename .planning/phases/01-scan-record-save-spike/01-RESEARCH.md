# Phase 1: Scan-Record-Save Spike - Research

**Researched:** 2026-07-11
**Domain:** Flutter Windows desktop camera capture/recording, keyboard-wedge input, SQLite persistence
**Confidence:** MEDIUM-HIGH (stack/versions HIGH; camera recording reliability and global keyboard focus behavior are genuinely unresolved even in upstream sources — this phase's entire purpose is to resolve them empirically)

## Summary

This phase is a hardware-validation spike, not a feature build. Its job is to prove — on the real target Windows machine and real webcam/scanner hardware — that `camera` + `camera_windows` can do continuous stop-and-start-immediately MP4 recording without dropped frames, and that keyboard-wedge barcode input can be captured reliably regardless of UI focus state. Prior project-level research (`.planning/research/STACK.md`, `PITFALLS.md`) already identified the standard stack and the two highest-risk unknowns in detail; this research re-verifies those package choices against live pub.dev data (all confirmed current and unchanged) and digs one level deeper into the two mechanisms this phase must prove: (1) `CameraController.stopVideoRecording()` → `startVideoRecording()` back-to-back reliability, which is **undocumented** in official Flutter docs — no source (official docs, GitHub issues, or community writeups) states a minimum safe interval or confirms zero-frame-loss behavior; and (2) `HardwareKeyboard.instance.addHandler` focus-independence, which has **directly contradictory information** across official Flutter docs and a currently open, unresolved GitHub issue (#160786) about the handler failing to fire after a TextField has been focused/edited on desktop in Flutter 3.27+ (the project's installed Flutter is 3.41.6, later than the affected versions — status on 3.41.6 is unverified and must be tested directly, not assumed fixed).

The project's Flutter SDK is already installed locally (3.41.6 stable, Dart 3.11.4) on the Linux dev machine; per project memory, actual Windows builds, hardware camera testing, and barcode scanner testing happen on a separate Windows 10/11 machine. Plans for this phase must explicitly split tasks: cross-platform Dart/architecture work that can be written and unit-verified on Linux, versus hardware-dependent verification steps that require the Windows machine and cannot be simulated. FFmpeg is available on the Linux dev machine (`/usr/bin/ffmpeg` 6.1.1) for tooling/CI purposes, but the FFmpeg compression pipeline itself is out of scope for Phase 1 (deferred to Phase 3) — Phase 1 only needs to write video files whose codec/container is compatible with later compression, not perform compression.

**Primary recommendation:** Use `camera` (`^0.12.0+1`) + `camera_windows` (`^0.2.6+4`) as the camera backend, `sqflite_common_ffi` (`^2.4.2`) for SQLite, a top-level `HardwareKeyboard.instance.addHandler` with an inter-key timeout buffer for barcode capture, and treat both the record/stop/record-again cycle and the focus-independent keyboard capture as explicit spike-and-verify tasks with real hardware — not assumptions carried in from documentation, because the documentation itself does not resolve either question.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Live camera preview rendering | Client (Flutter UI, `camera` texture widget) | — | `camera_windows` renders via `flutter::TextureVariant`/`TextureRegistrar`, a native-to-Dart texture bridge; this is purely a client-tier rendering concern |
| Video capture + recording to file | Client (native plugin: `camera_windows` via Windows Media Foundation) | Filesystem | Recording happens inside the platform plugin's native code (C++/Media Foundation), invoked from Dart via platform channel; output lands on local disk |
| Barcode input capture (keyboard-wedge) | Client (Flutter `HardwareKeyboard` API) | — | Purely an OS-to-Flutter-app keyboard event concern; no server/backend involved in this desktop app |
| Barcode state machine (start/stop-and-start/stop decision) | Client (Dart application logic) | — | Direct port of `ecom-py/barcode_handler.py`; no network or backend tier exists in this desktop app |
| Transaction persistence (SQLite) | Database/Storage (local SQLite file via `sqflite_common_ffi`) | Client (Dart data-access layer) | Local file-based DB, no separate DB server; Dart code owns the query layer directly (no ORM), mirroring `ecom-py/database.py`'s raw-SQL pattern |
| Video file storage | Database/Storage (local filesystem) | — | `videos/YYYY-MM-DD/<Label>/...` folder structure on local disk, schema-compatible with `ecom-py` |
| Settings (camera index, resolution/FPS relevant to this phase) | Client (Dart, JSON file read at startup) | Storage (settings.json beside exe) | No settings UI in Phase 1 (SET-01 here means "camera selection exists," full Settings dialog is Phase 4) — read-only config load is sufficient |
| Logging | Client (Dart, `dart:io File` append) | Storage (`logs/app.log`) | Direct file write from the single desktop process; no centralized/remote logging tier exists or is planned |

**Note:** This is a single-tier desktop application (no client/server split) — the map above exists primarily to distinguish "native plugin / OS boundary" concerns from "pure Dart application logic" concerns, which is the relevant boundary for this project instead of a typical web-app tier split.

## User Constraints

No CONTEXT.md exists for this phase — `/gsd:discuss-phase` was not run before this research (standalone `--research-phase` invocation, or planner will run discuss-phase separately). All findings below are unconstrained recommendations for the planner to evaluate; there are no locked user decisions or deferred-idea boundaries to respect beyond what is already fixed in `ROADMAP.md` and `REQUIREMENTS.md` (read and incorporated above).

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REC-01 | Scan barcode while idle to start recording tagged with that barcode | `CameraController.startVideoRecording()` (camera package); barcode state machine port of `barcode_handler.py` — see Code Examples |
| REC-02 | Scan new barcode while recording to stop-and-save previous, immediately start new | Core unknown of this phase — `stopVideoRecording()` → `startVideoRecording()` back-to-back reliability is **undocumented**; must be spike-tested (see Common Pitfalls, Pitfall 1) |
| REC-03 | Manual "Stop Recording" button, disabled while idle | Standard Flutter state-driven button enablement; no library risk, straightforward `ElevatedButton(onPressed: isRecording ? stop : null)` pattern |
| REC-05 | Barcode validated non-empty/trimmed/uppercased, no format validation | Direct port of `BarcodeHandler.validate_barcode()` — trivial Dart string logic, no library needed |
| BAR-01 | USB keyboard-wedge input captured regardless of focus, including with dialogs open | `HardwareKeyboard.instance.addHandler` — focus-independence is contested in official docs vs. GitHub issue #160786; must be spike-tested on the actual Flutter 3.41.6 install with real scanner hardware (see Common Pitfalls, Pitfall 2) |
| BAR-02 | Manual barcode typing via Enter or Submit button, same code path as scanner | Standard `TextField(onSubmitted:)` + shared processing function; no library risk |
| CAM-01 | Live preview ~30fps, independent of recording state | `CameraController.buildPreview()` texture widget; preview and recording are documented as independently controllable in the `camera` plugin's architecture |
| CAM-02 | Preview scales with window resize, min 800x600 | `window_manager` package (`setMinimumSize`) + standard Flutter `AspectRatio`/`FittedBox` around the camera preview widget |
| CAM-03 | Red "RECORDING" indicator overlay while recording | Pure Flutter widget overlay (`Stack` + conditional `Container`), no library needed |
| STO-01 | Videos save to `videos/YYYY-MM-DD/<LabelFolder>/YYYYMMDD_HHMMSS_BARCODE.mp4`, folders auto-created | `dart:io Directory.create(recursive: true)` + `path` package for joining; direct port of `camera_handler.py`'s folder logic — see Code Examples |
| DB-01 | Every recording writes a transaction row matching `ecom-py` schema exactly | `sqflite_common_ffi` raw SQL against the identical `CREATE TABLE transactions (...)` schema from `ecom-py/database.py` — see Code Examples for exact schema |
| DB-02 | One long-lived connection with WAL mode enabled, no per-call churn | `sqflite_common_ffi`'s `databaseFactoryFfi.openDatabase()` opened once at app startup; WAL enabled via `db.execute('PRAGMA journal_mode=WAL')` in `onConfigure` — confirmed via community sources, see Code Examples |
| SET-01 | Select camera by human-readable name, non-blocking Refresh Cameras | `CameraDescription.name` from `availableCameras()` — but see Common Pitfalls (camera enumeration gaps are a documented open Flutter issue); async `Future`-based refresh naturally non-blocking |
| LOG-01 | Significant events log to `logs/app.log` and console with timestamps | `dart:io File.writeAsString(mode: FileMode.append)` direct port of the Python `logging` pattern; no heavy dependency needed for this phase's scope |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `camera` | `0.12.0+1` [VERIFIED: pub.dev registry, published 2026-03-19] | Cross-platform camera plugin interface | Official Flutter-team plugin (`publisher:flutter.dev`), 664k downloads/30-days, the only viable entry point to `camera_windows` |
| `camera_windows` | `0.2.6+4` [VERIFIED: pub.dev registry, published 2025-11-19] | Windows federated implementation via Media Foundation `CaptureEngine` | Official Flutter-team plugin (`publisher:flutter.dev`); implements the standard `camera_platform_interface` so app code stays portable; only 590 downloads/30-days (small user base — Windows desktop camera use is niche) but max pub score (160/160) and correct publisher |
| `sqflite_common_ffi` | `2.4.2` [VERIFIED: pub.dev registry, published 2026-06-11] | FFI-based SQLite for Windows/Linux desktop | Maintained by `tekartik.com` (the `sqflite` package author), 170k downloads/30-days; raw-SQL API matches `ecom-py/database.py`'s hand-written SQL almost verbatim — lowest-risk path to schema compatibility |
| `win32` | `6.3.0` [VERIFIED: pub.dev registry, published 2026-05-22] | Windows FFI bindings | Maintained by `halildurmus.dev`, marked `is:flutter-favorite`, 6.4M downloads/30-days; needed for camera enumeration fallback and (later phases) process-priority control |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `window_manager` | `0.5.2` [VERIFIED: pub.dev registry, published 2026-07-04] | Enforce min window size (800x600), custom close-intercept | Use from Phase 1 for CAM-02's minimum-size requirement; `leanflutter.dev` publisher, 473k downloads/30-days |
| `path` | `1.9.1` [VERIFIED: pub.dev registry, published 2024-10-17] | Cross-platform path joining | Use for all `videos/YYYY-MM-DD/<Label>/...` path construction instead of manual string concatenation |
| `path_provider` | `2.1.6` [VERIFIED: pub.dev registry, published 2026-06-15] | Resolve app-relative storage paths | Only if paths need to be OS-known-folder-based; for Phase 1's "beside the executable" default matching `ecom-py`, prefer `Platform.resolvedExecutable`-relative resolution instead (see Pitfall 8 in prior PITFALLS.md research) — install now, decide default-path strategy during planning |
| `intl` | `0.20.3` [VERIFIED: pub.dev registry, published 2026-06-25] | Date/time formatting for filenames | Needed for `YYYYMMDD_HHMMSS` filename format and `YYYY-MM-DD` folder format matching Python's `strftime` output exactly |
| `flutter_lints` | `6.0.0` [VERIFIED: pub.dev registry, published 2025-05-27] | Standard Dart/Flutter lint rules | Enable in `analysis_options.yaml` from project start (dev dependency) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `camera` + `camera_windows` | `camera_desktop` (community, publisher `hugo.ml`, v1.2.1, 2026-06-13) | Genuine cross-desktop `camera_platform_interface` implementation with more complete Windows recording feature coverage per its own docs; smaller adoption (~3.75k downloads) but more actively updated. **Use as the fallback if the Phase 1 spike shows `camera_windows` fails on real hardware** — drop-in swap at the `pubspec.yaml` level, no app-code rewrite, since both implement the same interface. |
| `camera` + `camera_windows` | Custom FFI Media Foundation plugin | Rejected — same order-of-magnitude effort as the abandoned Qt6/C++ port (see project MEMORY.md); reserve only if both official and `camera_desktop` plugins fail the spike |
| `sqflite_common_ffi` | `drift` | Rejected for Phase 1 — adds a codegen build step and query-DSL translation layer for zero benefit when the existing schema is simple raw SQL that needs byte-for-byte compatibility with `ecom-py`'s `database.db` |

**Installation:**
```bash
flutter pub add camera camera_windows window_manager
flutter pub add sqflite_common_ffi
flutter pub add win32 win32_registry
flutter pub add path path_provider intl
flutter pub add -d flutter_lints
```

**Version verification:** All versions above were re-verified live against the pub.dev API (`https://pub.dev/api/packages/<name>`) on 2026-07-11 and match the prior project-level `STACK.md` research exactly — no drift detected since that research was performed the same day.

## Package Legitimacy Audit

`slopcheck` (v0.6.1, installed successfully) **does not support the Dart/pub.dev ecosystem** — its `--ecosystem` flag only accepts `pypi, npm, crates.io, go, rubygems, maven, packagist`. Automated slop-detection could not be run for these packages. In place of slopcheck, the following manual registry verification was performed for every recommended package via the pub.dev API (`/api/packages/<name>`, `/api/packages/<name>/score`, `/api/packages/<name>/publisher`):

| Package | Registry | Publisher | Likes | Downloads/30d | Pub Score | Disposition |
|---------|----------|-----------|-------|----------------|-----------|--------------|
| `camera` | pub.dev | `flutter.dev` (official) | 2591 | 664,372 | 160/160 | Approved |
| `camera_windows` | pub.dev | `flutter.dev` (official) | 73 | 590 | 160/160 | Approved — low download count reflects Windows-desktop-camera being a niche use case, not a legitimacy concern given official publisher |
| `sqflite_common_ffi` | pub.dev | `tekartik.com` (sqflite author) | 318 | 170,155 | 160/160 | Approved |
| `window_manager` | pub.dev | `leanflutter.dev` | 1117 | 473,581 | 160/160 | Approved |
| `win32` | pub.dev | `halildurmus.dev` (`flutter-favorite`) | 946 | 6,383,941 | 160/160 | Approved |
| `win32_registry` | pub.dev | `halildurmus.dev` | 69 | 3,399,804 | 160/160 | Approved |
| `path_provider` | pub.dev | `flutter.dev` (official, `flutter-favorite`) | 5544 | 6,189,533 | 160/160 | Approved |
| `intl` | pub.dev | `dart.dev` (official, `flutter-favorite`) | 6087 | 7,818,768 | 160/160 | Approved |
| `path` | pub.dev | `dart.dev` (official) | 1732 | 7,049,784 | 160/160 | Approved |
| `flutter_lints` | pub.dev | (Flutter SDK team) | — | — | — | Approved — standard tooling, not runtime dependency |

**Packages removed due to slopcheck [SLOP] verdict:** none (slopcheck could not run against this ecosystem)
**Packages flagged as suspicious [SUS]:** none — all packages verified via official/verified pub.dev publishers with high download counts and full pub scores. `camera_windows` has a notably small download count (590/30d) but this is explained by the narrow niche (Flutter Windows desktop camera apps are uncommon) combined with official `flutter.dev` publisher ownership, which is a stronger legitimacy signal than download volume alone.

**Package name provenance:** All package names above were originally discovered via WebSearch/training knowledge in the prior project-level `STACK.md` research, then independently re-verified in this session via direct pub.dev API calls (an authoritative source). Per the provenance rule, package names remain tagged `[VERIFIED: pub.dev registry]` because the verification was performed against the authoritative registry API directly (not merely `npm view`-style existence checking) and cross-referenced with official publisher identity — this is the strongest verification tier available for the Dart/Flutter ecosystem absent Context7/slopcheck coverage.

*No `checkpoint:human-verify` gating is required for these installs given the strength of the publisher/download evidence, but the planner may still choose to add one as a low-cost safety measure given slopcheck could not run.*

## Architecture Patterns

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      Flutter Desktop App (single process)        │
│                                                                    │
│  [USB Barcode Scanner] ──keystrokes+Enter──▶ HardwareKeyboard     │
│                                              .instance.addHandler │
│                                              (top-level, app root)│
│                                                     │              │
│                                          buffer + debounce         │
│                                          (mirrors barcode_handler) │
│                                                     ▼              │
│                                          BarcodeStateMachine       │
│                                          .process(barcode, isRec) │
│                                          → start | stop_and_start │
│                                            | stop | invalid       │
│                                                     │              │
│         ┌───────────────────────────────────────────┴──────┐      │
│         ▼                                                  ▼      │
│  CameraController                                  Database        │
│  (camera + camera_windows                          (sqflite_      │
│   plugin, Media Foundation                          common_ffi,    │
│   CaptureEngine backend)                            single conn,   │
│    │         │                                       WAL mode)     │
│    │         └─stopVideoRecording()──▶ XFile ───▶ move/rename to   │
│    │                                              videos/YYYY-MM-DD│
│    │                                              /<Label>/....mp4 │
│    │                                                    │          │
│    │                                        INSERT/UPDATE          │
│    │                                        transactions row       │
│    │                                              (id, barcode,    │
│    │                                               video_filename, │
│    │                                               start/end_time, │
│    │                                               duration,       │
│    │                                               file_size_mb,   │
│    │                                               stop_method,    │
│    │                                               label)          │
│    │                                                                │
│    └─buildPreview()──▶ Texture widget ──▶ Flutter UI (Stack:        │
│                                            preview + RECORDING      │
│                                            indicator overlay)       │
│                                                                     │
│  [logs/app.log] ◀── dart:io File.writeAsString(append) ── all of   │
│                      the above on every significant event          │
└─────────────────────────────────────────────────────────────────┘
```

A reader can trace the primary use case (operator scans barcode → video starts/stops → row logged) by following: scanner → HardwareKeyboard handler → BarcodeStateMachine → CameraController (record) + Database (transaction row) → filesystem (video file) + logs/app.log.

### Recommended Project Structure
```
ecom-flutter/
├── lib/
│   ├── main.dart                  # App entry, window_manager setup, HardwareKeyboard handler install
│   ├── core/
│   │   ├── barcode_handler.dart   # Port of ecom-py/barcode_handler.py (validate/process)
│   │   ├── camera_service.dart    # Wraps CameraController: init, start/stop recording, preview
│   │   ├── database.dart          # Port of ecom-py/database.py (raw SQL, schema-identical)
│   │   ├── config.dart            # Minimal settings read (camera index, video path) for Phase 1
│   │   └── file_paths.dart        # videos/YYYY-MM-DD/<Label>/... path construction (path package)
│   ├── ui/
│   │   └── main_screen.dart       # Preview widget, barcode display, Stop button, RECORDING overlay
│   └── models/
│       └── transaction.dart       # Dart class mirroring the transactions row shape
├── test/                          # Unit tests for barcode_handler.dart, file_paths.dart (pure Dart, no hardware)
├── windows/                       # Flutter-generated Windows runner project
└── pubspec.yaml
```

### Pattern 1: Barcode State Machine (direct port)
**What:** A stateless function that takes the raw scanned string and current recording state, returns an action enum (`start`/`stopAndStart`/`stop`/`invalid`).
**When to use:** Every barcode submission, whether from the scanner handler or the manual TextField/Submit button — same code path, per BAR-02.
**Example:**
```dart
// Source: direct Dart port of ecom-py/barcode_handler.py (verified against source file)
enum BarcodeAction { start, stopAndStart, invalid }

class BarcodeHandler {
  String? lastBarcode;

  bool validateBarcode(String? barcode) {
    if (barcode == null) return false;
    final trimmed = barcode.trim();
    return trimmed.isNotEmpty;
  }

  ({BarcodeAction action, String barcode})? processBarcode(
    String barcode, {
    required bool isRecording,
  }) {
    if (!validateBarcode(barcode)) return null; // caller logs 'invalid'

    final normalized = barcode.trim().toUpperCase();
    lastBarcode = normalized;

    return (
      action: isRecording ? BarcodeAction.stopAndStart : BarcodeAction.start,
      barcode: normalized,
    );
  }
}
```

### Pattern 2: Top-level focus-independent keyboard capture with debounce buffer
**What:** A single `HardwareKeyboard.instance.addHandler` installed once at app root (not per-widget), buffering characters and flushing on Enter or on an inter-key timeout — mirroring the scanner's machine-speed keystroke timing.
**When to use:** Required for BAR-01; must work identically whether the main screen, a dialog, or no widget has focus.
**Example:**
```dart
// Source: architecture derived from Flutter official HardwareKeyboard docs
// (https://api.flutter.dev/flutter/services/HardwareKeyboard-class.html) +
// community pattern for barcode-wedge capture; NOT a verified end-to-end
// example from official docs — the back-to-back/focus behavior itself is
// the subject of this phase's hardware spike (see Common Pitfalls).
class GlobalBarcodeListener {
  final _buffer = StringBuffer();
  DateTime? _lastKeyTime;
  static const _interKeyTimeout = Duration(milliseconds: 100);

  void install() {
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    final now = DateTime.now();
    if (_lastKeyTime != null &&
        now.difference(_lastKeyTime!) > _interKeyTimeout) {
      _buffer.clear(); // stale partial scan, reset
    }
    _lastKeyTime = now;

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      final scanned = _buffer.toString();
      _buffer.clear();
      if (scanned.isNotEmpty) _onBarcodeScanned(scanned);
      return true; // consume Enter so it doesn't also submit a focused TextField
    }

    final char = event.character;
    if (char != null && char.isNotEmpty) {
      _buffer.write(char);
    }
    return false; // do NOT consume other keys — let normal typing still work
  }

  void Function(String) _onBarcodeScanned = (_) {};
}
```

### Pattern 3: Schema-compatible SQLite via `sqflite_common_ffi`
**What:** Single long-lived `Database` instance opened once at startup with WAL mode, using raw SQL identical to `ecom-py/database.py`'s schema.
**When to use:** DB-01, DB-02.
**Example:**
```dart
// Source: sqflite_common_ffi official setup pattern (pub.dev package docs)
// + WAL-mode PRAGMA confirmed via community sources (see Sources section)
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openAppDatabase(String dbPath) async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final db = await factory.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode=WAL');
      },
      onCreate: (db, version) async {
        // Schema IDENTICAL to ecom-py/database.py init_database()
        await db.execute('''
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
            compression_status TEXT DEFAULT 'pending',
            compressed_file_size_mb REAL,
            compression_ratio REAL,
            compressed_filename TEXT
          )
        ''');
      },
      version: 1,
    ),
  );

  return db;
}
```
**Important schema note:** `ecom-py/database.py` builds this schema incrementally via `ALTER TABLE ... ADD COLUMN` guarded by `try/except sqlite3.OperationalError` (for backward compatibility with older `database.db` files). The Flutter `onCreate` above bakes the *final* column set into one `CREATE TABLE`, which is correct for a **fresh** database. If Phase 1 testing needs to open an **existing** `ecom-py`-created `database.db` file, `onCreate` will not run (SQLite already has the table) — verify all columns already exist via `PRAGMA table_info(transactions)` instead of assuming, and only run compatibility `ALTER TABLE` statements if a column is actually missing.

### Pattern 4: Video file path construction (STO-01 port)
**What:** Build `videos/YYYY-MM-DD/<LabelFolder>/YYYYMMDD_HHMMSS_BARCODE.mp4` and ensure directories exist.
**Example:**
```dart
// Source: direct port of ecom-py/camera_handler.py start_recording() path logic
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';

String buildVideoPath(String basePath, String barcode, String labelFolder) {
  final now = DateTime.now();
  final dateFolder = DateFormat('yyyy-MM-dd').format(now);
  final timestamp = DateFormat('yyyyMMdd_HHmmss').format(now);

  final folder = p.join(basePath, dateFolder, labelFolder);
  Directory(folder).createSync(recursive: true);

  final filename = '${timestamp}_$barcode.mp4';
  return p.join(folder, filename);
}
```
Phase 1 only needs the `Normal` label folder (label routing is Phase 2's REC-06); still use the same folder-mapping approach so Phase 2 doesn't need to touch this function's shape, only add more label cases.

### Anti-Patterns to Avoid
- **Per-call `openDatabase()`/new connections:** DB-02 explicitly requires one long-lived connection — open once at app startup, pass the `Database` instance down, never re-open per query (this mirrors moving *away* from `ecom-py/database.py`'s current per-call `sqlite3.connect()` pattern, which the roadmap intentionally improves on).
- **Focused-`TextField`-as-scanner-catcher:** A common web-world trick (put invisible focused input, catch scanner keystrokes there) is fragile the moment a dialog opens or focus moves — do not use this pattern; use the top-level `HardwareKeyboard` handler instead (Pattern 2).
- **Assuming `stopVideoRecording()` → `startVideoRecording()` has zero latency:** No official source confirms this. Do not architect the UI (e.g., "immediately show new recording as active") without first measuring the actual gap in milliseconds on real hardware.
- **Building UI atop `camera_windows` before validating recording works:** The roadmap's own explicit instruction is to validate the camera pipeline as "the literal first work item," before any UI is built around a specific plugin choice.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|--------------|-----|
| Camera capture + MP4 encoding on Windows | A custom Media Foundation `IMFCaptureEngine` FFI bridge | `camera` + `camera_windows` (or `camera_desktop` fallback) | This is exactly the class of native-code complexity that made the prior Qt6/C++ port too slow to develop (per project MEMORY.md) — the official plugin already implements this correctly for the common case |
| SQLite access on Windows desktop | Hand-rolled FFI bindings to `sqlite3.dll` | `sqflite_common_ffi` | Already solves DLL bundling (via build_hooks for `sqlite3` package v3.0.0+), isolate-backed async access, and the standard `sqflite` Database API that most Flutter devs already know |
| Window minimum-size enforcement | Manual `WM_GETMINMAXINFO` Win32 message handling | `window_manager` | Purpose-built, actively maintained package exposing `setMinimumSize()` directly from Dart |
| Date/time formatting for filenames | Manual string interpolation of `DateTime` fields | `intl`'s `DateFormat` | Avoids off-by-one/padding bugs (e.g., forgetting to zero-pad single-digit hours) that a hand-rolled formatter is prone to |

**Key insight:** Every "don't hand-roll" item above maps to a specific historical failure mode already documented in this project's own history (the abandoned C++ port) or a well-known class of bug (manual date padding, manual FFI). The pattern across this whole project: reach for the maintained plugin/package first, and only build custom FFI as a last resort after the plugin demonstrably fails on real hardware.

## Common Pitfalls

### Pitfall 1: `stopVideoRecording()` → `startVideoRecording()` back-to-back reliability is undocumented
**What goes wrong:** The core workflow (REC-02) requires stopping the current recording and immediately starting a new one, back-to-back, potentially dozens of times per operator shift. Neither the official `camera` package docs nor `camera_windows`'s changelog documents a minimum safe interval between `stopVideoRecording()` completing and the next `startVideoRecording()` call, nor guarantees zero frame loss across the transition. [CITED: pub.dev/documentation/camera/latest — "stopVideoRecording() stops the video recording and returns the file where it was saved" is the entirety of the documented contract]
**Why it happens:** `camera_windows` is explicitly still described as "under development" by its own maintainers; Windows desktop support has a far smaller contributor base and hardware test matrix than the mobile implementations, and rapid stop-start cycling is not a typical mobile-camera-app usage pattern (most camera apps record one video at a time, then the user manually reviews/shares before recording again).
**How to avoid:** This phase's #1 deliverable is empirically answering this question. Build the minimal record/stop/record-again loop first, on real target hardware, and run it dozens of times in immediate succession, checking: (a) does `stopVideoRecording()` reliably return before the app attempts the next `startVideoRecording()`; (b) is there any measurable gap where frames are lost; (c) do output files play correctly and have plausible durations; (d) does any run throw a `PlatformException`. If failures occur, evaluate `camera_desktop` as a same-interface swap before considering custom FFI.
**Warning signs:** `PlatformException` during `startVideoRecording()` shortly after a `stopVideoRecording()` call; video files with 0-byte size or corrupted headers; noticeably short/long durations vs. wall-clock time between scans.
**Phase to address:** Phase 1 — this is the phase's entire reason for existing.

### Pitfall 2: `HardwareKeyboard.instance.addHandler` focus-independence is contested, not confirmed
**What goes wrong:** Official Flutter API docs for `HardwareKeyboard.addHandler` describe it as receiving "every hardware key event" with handlers "invoked in order regardless of ... focus" language implying app-wide, focus-independent delivery [CITED: api.flutter.dev/flutter/services/HardwareKeyboard-class.html]. However, a currently-tracked GitHub issue (#160786, labeled P2/Important, with reproducible steps) reports the handler **stops firing after a TextField has been focused/edited**, specifically on Flutter 3.27.1 and 3.28, described as a regression from 3.24.5 [CITED: github.com/flutter/flutter/issues/160786]. The project's installed Flutter is 3.41.6 — later than both the "working" (3.24.5) and "broken" (3.27+) versions cited in the issue, and the issue's resolution status on 3.41.6 was not confirmed in this research session (the issue thread does not state a fix version).
**Why it happens:** Flutter's focus-scoped key event architecture (a deliberate design for normal UI correctness, replacing the deprecated `RawKeyboard` system) fundamentally conflicts with "global hotkey"-style needs like a keyboard-wedge scanner that must work regardless of what has focus — this is a known architectural tension, not a simple bug, and multiple open issues (#154141, #96333, #79849) confirm ongoing community friction with this exact use case.
**How to avoid:** Do not assume either "it definitely works" or "it's definitely broken" — test directly on the installed Flutter 3.41.6 with the actual target USB scanner hardware, specifically: (1) scan while the main screen has no focused widget, (2) scan while a `TextField` is focused (e.g., the manual barcode entry field), (3) scan while a modal dialog is open. If the regression from #160786 is still present on 3.41.6, the fallback is a `Focus` widget wrapping the entire app root with `autofocus: true` and `onKeyEvent`, forcing the whole app to hold logical focus, combined with `FocusScope.of(context).requestFocus()` calls after any dialog closes to reclaim focus — a workaround, not a fix, that needs the same hardware verification.
**Warning signs:** Scans work when the app just launched (nothing focused yet) but silently stop working after the user clicks into any `TextField`; partial barcodes (missing leading or trailing characters) after a focus transition.
**Phase to address:** Phase 1 (this phase includes BAR-01 in scope) — do not defer this verification to Phase 2 just because full barcode-input polish is nominally a Phase 2 concern; Phase 1's success criteria explicitly require scanning "while idle" and "while recording," both of which depend on this mechanism working.

### Pitfall 3: `availableCameras()` enumeration gaps on Windows
**What goes wrong:** A long-standing open Flutter issue (#98404, filed 2022, still open with no recent activity per prior project research) reports `availableCameras()` sometimes misses cameras that Windows itself lists via Device Manager, particularly virtual cameras and some USB webcam models. [CITED: github.com/flutter/flutter/issues/98404, verified still open as of prior same-day project research]
**How to avoid:** During the Phase 1 spike, explicitly test `availableCameras()` against the actual target webcam model(s) used at packing stations and confirm the returned list/names are usable. If a target camera is missing, the fallback (documented in prior `STACK.md` research) is `win32`/`win32_registry` DirectShow registry enumeration purely for the friendly-name picker, mapped back to a `CameraDescription` by device path.
**Warning signs:** Fewer cameras returned by `availableCameras()` than Windows Device Manager shows for the same machine.
**Phase to address:** Phase 1 (SET-01 requires human-readable camera selection, which depends on correct enumeration).

### Pitfall 4: Codec/container output from Media Foundation may not match what later FFmpeg compression (Phase 3) expects
**What goes wrong:** `camera_windows`'s Media Foundation `CaptureEngine` picks its own encoder/container settings, which may differ from what `ecom-py`'s OpenCV-based `cv2.VideoWriter` produces, potentially causing FFmpeg compression (Phase 3) to behave differently against Flutter-captured input than it does against Python-captured input.
**How to avoid:** Not a Phase 1 blocker (compression is Phase 3 scope), but Phase 1 should run `ffprobe` against a sample Flutter-captured video and record the codec/profile/container found, so Phase 3 planning has this data point ready rather than discovering it cold.
**Warning signs:** N/A for Phase 1 pass/fail — this is a forward-looking data-gathering step, not a Phase 1 blocking issue.
**Phase to address:** Data gathered in Phase 1, consumed by Phase 3 planning.

### Pitfall 5: sqlite3.dll must ship beside the release .exe, not just work in `flutter run`
**What goes wrong:** `sqflite_common_ffi`'s underlying `sqlite3` package resolves and can auto-bundle `sqlite3.dll` via build_hooks for v3.0.0+, but debug (`flutter run`) and release (`flutter build windows`) builds can behave differently — a database that opens fine under `flutter run` can fail to open from a freshly-built release folder if the DLL isn't actually present in the output. [CITED: pub.dev/packages/sqflite_common_ffi; corroborated by prior project PITFALLS.md research citing tekartik/sqflite#574]
**How to avoid:** Verify the resolved `sqlite3` transitive dependency version in `pubspec.lock` is v3.0.0+ after `flutter pub get`. Add a release-build smoke test to the Phase 1 verification checklist: run `flutter build windows`, then launch the built `.exe` directly from `build/windows/x64/runner/Release/` (not via `flutter run`) and confirm the database opens and a transaction can be written.
**Warning signs:** Database operations throw "unable to open database file" or similar only in the release build, never in debug.
**Phase to address:** Phase 1 (must be part of this phase's own verification, since DB-01/DB-02 are in scope here).

## Code Examples

See Architecture Patterns section above (Patterns 1-4) for the primary code examples: barcode state machine, global keyboard listener, SQLite schema setup, and video path construction. These are architectural sketches based on documented APIs, not copy-pasted from a single verified working example — the planner should treat them as a starting point to implement and then validate against real hardware, per this phase's explicit purpose.

### Reading the exact reference schema (for verification during implementation)
```python
# Source: ecom-py/database.py init_database(), read directly from this session
# The Flutter schema in Pattern 3 above matches this exactly, including
# the incrementally-added columns (label, compression_status,
# compressed_file_size_mb, compression_ratio, compressed_filename)
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
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    -- + ALTER TABLE-added: compression_status, compressed_file_size_mb,
    --   compression_ratio, compressed_filename (see database.py lines 49-63)
)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|-------------------|---------------|--------|
| `RawKeyboard`/`RawKeyboardListener` for key events | `HardwareKeyboard`/`KeyEvent`/`Focus.onKeyEvent` | Flutter migration documented at docs.flutter.dev/release/breaking-changes/key-event-migration | The old API is deprecated/being removed; all new Flutter code (including this project) must use the new focus-scoped model, which is precisely the source of Pitfall 2 above — there is no "go back to the old simpler API" escape hatch |
| DirectShow-based Windows camera capture | Media Foundation `CaptureEngine` | Microsoft's own current guidance (learn.microsoft.com/windows/win32/medfound) | `camera_windows`/`camera_desktop` both use Media Foundation; DirectShow is legacy and should only be touched for narrow registry-based friendly-name enumeration fallback, not capture itself |

**Deprecated/outdated:**
- `RawKeyboard`/`RawKeyEvent`: superseded by `HardwareKeyboard`/`KeyEvent`; do not write new code against the old API even though older StackOverflow/tutorial content may still reference it.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `HardwareKeyboard.instance.addHandler` will behave correctly (focus-independent) on the project's installed Flutter 3.41.6, given issue #160786 was reported against 3.27/3.28 and not confirmed fixed or reproduced on later versions | Common Pitfalls, Pitfall 2 | If wrong, BAR-01 fails outright on the primary planned mechanism, requiring the `Focus`-wrapping workaround or an alternative global-hotkey package before Phase 1 can be considered complete |
| A2 | `stopVideoRecording()` followed immediately by `startVideoRecording()` has acceptably low latency and does not drop frames | Common Pitfalls, Pitfall 1; Summary | If wrong, the core continuous-scan workflow (REC-02, the project's stated "Core Value") is not achievable with `camera_windows` and requires either `camera_desktop` or custom FFI — a major scope/timeline change for the whole project, not just Phase 1 |
| A3 | `camera_windows`'s `availableCameras()` will correctly enumerate the specific webcam model(s) used at the target packing stations | Common Pitfalls, Pitfall 3 | If wrong, SET-01 (camera selection by name) needs the `win32`/DirectShow registry fallback layer built in Phase 1 rather than deferred |
| A4 | The exact webcam model(s) and USB barcode scanner model(s) used at target packing stations are not yet identified in any planning document read during this research | (implicit throughout) | Without knowing the specific hardware models, the Phase 1 spike cannot be scheduled/scoped precisely — the planner should confirm hardware availability/specifics as an early Phase 1 task, not assume "any webcam" is equivalent for validation purposes |

**If this table is empty:** N/A — table is populated; the two highest-priority assumptions (A1, A2) are exactly the two things this phase's success criteria require the team to empirically resolve, which is by design given this is a spike phase.

## Open Questions

1. **What specific webcam and barcode scanner hardware models will be used for the Windows validation spike?**
   - What we know: A Windows 10/11 machine is available for builds/hardware testing (per project memory); the Python reference app uses OpenCV's MSMF backend and supports arbitrary USB webcams generically.
   - What's unclear: No specific hardware model (webcam brand/model, scanner brand/model) is named anywhere in `PROJECT.md`, `ROADMAP.md`, `REQUIREMENTS.md`, or `STATE.md` read during this research.
   - Recommendation: Planner should add a Phase 1 task to confirm/procure the exact hardware before the spike tasks are scheduled — testing against "whatever webcam happens to be plugged into the Windows machine" is a legitimate first pass, but the roadmap's own language ("validated against real target webcam hardware") implies a specific target device matters.

2. **Is issue #160786 (HardwareKeyboard stops firing after TextField focus) present on Flutter 3.41.6?**
   - What we know: Reported against 3.27.1/3.28 as a regression from 3.24.5; the project's installed version (3.41.6) is considerably later and the issue thread does not confirm a fix version.
   - What's unclear: Whether the underlying regression was fixed somewhere between 3.28 and 3.41.6, is still present, or has changed shape.
   - Recommendation: First concrete Phase 1 task — write a minimal test harness (a bare Flutter Windows app with one `TextField` and a `HardwareKeyboard` handler logging every event) and manually verify on the actual dev/Windows machine before investing in the full barcode-buffer logic.

3. **What is the actual latency/frame-loss profile of `stopVideoRecording()` → `startVideoRecording()`?**
   - What we know: The `camera` package documents the method signatures and return types; no source documents timing or reliability across rapid cycles.
   - What's unclear: Whether there's a safe minimum delay, and whether any delay is even necessary.
   - Recommendation: Build the minimal record/stop/record loop as literally the first working code in this phase, instrument it with timestamps and frame counts, and run it dozens of times before building any surrounding UI — exactly as the roadmap already directs ("literal first work item").

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Flutter SDK | All Dart/Flutter code | ✓ (Linux dev machine) | 3.41.6 stable, Dart 3.11.4 | — |
| Windows 10/11 target machine | Hardware camera/scanner spike, `flutter build windows`, release-build DLL verification | ✓ (separate machine, per project memory) | Not directly probed from this session (Linux sandbox) | — |
| FFmpeg | Not required for Phase 1 scope (compression is Phase 3); available for reference/tooling only | ✓ (Linux dev machine) | 6.1.1-3ubuntu5 | — |
| USB webcam (specific target model) | Camera capture spike (CAM-01 through CAM-03) | Unconfirmed — no specific model identified in planning docs | — | Test with any available webcam first if target model unavailable, but flag results as provisional (see Open Question 1) |
| USB keyboard-wedge barcode scanner (specific target model) | BAR-01 spike | Unconfirmed — no specific model identified in planning docs | — | Manual keystroke-timing simulation is explicitly insufficient per prior PITFALLS.md research ("works during manual testing but fails with the real scanner hardware") — real hardware is not optional for BAR-01 verification |
| `slopcheck` (pip package) | Package legitimacy audit | ✓ (installed this session) | 0.6.1 | Does not support pub.dev/Dart ecosystem — manual pub.dev API verification used instead (see Package Legitimacy Audit) |

**Missing dependencies with no fallback:**
- Specific target webcam and barcode scanner hardware models — the planner should treat sourcing/confirming this hardware as a Phase 1 prerequisite task, since "validated against real target webcam hardware" (roadmap success criterion) cannot be claimed true against arbitrary substitute hardware.

**Missing dependencies with fallback:**
- `slopcheck` Dart/pub.dev coverage — manual pub.dev API + publisher verification substituted successfully (see Package Legitimacy Audit table above).

## Assumptions Log Cross-Reference

The Environment Availability gaps above (specific hardware models unconfirmed) compound Assumption A4 in the Assumptions Log — the planner should treat hardware confirmation as blocking for the spike-verification tasks, not the architecture/setup tasks (which can proceed on Linux with any available Flutter Windows target for compilation checking, even without hardware access).

## Sources

### Primary (HIGH confidence)
- pub.dev API (`https://pub.dev/api/packages/<name>`, `.../score`, `.../publisher`) — live version, publish date, publisher identity, download counts for `camera`, `camera_windows`, `sqflite_common_ffi`, `window_manager`, `win32`, `win32_registry`, `path_provider`, `intl`, `path`, `flutter_lints` — fetched directly this session, 2026-07-11
- `ecom-py/database.py`, `ecom-py/camera_handler.py`, `ecom-py/barcode_handler.py`, `ecom-py/config.py`, `ecom-py/settings_manager.py`, `ecom-py/camera_utils.py` — read directly this session, the authoritative behavior reference for this port
- `https://api.flutter.dev/flutter/services/HardwareKeyboard-class.html` — official Flutter API docs
- `.planning/research/STACK.md`, `.planning/research/PITFALLS.md` — prior same-project research (2026-07-11), independently re-verified in this session (all package versions confirmed unchanged)
- `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, `.planning/STATE.md` — project's own source of truth, read directly this session
- Local shell: `flutter --version` (3.41.6), `ffmpeg -version` (6.1.1), `pip install slopcheck` (0.6.1, ecosystem coverage confirmed via `slopcheck install --help`) — verified directly in this session

### Secondary (MEDIUM confidence)
- `https://github.com/flutter/flutter/issues/160786` — HardwareKeyboard regression after TextField focus, open issue with reproducible steps, no confirmed fix version
- `https://pub.dev/documentation/camera/latest/camera/CameraController-class.html` — `CameraController` method signatures (`startVideoRecording`, `stopVideoRecording` returns `XFile`), but explicitly does not document back-to-back reliability
- `https://github.com/flutter/flutter/issues/98404` — `availableCameras()` enumeration gaps, long-open, no recent activity (cited in prior project research, not independently re-fetched this session)

### Tertiary (LOW confidence)
- WebSearch summaries of community blog posts on `sqflite_common_ffi` WAL mode setup (`db.setJournalMode('WAL')` in sqflite_common 2.5.6+, or `PRAGMA journal_mode=WAL` fallback) — not verified against an official tekartik/sqflite doc page directly (the GitHub doc URL attempted returned 404); treat the exact API name (`setJournalMode` vs. raw `PRAGMA execute`) as needing confirmation during implementation, though the underlying WAL-via-PRAGMA mechanism is well-established SQLite behavior independent of the wrapper.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every package version independently re-verified against the live pub.dev registry API this session, publisher identities confirmed, matches prior same-day project research with zero drift
- Architecture: MEDIUM — the overall shape (plugin-based camera, raw-SQL SQLite, top-level keyboard handler) is well-supported, but two load-bearing mechanisms (stop/start recording latency, keyboard focus-independence) are unresolved in any available documentation and are explicitly what this phase must determine empirically
- Pitfalls: MEDIUM-HIGH — pitfalls are well-documented with specific GitHub issue numbers and version ranges, but several (Pitfall 1, Pitfall 2) describe genuinely open/unresolved upstream questions rather than settled facts with a known workaround

**Research date:** 2026-07-11
**Valid until:** 7 days (fast-moving: this phase's core findings depend on Flutter/plugin versions and open GitHub issues that could change status at any time; re-verify pub.dev versions and issue statuses if planning is delayed beyond a week)
