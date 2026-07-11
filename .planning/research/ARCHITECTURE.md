# Architecture Research

**Domain:** Flutter Windows desktop app — real-time webcam capture + barcode-triggered recording + SQLite log + FFmpeg post-processing
**Researched:** 2026-07-11
**Confidence:** MEDIUM-HIGH (component boundaries, state management, and data flow are HIGH confidence — standard Flutter desktop patterns; the camera/recording plugin choice is MEDIUM confidence and flagged for dedicated phase-1 research/spike, since Flutter's Windows camera story is thin and this is exactly the risk the PROJECT.md already calls out)

## Standard Architecture

### System Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Presentation (Flutter UI)                     │
│  MainScreen (preview + barcode field + recent list)                   │
│  SearchDialog | SettingsDialog | SavingProgressDialog                 │
│  — all widgets, single Window (window_manager for size/title only)    │
├───────────────────────────┬─────────────────────────────────────────┤
│                            │  watch / read                            │
│                            ▼                                          │
│                    State Layer (Riverpod)                             │
│  recordingSessionProvider  cameraPreviewProvider  settingsProvider    │
│  recentTransactionsProvider  compressionQueueProvider                 │
├───────────────────────────┬─────────────────────────────────────────┤
│                            │  calls methods on                        │
│                            ▼                                          │
│                    Service Layer (plain Dart classes)                 │
│  RecordingOrchestrator  (single source of truth — the ONE thing       │
│                           both barcode-scan and manual-stop call)     │
│      ├─ CameraService      (capture + preview + record, isolate/FFI)  │
│      ├─ BarcodeService     (pure function: action decision)           │
│      ├─ DatabaseService    (sqlite3 FFI, one connection, WAL)         │
│      ├─ SettingsService    (JSON file, ChangeNotifier/Riverpod state) │
│      └─ CompressionService (Process.start ffmpeg.exe, worker queue)   │
├───────────────────────────┬─────────────────────────────────────────┤
│                            ▼                                          │
│              Filesystem / OS Resources                                │
│  videos/YYYY-MM-DD/<Label>/*.mp4, database.db (WAL),                  │
│  settings.json, logs/app.log, Windows Media Foundation camera,        │
│  bundled ffmpeg.exe subprocess                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| UI widgets | Render preview texture, forms, dialogs; dispatch user intents | `StatelessWidget`/`ConsumerWidget`, no business logic, no direct service calls |
| Riverpod providers | Expose service state to widgets reactively; own no I/O themselves | `NotifierProvider`/`AsyncNotifierProvider` wrapping a service; `Provider` for stateless service singletons |
| `RecordingOrchestrator` | The single barcode-scan → recording-lifecycle → DB → compression pipeline | Plain Dart class, holds current-session state (`currentTransactionId`, `isRecording`), calls into `CameraService`/`DatabaseService`/`CompressionService` in sequence |
| `CameraService` | Owns camera lifecycle: open device, deliver preview frames to a `Texture`, start/stop file recording | FFI binding to a small native capture module (mirrors `camera_handler.py`), OR `camera_windows`/`camera_desktop` plugin — see Anti-Patterns/Integration Points for the tradeoff |
| `BarcodeService` | Pure decision function: given barcode + current recording state → `start`/`stopAndStart`/`stop`/`invalid` | Stateless Dart class/function, fully unit-testable, no I/O |
| `DatabaseService` | All SQLite reads/writes for the transactions table | `sqlite3` (Dart FFI package) with one long-lived connection, WAL mode, prepared statements |
| `SettingsService` | Load/save `settings.json`, expose typed getters, notify listeners on change | Dart class over `dart:io` File + `dart:convert` JSON, deep-merge with defaults, backed by a `Notifier` provider so UI reacts to live changes |
| `CompressionService` | Queue finished recordings, run FFmpeg as a subprocess, report completion | `dart:io Process.start()` + a Dart `Queue`/async worker loop running in a spawned `Isolate` (mirrors the Python daemon thread) |
| Global barcode scanner listener | Capture keyboard-wedge input app-wide regardless of focused widget | `HardwareKeyboard`/`RawKeyboard` global handler feeding into a debounced "scan buffer" that resolves to `BarcodeService` |

## Recommended Project Structure

```
ecom-flutter/
├── lib/
│   ├── main.dart                    # ProviderScope, window setup, DI wiring
│   ├── app.dart                     # MaterialApp, theme, root route
│   ├── core/
│   │   ├── config.dart              # runtime paths (mirrors config.py), exe-relative path resolution
│   │   ├── logging.dart             # package:logging setup, file + console sink
│   │   └── result.dart              # Result/Either-style error wrapper (optional but recommended)
│   ├── models/
│   │   ├── transaction.dart         # freezed/plain data class mirroring `transactions` table row
│   │   ├── settings.dart            # typed settings model (video/camera/compression/storage/app)
│   │   └── recording_state.dart     # enum + value class: idle/recording/saving
│   ├── services/
│   │   ├── camera/
│   │   │   ├── camera_service.dart          # abstract interface
│   │   │   ├── camera_service_ffi.dart      # FFI-backed impl (if custom capture module)
│   │   │   └── camera_service_plugin.dart   # camera_windows/camera_desktop-backed impl (if plugin route)
│   │   ├── barcode_service.dart     # pure state machine, no I/O
│   │   ├── database_service.dart    # sqlite3 FFI wrapper, schema, CRUD, search
│   │   ├── settings_service.dart    # JSON persistence + defaults + deep merge
│   │   ├── compression_service.dart # ffmpeg Process.start queue worker (isolate)
│   │   └── recording_orchestrator.dart  # THE shared session controller (barcode→record→DB→compress)
│   ├── providers/
│   │   ├── service_providers.dart   # Provider<CameraService>, Provider<DatabaseService>, etc.
│   │   ├── recording_providers.dart # NotifierProvider<RecordingSessionState>
│   │   ├── settings_providers.dart  # AsyncNotifierProvider<Settings>
│   │   └── recent_transactions_provider.dart
│   └── ui/
│       ├── main_screen.dart
│       ├── widgets/                 # camera_preview.dart, barcode_input.dart, recording_indicator.dart
│       ├── search/                  # search_dialog.dart, search_filters.dart, result_card.dart
│       ├── settings/                # settings_dialog.dart, tabs/ (video, camera, compression, storage, app)
│       └── dialogs/                 # saving_progress_dialog.dart
├── native/                          # ONLY if FFI capture route is chosen (see Integration Points)
│   └── capture/                     # small C++ Media Foundation/OpenCV capture DLL + Dart FFI bindings
├── windows/                         # Flutter-generated Windows runner project
└── test/
    ├── services/                    # barcode_service_test.dart, database_service_test.dart (pure logic first)
    └── widgets/
```

### Structure Rationale

- **`services/` holds all I/O and business logic; `ui/` holds zero business logic.** This directly fixes the reference app's #1 architectural flaw (duplicated orchestration between Flask and Tkinter) by making it structurally impossible to re-implement the barcode→record→DB→compress pipeline a second time — there is only one `RecordingOrchestrator`, and the single Flutter UI is its only caller.
- **`recording_orchestrator.dart` is a first-class file, not a method bag on a widget.** In the Python app this logic was smeared across `app_gui.py` (`process_barcode`, `_stop_recording_with_progress`) and `app.py`. Promoting it to a standalone, widget-free class makes it unit-testable without a running UI or camera.
- **`camera/` is split into an abstract interface + swappable implementation** because the camera/recording plugin choice is the single biggest open risk in this project (per PROJECT.md) and is likely to require a phase-1 spike deciding between an FFI-based custom capture module (closest to the proven Python/OpenCV approach) and a Flutter camera plugin (`camera_windows` or `camera_desktop`). Isolating it behind an interface means the decision doesn't ripple through the orchestrator or UI.
- **`native/` only exists if the FFI route wins the spike.** Do not scaffold it speculatively — the phase-1 research/spike should resolve this before any UI work depends on a concrete `CameraService`.
- **`providers/` is a thin reactive layer over `services/`**, not a place for logic — Riverpod's job here is only "notify widgets when session/settings/recent-list state changes," matching how the Python app polls (`update_camera_feed` via `after()`) but in a push/reactive style instead of a poll loop.

## Architectural Patterns

### Pattern 1: Single Orchestrator, One Presentation Layer

**What:** All recording-lifecycle business logic (barcode decision → start/stop camera → create/complete DB transaction → enqueue compression → resume next recording) lives in exactly one class, `RecordingOrchestrator`, called by exactly one presentation layer (the Flutter desktop UI).
**When to use:** Always, for this project — it directly targets the reference app's worst anti-pattern (duplicated orchestration between `app.py` and `app_gui.py`, per `.planning/codebase/ARCHITECTURE.md` and `CONCERNS.md`).
**Trade-offs:** No web UI is possible without adding a second caller of the orchestrator later — but that's explicitly out of scope for this port (PROJECT.md: "Web interface... remains available in ecom-py"). If a web UI is ever added in Flutter (e.g., via `shelf`), it becomes a second thin caller of the same orchestrator, not a second implementation.

**Example:**
```dart
class RecordingOrchestrator {
  RecordingOrchestrator(this._camera, this._db, this._compressor, this._barcode);

  final CameraService _camera;
  final DatabaseService _db;
  final CompressionService _compressor;
  final BarcodeService _barcode;

  int? _currentTransactionId;

  Future<RecordingAction> handleBarcodeScan(String barcode) async {
    final action = _barcode.decide(barcode, isRecording: _camera.isRecording);
    switch (action) {
      case BarcodeAction.start:
        await _camera.startRecording(barcode);
        _currentTransactionId = await _db.createTransaction(barcode);
        break;
      case BarcodeAction.stopAndStart:
        await _finishCurrentRecording();
        await _camera.startRecording(barcode);
        _currentTransactionId = await _db.createTransaction(barcode);
        break;
      case BarcodeAction.stop:
        await _finishCurrentRecording();
        break;
      case BarcodeAction.invalid:
        break;
    }
    return action;
  }

  Future<void> _finishCurrentRecording() async {
    final result = await _camera.stopRecording();
    await _db.completeTransaction(_currentTransactionId!, result);
    _compressor.enqueue(result.filePath, _currentTransactionId!);
    _currentTransactionId = null;
  }
}
```

### Pattern 2: Isolate-Bounded Worker for FFmpeg (mirrors Python's daemon thread + queue)

**What:** Run the compression queue's blocking work (spawning `ffmpeg.exe`, waiting on it) inside a dedicated long-lived `Isolate` (or, more simply, rely on `dart:io Process` being non-blocking by nature — `Process.start` is already async and doesn't need a full isolate unless CPU-bound Dart-side work is added). Communicate queue depth/completion back to the UI isolate via a `SendPort`/`ReceivePort` or, more idiomatically, expose an async `Stream<CompressionEvent>` that a Riverpod provider listens to.
**When to use:** Compression queue worker, camera frame polling if a custom FFI capture module is used (frame delivery from native code should not block the UI isolate).
**Trade-offs:** `Process.start()` on its own does not block the Dart event loop (it's I/O, not CPU) — a full isolate is only strictly necessary if there's local Dart-side CPU work (e.g., frame-buffer manipulation for a custom capture path). Don't over-isolate: for the FFmpeg queue alone, an async worker loop over a `Queue` in the main isolate (same pattern as `video_compressor.py`'s `queue.Queue` + thread, just async instead of threaded) is simpler and sufficient. Reserve isolates for the camera frame pipeline if FFI capture is chosen.

**Example:**
```dart
class CompressionService {
  final _queue = Queue<CompressionJob>();
  bool _workerRunning = false;
  final _events = StreamController<CompressionEvent>.broadcast();
  Stream<CompressionEvent> get events => _events.stream;

  void enqueue(String videoPath, int transactionId) {
    _queue.add(CompressionJob(videoPath, transactionId));
    if (!_workerRunning) _runWorker();
  }

  Future<void> _runWorker() async {
    _workerRunning = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      final process = await Process.start(ffmpegPath, buildArgs(job), mode: ProcessStartMode.normal);
      final exitCode = await process.exitCode; // non-blocking await, event loop free
      _events.add(CompressionEvent(job.transactionId, exitCode == 0));
    }
    _workerRunning = false;
  }
}
```

### Pattern 3: Repository/Service Singletons via Riverpod `Provider`, Reactive State via `Notifier`

**What:** Stateless or single-instance services (`DatabaseService`, `SettingsService`, `CameraService`, `CompressionService`, `RecordingOrchestrator`) are exposed as plain `Provider`s (constructed once, live for app lifetime). Anything the UI needs to *react* to (recording status, recent transactions list, live settings, compression queue depth) is exposed via `NotifierProvider`/`AsyncNotifierProvider` that wraps calls to the underlying service.
**When to use:** This is the standard Riverpod app-architecture shape (controller-service-repository) and fits a single-window desktop app well — no need for feature-based DI modules or GetIt at this scale.
**Trade-offs:** `StateNotifier` is legacy as of Riverpod 2.x; use `Notifier`/`AsyncNotifier` (Riverpod 2.0+ codegen or manual) instead. Keep providers thin — if a provider method grows business logic instead of delegating to a service, that's a sign logic is leaking out of `services/`.

## Data Flow

### Primary Flow: Barcode Scan → Recording Lifecycle → DB → Compression

```
[USB scanner keystrokes + Enter]
    ↓
Global keyboard listener (HardwareKeyboard) → assembles scan buffer
    ↓
recordingSessionProvider.scan(barcode)  — Riverpod Notifier method
    ↓
RecordingOrchestrator.handleBarcodeScan(barcode)
    ↓
BarcodeService.decide(barcode, isRecording) → {start | stopAndStart | stop | invalid}
    ↓                                              ↓
CameraService.startRecording(barcode)      CameraService.stopRecording()
    ↓ (opens writer, begins frame drain)          ↓ (flushes buffer, closes writer, returns duration+size)
DatabaseService.createTransaction(barcode)  DatabaseService.completeTransaction(id, result)
    ↓                                              ↓
recentTransactionsProvider invalidated      CompressionService.enqueue(path, id)
    ↓                                              ↓
UI: recording indicator ON, recent list     CompressionService worker (async loop) →
    refreshes                                  Process.start(ffmpeg.exe) → exitCode
                                                    ↓
                                             DatabaseService.updateCompressionStatus(id, result)
                                                    ↓
                                             compressionQueueProvider / recentTransactionsProvider
                                             invalidated → UI reflects compressed status
```

### State Management

```
Riverpod ProviderScope (app root)
    ↓ (widgets `ref.watch(...)`)
recordingSessionProvider ──┐
cameraPreviewProvider ─────┤→ services/ (single instances, constructed in service_providers.dart)
settingsProvider ──────────┤
recentTransactionsProvider ┤
compressionQueueProvider ──┘
    ↓ (services call into)
CameraService / DatabaseService / SettingsService / CompressionService
    ↓
OS resources (camera device, SQLite file, JSON file, ffmpeg.exe)
```

No global mutable variables anywhere in this design — every piece of session state (`isRecording`, `currentTransactionId`, live settings) lives inside exactly one owning class instance (`RecordingOrchestrator`/`CameraService`/`SettingsService`), constructed once at app startup and provided via Riverpod. This directly replaces the reference app's `current_transaction_id` global (`app.py`) and the "two independent `CameraHandler`/`Database` instances" problem (Flask vs. Tkinter) — in Flutter there is only one process, one UI, one set of service singletons, so the entire class of "dual un-synchronized instance" bugs documented in `CONCERNS.md` cannot occur by construction.

### Key Data Flows

1. **Camera preview flow (continuous, independent of recording):** Native camera source → frame delivered to a Flutter `Texture` (via platform view/texture registration, whichever camera integration is chosen) → `cameraPreviewProvider` only tracks *status* (connected/disconnected/error), not raw frames — the texture updates are handled by the platform layer directly for performance, matching the Python app's separation of `latest_frame` (always updating) from `frame_buffer` (only fills while recording).
2. **Recording flow:** See primary flow above — barcode scan is the only entry point (plus a manual "Stop" button in Settings/toolbar, which calls the same `RecordingOrchestrator._finishCurrentRecording` path, never a separate implementation).
3. **Compression flow:** Fire-and-forget from the orchestrator's perspective — `CompressionService.enqueue()` returns immediately; the UI observes progress via `compressionQueueProvider` listening to `CompressionService.events`. Compression failure (missing ffmpeg, non-zero exit) surfaces as a persistent banner/status rather than silently skipping (fixes a flagged reference-app gap: "FFmpeg missing" is currently a silent skip in `ecom-py`).
4. **Settings flow:** `SettingsDialog` writes through `settingsProvider` → `SettingsService.save()` (JSON file) → `SettingsService` notifies its `Notifier` → every dependent provider (camera resolution, compression codec, storage path) rebuilds. Because there's exactly one process, there is no cross-process settings staleness problem the Python app has (Flask process vs. Tkinter process each caching `config.py` independently).
5. **Search flow:** `SearchDialog` reads via `DatabaseService.search(filters)` directly (a one-shot query, no need for a long-lived provider) — return results as a `Future<List<Transaction>>` consumed by a `FutureProvider.family` or `AsyncNotifier`.

## Scaling Considerations

This is a single-user kiosk desktop app, not a multi-tenant service — "scaling" here means longevity/robustness of a long-running unattended process, not user count.

| Scale | Architecture Adjustments |
|-------|--------------------------|
| Single station, short sessions | Current design as-is: one process, in-memory session state, synchronous SQLite via FFI |
| Single station, 24/7 kiosk operation (weeks/months uptime) | Add: disk-space guard before `startRecording` (missing in reference app per `CONCERNS.md`), log rotation (reference app has none), WAL mode on SQLite from day one (reference app lacks this and risks lock contention), periodic health-check/auto-reconnect for camera (mirror `_try_reinitialize_camera` but avoid the reference app's broad `importlib.reload`-equivalent footgun — Flutter has no analog risk here since there's no module-reload mechanism, but a naive "recreate all services" reinit path should be avoided in favor of narrowly recreating just the camera connection) |
| Multiple stations (future, out of scope for v1) | Each station remains an independent process/DB as today; if centralization is ever wanted, it's an additive sync layer on top of this architecture, not a redesign |

### Scaling Priorities

1. **First reliability risk: camera disconnect/reinit during unattended operation.** Mirror the Python app's cooldown + auto-reinit logic, but implement it as a narrowly-scoped method on `CameraService` (reopen device handle only), never a broad "reload everything" operation.
2. **Second reliability risk: disk fills up during a long recording.** Add an explicit `shutil.disk_usage`-equivalent check (`File.stat()`/`FileSystemEntity` on the storage path, or a Win32 FFI call) before `startRecording`, refusing to start (with a clear UI error) below a configurable free-space floor — this is a documented missing feature in the reference app, not a Flutter-specific problem, but it's cheap to build correctly from the start.

## Anti-Patterns

### Anti-Pattern 1: Duplicating recording orchestration in a second entry point

**What people do (and what the Python reference did):** Re-implement the barcode → record → DB → compress sequence separately in each UI surface (Flask routes vs. Tkinter handlers), because each surface "just needs a slightly different response shape."
**Why it's wrong:** The two copies drift — the reference app's `CONCERNS.md` documents this exact drift (`SavingProgressDialog` UX only exists in the GUI path; the Flask API has no equivalent). Any bugfix must be made twice and is easy to forget once.
**Do this instead:** `RecordingOrchestrator` is the only thing that touches `CameraService`/`DatabaseService`/`CompressionService` for the record lifecycle. The Flutter UI is a thin caller. If a second surface is ever added (e.g., a companion web dashboard via `shelf`), it calls the same orchestrator instance or a serialized RPC into the same running process — it does not get its own copy of the state machine.

### Anti-Pattern 2: Global mutable state for "current recording session"

**What people do:** A top-level variable (`current_transaction_id` in `app.py`) or singleton mutated from multiple call sites with no ownership.
**Why it's wrong:** Race-prone (documented in `CONCERNS.md` as a real, if low-probability, bug in the reference app under Flask's threaded mode) and hard to reason about — any code anywhere can mutate it.
**Do this instead:** Session state (`currentTransactionId`, `isRecording`) is private state inside `RecordingOrchestrator`, mutated only by its own methods, exposed to the UI read-only through a Riverpod `Notifier`. There is exactly one instance of `RecordingOrchestrator` for the lifetime of the app (Riverpod `Provider`, not recreated).

### Anti-Pattern 3: Reaching for a Flutter camera plugin without validating recording quality first

**What people do:** Assume `camera` package parity with mobile — pick `camera_windows` (official but explicitly "under development," pause/resume unsupported, several controls unimplemented on Windows) or a lesser-known desktop fork, wire up the whole UI against it, and discover late that recorded file quality/codec/frame-timing doesn't meet the bar the Python/OpenCV reference already hits in production.
**Why it's wrong:** This is the single largest technical risk explicitly flagged in PROJECT.md ("Flutter's official camera plugin support on Windows is limited"). Committing to a plugin-based `CameraService` implementation before validating it against real hardware risks a costly rewrite mid-project.
**Do this instead:** Treat camera/recording integration as a dedicated phase-1 spike (see Build Order below) evaluating at minimum: (a) `camera_windows` via the standard `camera` package interface, (b) the community `camera_desktop` package (Media Foundation backend, actively maintained, claims Windows recording support), and (c) a custom FFI capture module reusing the proven Media Foundation/OpenCV approach from `camera_handler.py`. Decide based on measured recording quality/frame-timing on the actual target hardware, not documentation claims alone — then build `CameraService` behind the abstract interface so the decision is isolated.

### Anti-Pattern 4: Assuming `ffmpeg_kit_flutter`-style plugins solve Windows compression

**What people do:** Reach for a Flutter FFmpeg plugin (`ffmpeg_kit_flutter`, `ffmpeg_kit_flutter_new`) assuming it's a drop-in cross-platform FFmpeg wrapper.
**Why it's wrong:** The original `ffmpeg-kit` project was retired in January 2025 with binaries pulled from package registries; it was also historically mobile/iOS/Android-first with desktop as an afterthought, and pulls in a large bundled FFmpeg binary when the project already has a specific bundled/on-PATH `ffmpeg.exe` strategy (per PROJECT.md constraints) matching the Python reference.
**Do this instead:** Use `dart:io Process.start()` to shell out to the same bundled/documented `ffmpeg.exe` the Python app already uses — this is a direct, low-risk port of `video_compressor.py`'s subprocess approach and avoids an extra native dependency entirely.

### Anti-Pattern 5: Per-call SQLite connections (mirroring the Python reference's flaw)

**What people do:** Open a new SQLite connection for every query (as `database.py` does), relying on success-path cleanup only.
**Why it's wrong:** Already flagged as tech debt in `CONCERNS.md` (connection leak risk, no WAL, lock contention risk). No reason to re-import this pattern into a fresh codebase.
**Do this instead:** One long-lived `sqlite3` (Dart FFI package) connection per app process, opened at startup with `PRAGMA journal_mode=WAL` and `PRAGMA foreign_keys=ON`, wrapped so all access goes through `DatabaseService` methods — no ad hoc `Database.open()` calls scattered through the codebase.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Windows camera device | Either (a) `camera` package + `camera_windows`/`camera_desktop` plugin via platform interface, exposing a `Texture` for preview and plugin-native `startVideoRecording()`/`stopVideoRecording()`, or (b) custom Dart FFI binding to a small native Media Foundation/OpenCV capture module, feeding a registered Flutter texture manually | This is the #1 open risk — resolve via phase-1 spike, not assumption. `camera_windows` docs confirm pause/resume unsupported and several controls unimplemented; `camera_desktop` (Media Foundation backend) claims full recording support and is actively maintained (v1.2.1, verified publisher) but is a smaller, less battle-tested community package — validate against actual target webcams before committing. |
| `ffmpeg.exe` | `dart:io Process.start()`, same bundled-binary/PATH-lookup strategy as the Python reference (`video_compressor.py`'s `check_ffmpeg_installed()` search paths) | Do not use `ffmpeg_kit_flutter*` packages (see Anti-Pattern 4). Parse `-progress pipe:1`/stderr output for progress if a progress UI is wanted; Dart must actively drain both stdout and stderr streams to avoid pipe-buffer deadlock on Windows. |
| SQLite | `sqlite3` Dart package (FFI-based, works on Windows/macOS/Linux and the Dart VM) with `PRAGMA journal_mode=WAL` | Avoid `sqflite`/`sqflite_common_ffi` unless mobile parity is wanted later — plain `sqlite3` package is lighter for a desktop-only app and maps closely to the reference's raw-SQL, no-ORM style (`database.py`). If richer type-safety/codegen is desired later, `drift` can layer on top of the same SQLite file without a schema change. |
| Barcode scanner (USB HID keyboard wedge) | No plugin needed — scanner types characters + Enter into whatever has focus | App-level global key event listener (`HardwareKeyboard.instance` / `KeyboardListener` at the root) rather than relying on a single `TextField` having focus, so scans work regardless of which dialog is open — this is stricter than the Python reference (which requires the barcode `Entry` widget to have focus) and closes a real usability gap. |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| UI widgets ↔ Riverpod providers | `ref.watch`/`ref.read`, one-way data down, event calls up | Widgets never call services directly; always through a provider/notifier method |
| Providers ↔ Services | Direct method calls (`await service.method()`), providers awaiting/exposing `AsyncValue` | Providers are thin; no business logic lives here |
| `RecordingOrchestrator` ↔ `CameraService`/`DatabaseService`/`CompressionService` | Direct method calls, orchestrator owns the sequencing | This is the boundary that replaces the reference app's duplicated Flask/Tkinter orchestration — keep it the *only* caller of these three services for recording-lifecycle purposes |
| `CameraService` internals ↔ Flutter UI thread | Either plugin-managed `Texture`/platform-view (if plugin route) or FFI native callback via `NativeCallable.listener` (thread-safe dispatch back to the Dart isolate) if a custom capture module delivers frames from a non-Dart capture thread | `NativeCallable.isolateLocal` must not be used for cross-thread native camera callbacks — it aborts the process if invoked off the isolate's mutator thread; `NativeCallable.listener` is the correct, documented mechanism for native code calling back into Dart from an arbitrary thread |
| `CompressionService` worker ↔ UI | `Stream<CompressionEvent>` (broadcast) consumed by a Riverpod provider | Mirrors the Python reference's callback-based (`on_complete`) decoupling of the FFmpeg worker thread from the caller, just async/stream-based instead of callback-based |

## Suggested Build Order

Dependencies flow bottom-up: persistence/config first (no camera hardware needed, fully testable), then the highest-risk unknown (camera/recording integration) as an early spike, then orchestration wiring, then UI, then compression, then polish/parity details.

1. **Foundations (no hardware dependency, fully unit-testable):** `SettingsService` (JSON load/save/deep-merge, matching `settings_manager.py`'s shape) and `DatabaseService` (schema creation, WAL mode, CRUD, search) — both are pure-logic-adjacent and can be built and tested against the existing `ecom-py` `database.db`/`settings.json` shape for compatibility, satisfying the "Data compatibility" constraint in PROJECT.md before any UI exists.
2. **`BarcodeService`:** Pure function/state machine, zero dependencies, straight port of `barcode_handler.py`'s decision logic — trivial to build and unit test early, and it's a dependency of the orchestrator built next.
3. **Camera/recording spike (highest risk, do this before committing to a `CameraService` implementation):** Stand up a throwaway preview+record test harness against `camera_windows`, `camera_desktop`, and (if both disappoint) a minimal custom FFI capture module, and measure actual recorded video quality/frame timing on target hardware. This directly de-risks the item PROJECT.md flags as "the hard technical problem" before the rest of the app is built around a choice that might not hold up.
4. **`CameraService` (real implementation, behind the interface defined in step 3):** Preview texture + start/stop recording, matching the file-naming/folder-layout convention (`videos/YYYY-MM-DD/<Label>/*.mp4`) already established by the Python reference.
5. **`RecordingOrchestrator`:** Wire `BarcodeService` + `CameraService` + `DatabaseService` together (compression can be stubbed/no-op at this point) — this is where the core value proposition ("continuous scan → record → save loop... without missing frames or losing videos") becomes testable end-to-end for the first time.
6. **Minimal UI (main screen only):** Camera preview widget, barcode input (global key listener), recording indicator, recent-recordings list — enough to manually validate the orchestrator against real hardware and real scans.
7. **`CompressionService`:** `Process.start()`-based FFmpeg queue worker, wired into the orchestrator's `_finishCurrentRecording` path — safe to build after the core loop is proven, since compression is fire-and-forget and doesn't gate recording correctness. Implement with rename-then-delete/`FileSystemEntity.rename` atomic swap semantics from the start (fixing the reference app's documented delete-then-rename data-loss bug — do not port that pattern).
8. **Remaining UI surfaces:** `SearchDialog` (depends on `DatabaseService.search` only), `SettingsDialog` (depends on `SettingsService`), `SavingProgressDialog` (depends on orchestrator exposing an async "saving" state).
9. **Hardening pass:** Disk-space guard before recording, camera auto-reinit with cooldown, log rotation, storage/statistics display — these are the reference app's known gaps (`CONCERNS.md`); build them in from the start rather than retrofitting, since they're cheap here and expensive to add after the fact in production.

**What NOT to carry over from the Python reference (explicit non-goals):**
- No second presentation layer / no duplicated orchestration logic (no Flask-equivalent web routes re-implementing the recording state machine — a future web surface, if ever built, must call into the same `RecordingOrchestrator`).
- No global mutable module-level state (`current_transaction_id`-style globals) — all session state is owned by one service instance.
- No per-call SQLite connections without pooling — one long-lived WAL-mode connection via `DatabaseService`.
- No delete-then-rename compression swap — atomic replace only.
- No silent FFmpeg-missing skip — surface a persistent, visible warning.
- No unbounded log file — rotate from day one.
- No `importlib.reload`-equivalent "reload everything" pattern for camera reinit — narrowly scoped reconnect only.

## Sources

- [camera_windows | Flutter package](https://pub.dev/packages/camera_windows) — MEDIUM confidence (official docs, but plugin explicitly "under development"; pause/resume and several controls unimplemented on Windows)
- [camera_desktop | Flutter package](https://pub.dev/packages/camera_desktop) — MEDIUM confidence (official docs; actively maintained, Media Foundation backend on Windows, claims video recording support; smaller community package, not yet validated against this project's hardware)
- [Top Flutter Camera Image Capture, Video Recorder packages | Flutter Gems](https://fluttergems.dev/camera/) — LOW-MEDIUM confidence, ecosystem survey
- [GitHub - yushulx/flutter_camera_windows](https://github.com/yushulx/flutter_camera_windows) — LOW confidence, community fork reference only
- [Flutter FFMPEG support for windows desktop · Issue #140305 · flutter/flutter](https://github.com/flutter/flutter/issues/140305) — MEDIUM confidence, official Flutter issue tracker context on FFmpeg-on-Windows gaps
- [Saying Goodbye to FFmpegKit — Taner Sener, Medium](https://tanersener.medium.com/saying-goodbye-to-ffmpegkit-33ae939767e1) — HIGH confidence (maintainer's own retirement announcement, Jan 2025)
- [ffmpeg_kit_flutter_new | Flutter package](https://pub.dev/packages/ffmpeg_kit_flutter_new) — MEDIUM confidence, official pub.dev listing
- [sqflite_common_ffi | Dart package](https://pub.dev/packages/sqflite_common_ffi) — HIGH confidence, official docs
- [sqflite vs drift comparison — Flutter Gems](https://fluttergems.dev/sql-database/) — MEDIUM confidence, ecosystem survey
- [NativeCallable.listener / NativeCallable class — Dart API docs](https://api.flutter.dev/flutter/dart-ffi/NativeCallable-class.html) — HIGH confidence, official Dart API documentation
- [dart:io Process class — Dart API docs](https://api.dart.dev/dart-io/Process-class.html) — HIGH confidence, official Dart API documentation
- [Process.start() gets blocked when read stderr before stdout · dart-lang/sdk#50674](https://github.com/dart-lang/sdk/issues/50674) — MEDIUM confidence, official issue tracker, confirms pipe-buffer deadlock risk requiring both streams drained
- [Flutter App Architecture with Riverpod: An Introduction — Code with Andrea](https://codewithandrea.com/articles/flutter-app-architecture-riverpod-introduction/) — MEDIUM confidence, widely-cited community reference for Riverpod layering
- [Riverpod App Architecture with the Controller-Service-Repository Pattern — Code with Andrea](https://pro.codewithandrea.com/flutter-foundations/03-app-architecture/03-riverpod-app-architecture) — MEDIUM confidence
- `.planning/codebase/ARCHITECTURE.md` — HIGH confidence, first-party analysis of the reference implementation this port is based on
- `.planning/codebase/CONCERNS.md` — HIGH confidence, first-party analysis of known flaws to avoid replicating

---
*Architecture research for: Flutter Windows desktop camera-recording + SQLite + FFmpeg app*
*Researched: 2026-07-11*
