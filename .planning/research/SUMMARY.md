# Project Research Summary

**Project:** Ecom Video Tracker — Flutter Port
**Domain:** Flutter Windows desktop app — barcode-triggered webcam video recording (feature-parity port of a working Python/Tkinter reference app)
**Researched:** 2026-07-11
**Confidence:** MEDIUM-HIGH

## Executive Summary

This is a **port-parity project**, not a greenfield product: the feature set, data schema, and file layout are all fixed by a working Python/Tkinter reference app (`ecom-py/`) that operators use daily at packing stations. Experts build this kind of project by (1) isolating the one genuinely uncertain technical risk behind a clean interface and de-risking it first with a real-hardware spike, then (2) building the deterministic, well-understood parts (settings, database, barcode state machine) in parallel/beforehand since they need no hardware and are fully unit-testable, and (3) reproducing the reference app's proven operational patterns (serialized FFmpeg queue, watermarking, folder/DB layout) rather than reinventing them.

The recommended approach is: `camera` + `camera_windows` (official, Media Foundation-based Flutter plugin) as the primary camera/recording implementation, with `camera_desktop` (a newer, more actively-maintained community package on the same `camera_platform_interface`) as a drop-in fallback if a Phase 1 hardware spike finds enumeration or recording-reliability gaps. Everything else is high-confidence, conventional Flutter desktop architecture: `sqflite_common_ffi`/`sqlite3` for schema-compatible SQLite persistence, a hand-rolled JSON settings file (not `shared_preferences`) to preserve the "editable settings.json beside the exe" workflow, `dart:io Process.start()` for FFmpeg (not a Dart FFmpeg wrapper package), and a single `RecordingOrchestrator` service class as the one and only caller of camera/DB/compression services — directly fixing the reference app's worst architectural flaw (duplicated business logic between its Flask and Tkinter frontends).

The key risk, named explicitly in the project's own PROJECT.md and confirmed independently by all four research passes, is **Windows camera capture + recording in Flutter**: the official plugin is still described by its own maintainers as "under development," has open GitHub issues around camera enumeration gaps and codec/`PlatformException` failures, and lacks exposure/gain/brightness controls the reference app's operators actively use. This must be resolved with an end-to-end record/stop/save proof-of-concept on real target webcam hardware before any UI work depends on a concrete `CameraService`. The second-highest risk is **keyboard-wedge barcode input reliability** — Flutter's current `HardwareKeyboard` API is focus-scoped by design, which can silently drop or garble fast synthetic scanner keystrokes exactly when a dialog is open or nothing has focus; this must be solved with a top-level, focus-independent key handler and validated with real scanner hardware, not manual typing. A third cross-cutting risk — data loss from a delete-then-rename compression bug already present in the Python reference — is a known, named anti-pattern that must be deliberately avoided (atomic file replace only) rather than accidentally reintroduced during the port.

## Key Findings

### Recommended Stack

Flutter stable + Dart is the fixed platform choice (already decided in PROJECT.md). The stack research narrows the two genuinely open decisions — camera capture and SQLite access — and settles the rest (windowing, settings, packaging) with clear, low-risk defaults that prioritize parity and simplicity over introducing new abstractions.

**Core technologies:**
- `camera` (`^0.12.0+1`) + `camera_windows` (`^0.2.6+4`): live preview + `startVideoRecording()`/`stopVideoRecording()` — official, Flutter-team-maintained, built on Windows Media Foundation's Capture Engine with zero-copy texture rendering; primary approach, pending Phase 1 hardware validation
- `sqflite_common_ffi` (`^2.4.2`): SQLite persistence — raw-SQL API mirrors `database.py` near-verbatim, guarantees schema compatibility with the existing `database.db` that must remain searchable across both apps
- `win32` (`^6.3.0`): Windows FFI bindings — fallback camera enumeration, process-priority flags, and (if needed) `IAMCameraControl`/`IAMVideoProcAmp` exposure control shim
- `window_manager` (`^0.5.2`): window sizing/title/close-intercept — used to warn the operator if a recording is active before allowing app exit
- Hand-rolled JSON settings file (`dart:io` + `dart:convert`), NOT `shared_preferences` — preserves the human-editable `settings.json`-beside-the-exe workflow operators already rely on
- `dart:io Process.start('ffmpeg.exe', ...)` for compression — direct port of `video_compressor.py`'s subprocess approach; explicitly avoid `ffmpeg_kit_flutter*` packages (the underlying `ffmpeg-kit` project was retired in Jan 2025)

Packaging: `flutter build windows` portable folder wrapped in an Inno Setup installer, not MSIX — avoids a code-signing certificate requirement disproportionate to an internal packing-station tool, and matches the Python app's existing PyInstaller-based cert-free distribution model.

### Expected Features

This is a parity spec, not a competitive-features exercise: "table stakes" means "required for operators to accept the port as a replacement for the app they use daily." All Table Stakes items are v1 — nothing from the reference app is deferrable, since operators are switching wholesale.

**Must have (table stakes, v1):**
- Barcode-triggered recording state machine (start / stop-and-start / stop) — the core value loop
- Video Label selector (Normal / Return and Refund Unboxing / Return Parcel Unboxing) — **undocumented in PROJECT.md's requirement list but deeply load-bearing**: drives folder layout, DB schema, watermark text, and search filters; must be scoped into the first phase that touches storage
- Live camera preview independent of recording state, with auto-reinit on camera disconnect
- Frame watermarking (timestamp, label, barcode) burned in via the native video pipeline
- SQLite transaction log matching the existing schema exactly
- Search dialog: barcode/label/date-range filters, sort, result cards, play/show-in-folder, with backward-compatible path resolution for pre-label-folder legacy files
- Settings dialog: camera selection by human-readable name, resolution/FPS/codec, exposure/gain/brightness live-tuning, storage paths, FFmpeg compression settings
- FFmpeg compression queue: serialized single-worker, auto-discovery, graceful skip when missing, status tracked per-transaction
- Non-blocking save with a "Saving Recording..." progress dialog; confirm-before-exit while recording
- File + console logging of all significant events

**Should have (differentiators, safe to layer on once parity is field-validated):**
- Atomic compress-then-swap instead of the reference app's delete-then-rename data-loss bug
- Disk-space guard before starting a recording (reference has none)
- Robust global keyboard-wedge capture independent of widget focus (turns an implicit reference-app fragility into a genuine improvement)
- SQLite WAL mode, log rotation, modern theming (keep purple identity)

**Defer (explicitly out of scope, v2+):**
- Web UI / Flask-equivalent, mobile targets, cloud sync, user auth, multi-camera support, inventory integration, configurable/free-form barcode prefixes (dead code in the reference, do not port), new label categories beyond the fixed 3

### Architecture Approach

Single `RecordingOrchestrator` service class is the one and only caller of `CameraService`/`DatabaseService`/`CompressionService`/`BarcodeService` for the recording lifecycle, exposed to a single Flutter UI through thin Riverpod providers — this directly eliminates the reference app's worst flaw (duplicated orchestration logic between its Flask and Tkinter frontends, which had already drifted). `CameraService` is defined behind an abstract interface specifically so the camera plugin decision (the project's biggest open risk) can be swapped without rippling into the orchestrator or UI. No global mutable state anywhere — all session state (`isRecording`, `currentTransactionId`) is owned by exactly one long-lived service instance, constructed once and provided via Riverpod.

**Major components:**
1. `RecordingOrchestrator` — single source of truth for barcode-scan → recording-lifecycle → DB → compression sequencing
2. `CameraService` (interface + swappable plugin/FFI implementation) — camera lifecycle, preview texture, start/stop recording
3. `DatabaseService` — one long-lived WAL-mode SQLite connection, all reads/writes for the `transactions` table
4. `CompressionService` — async worker loop over a queue, `Process.start()`-based FFmpeg invocation, atomic file replace
5. `SettingsService` — JSON load/save/deep-merge matching `settings_manager.py`'s shape, notifies dependent providers on change
6. `BarcodeService` — pure, stateless decision function (start/stopAndStart/stop/invalid), zero I/O, trivially unit-testable
7. Global keyboard listener — app-wide `HardwareKeyboard` handler routing scanner keystrokes to `BarcodeService` regardless of focused widget

Suggested build order (bottom-up by dependency, not by UI-visible phase): foundations (Settings/DB, no hardware needed) -> `BarcodeService` -> camera/recording spike (highest risk, resolve before committing) -> real `CameraService` -> `RecordingOrchestrator` wiring -> minimal UI to validate end-to-end -> `CompressionService` -> remaining UI surfaces (Search/Settings dialogs) -> hardening pass (disk guard, reinit cooldown, log rotation).

### Critical Pitfalls

1. **`camera_windows` may not actually be able to do this app's job** — open GitHub issues on camera enumeration gaps and `PlatformException` on `startVideoRecording`, no exposure/focus controls, plugin self-described as "under development." Avoid by treating camera integration as a mandatory Phase 1 spike against real target webcam hardware (not just the dev machine's built-in camera) before any UI is built around it; keep `camera_desktop` as an evaluated fallback and a custom FFI Media Foundation module as a last resort.
2. **Codec/container mismatch breaks the existing FFmpeg compression pipeline** — Media Foundation's encoder choices don't necessarily match OpenCV's FOURCC output the Python app is tuned around. Avoid by running the *exact* existing FFmpeg compression command against Flutter-captured test video during the Phase 1 spike and comparing `ffprobe` output/file sizes before committing to the capture path.
3. **Keyboard-wedge barcode scans get silently swallowed or duplicated depending on focus** — Flutter's `HardwareKeyboard`/`KeyEvent` API (which replaced deprecated `RawKeyboard`) is focus-scoped by design, a fundamental mismatch with global-hotkey-style scanner input. Avoid with a top-level, focus-independent key handler installed at app root, inter-key timeout buffering matching `barcode_handler.py`'s proven debounce logic, and mandatory testing with real scanner hardware while dialogs are open and while nothing has focus.
4. **Long-running kiosk sessions surface memory/handle growth invisible in short demos** — repeated texture registration/unregistration on every record start/stop cycle, or FFmpeg zombie processes, only show up after hours of real shift-length operation. Avoid with an explicit multi-hour soak test (hundreds of simulated scan cycles) monitoring native Windows handle/working-set counts as an exit criterion, not just Dart heap via DevTools.
5. **Delete-then-rename compression finalize reintroduces a known, already-documented data-loss bug** from the Python reference (`video_compressor.py:305-315`) — a crash between delete and rename permanently loses the original video. Avoid with an explicit code-review gate against any delete-before-rename sequence; use atomic `File.rename()`/`MoveFileEx` replace semantics only.

## Implications for Roadmap

Based on combined research, suggested phase structure:

### Phase 1: Foundations + Camera/Recording Spike
**Rationale:** Settings and Database services need no hardware and are fully unit-testable — build them first to validate schema/JSON compatibility with the existing `ecom-py` files early and cheaply. In parallel/immediately after, resolve the single highest-risk unknown (camera capture+recording on Windows) before any UI work depends on a concrete `CameraService`, per PROJECT.md's own framing of this as "the hard technical problem."
**Delivers:** `SettingsService` (JSON deep-merge, matching `settings_manager.py`), `DatabaseService` (WAL-mode SQLite, schema-compatible with `database.db`), `BarcodeService` (pure state machine), and a validated end-to-end record/stop/save proof-of-concept against real target webcam hardware with a documented plugin choice (`camera_windows` vs. `camera_desktop` vs. FFI fallback).
**Addresses:** Table-stakes settings persistence, SQLite transaction log schema compatibility, barcode state machine (FEATURES.md)
**Avoids:** Pitfall 1 (camera plugin can't do the job), Pitfall 2 (codec/container mismatch), Pitfall 8 (path-resolution architecture must be decided here regardless of eventual packaging choice)

### Phase 2: Core Recording Workflow
**Rationale:** With `CameraService` validated and `BarcodeService`/`DatabaseService` already built, this phase wires the actual core value proposition — the continuous scan->record->save loop — and is where the project's second-biggest risk (keyboard-wedge reliability) must be solved.
**Delivers:** `RecordingOrchestrator` (single orchestrator pattern), global focus-independent keyboard listener, frame watermarking, Video Label selector wired into folder/DB/watermark, minimal main-screen UI (preview, barcode input, recording indicator, recent list) sufficient to manually validate against real hardware and real scans.
**Uses:** `camera`/`camera_windows` (or fallback), `win32` for registry/priority fallbacks, Riverpod state layer
**Implements:** `RecordingOrchestrator`, `CameraService`, global keyboard listener (ARCHITECTURE.md)

### Phase 3: Compression Integration
**Rationale:** Compression is fire-and-forget from the orchestrator's perspective and doesn't gate recording correctness, so it's safe to build once the core loop is proven — but it carries its own named risks (data-loss bug, silent-skip UX gap, CPU contention with live recording) that must be deliberately designed against rather than retrofitted.
**Delivers:** `CompressionService` (serialized async worker queue over `Process.start()`), atomic compress-then-swap file replacement, FFmpeg bundling/path-resolution relative to the executable, fail-loud UX when FFmpeg is missing, compression status tracked per-transaction.
**Addresses:** FFmpeg Compression Flow (FEATURES.md table stakes)
**Avoids:** Pitfall 6 (delete-then-rename data loss), Pitfall 7 (FFmpeg bundling/priority issues)

### Phase 4: Search, Settings UI, and Remaining Surfaces
**Rationale:** These UI surfaces depend only on already-built services (`DatabaseService.search`, `SettingsService`) and carry no new architectural risk — standard Flutter dialog/form patterns.
**Delivers:** Search dialog (filters, sort, result cards, backward-compatible legacy path resolution), Settings dialog (all tabs: video, camera, compression, storage), `SavingProgressDialog`.
**Addresses:** Search Dialog and Settings Dialog table-stakes features (FEATURES.md)

### Phase 5: Hardening and Soak Validation
**Rationale:** The reference app's known gaps (no disk-space guard, no WAL mode, no log rotation, camera reinit fragility) are cheap to build in now and expensive to retrofit after field deployment — and long-run stability (memory/handle growth, scan-under-load reliability) can only be verified with sustained, hours-long testing that should gate release, not follow it.
**Delivers:** Disk-space guard before recording, camera auto-reinit with cooldown, log rotation, multi-hour soak test (hundreds of simulated scan cycles) with flat memory/handle count as an explicit exit criterion, slow-disk/simulated-contention test for scan reliability under load.
**Avoids:** Pitfall 4 (long-run memory/handle growth), Pitfall 5 (main-isolate stalls dropping scan input)

### Phase Ordering Rationale

- Camera/recording risk must be resolved before UI work is built around a specific plugin choice — this is the single dependency that blocks the most downstream work if left unresolved (per both ARCHITECTURE.md's "Suggested Build Order" and PITFALLS.md's Pitfall 1 phase mapping).
- Settings/Database can and should be built before or alongside the camera spike since they have zero hardware dependency and validate a separate parity requirement (schema/file compatibility) early.
- Compression is deliberately sequenced after the core recording loop works, matching its "fire-and-forget, queued on stop not start" dependency relationship documented in FEATURES.md's Feature Dependencies graph.
- Hardening (soak testing, disk guard, log rotation) is sequenced last but is explicitly NOT optional polish — PITFALLS.md frames multi-hour soak validation as a release-gating exit criterion, not a nice-to-have, because this app runs unattended for full kiosk shifts.

### Research Flags

Needs deeper research during planning (`/gsd:plan-phase --research-phase <N>`):
- **Phase 1:** Camera/recording spike — thin, fast-moving plugin ecosystem (`camera_windows` vs `camera_desktop`), hardware-dependent behavior that generic research cannot fully resolve; needs direct testing against actual target webcam models, not just documentation review.
- **Phase 2:** Keyboard-wedge global capture — Flutter's `HardwareKeyboard` API is relatively new (post-`RawKeyboard` migration) with thin community coverage specifically for global/focus-independent capture; several open GitHub issues suggest this is still an active pain point.
- **Phase 3:** FFmpeg process-priority control on Windows from Dart — no first-class API for this in `dart:io Process`; needs a concrete decision (Win32 FFI `SetPriorityClass` vs. `cmd.exe` wrapper vs. relying on serialization alone) validated against real frame-drop testing.

Phases with standard, well-documented patterns (skip research-phase):
- **Phase 1 (Settings/Database portions only):** Standard `sqflite_common_ffi`/JSON-file patterns, HIGH confidence, directly portable from the existing Python schema.
- **Phase 4:** Search/Settings dialog UI — conventional Flutter forms/dialogs, no novel technical risk once underlying services exist.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM-HIGH | Everything except the camera/recording pipeline is HIGH confidence (official docs, live pub.dev API verification). Camera pipeline is MEDIUM — both plugin options are real but neither is validated against this project's actual target hardware yet. |
| Features | HIGH | Sourced directly from line-by-line reading of the working reference implementation (`app_gui.py` and all supporting modules) across 6 passes — this is a parity spec, not speculative market research. |
| Architecture | MEDIUM-HIGH | Component boundaries, state management, and data flow are HIGH confidence (standard, well-established Flutter desktop/Riverpod patterns). The camera/recording integration point is MEDIUM, consistent with the Stack assessment — same underlying uncertainty, flagged for the same Phase 1 spike. |
| Pitfalls | MEDIUM | Camera/keyboard mechanics verified against official Flutter docs and GitHub issue trackers; some Windows-desktop-specific failure modes (e.g., texture lifecycle leaks, FFmpeg priority control) have thinner community coverage because this specific plugin combination is relatively niche. Pitfalls sourced from the project's own first-party `CONCERNS.md` audit (delete-then-rename bug, no disk guard, no WAL, no log rotation) are HIGH confidence. |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **Camera plugin choice is not yet validated against real target hardware** — all four research files converge on the same recommendation (spike first, `camera_windows` primary / `camera_desktop` fallback / custom FFI last resort) but none can resolve this without actually testing the specific USB webcam models used at packing stations. This must be the literal first work item, not just a planning artifact.
- **Manual exposure/gain/brightness control parity is uncertain** — the reference app exposes live `cv2.VideoCapture.set()`-based controls that neither `camera_windows` nor `camera_desktop` currently implement. Whether this is an actual hard requirement at the packing stations (vs. a nice-to-have) needs a decision from the project stakeholder/operators, not just technical research — flag during Phase 1 planning.
- **FFmpeg process-priority control has no clean Dart-native solution** — requires either a `cmd.exe` wrapper or `win32` FFI `SetPriorityClass` call; the exact approach should be decided and validated with frame-drop testing during Phase 3, not assumed.
- **Video Label selector was not explicitly named in PROJECT.md's requirement list** despite being deeply load-bearing (folder layout, watermark, DB schema, search filter) — confirmed present and required via FEATURES.md's direct code reading. Treat as a confirmed, non-negotiable Phase 2 requirement, not an open question, but flag that PROJECT.md itself should probably be updated to name it explicitly.

## Sources

### Primary (HIGH confidence)
- pub.dev API — live version/publish-date verification for `camera`, `camera_windows`, `camera_desktop`, `sqflite_common_ffi`, `window_manager`, `win32`, and related packages
- https://docs.flutter.dev/release/breaking-changes/key-event-migration — official Flutter `RawKeyboard` -> `HardwareKeyboard` migration doc
- https://learn.microsoft.com/en-us/windows/win32/medfound/enumerating-video-capture-devices — Microsoft's own guidance on Media Foundation as the modern capture API
- https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes — MSIX AppData virtualization behavior
- `ecom-py/app_gui.py`, `barcode_handler.py`, `camera_handler.py`, `video_compressor.py`, `database.py`, `settings_manager.py` — primary parity spec, read in full
- `.planning/PROJECT.md`, `.planning/codebase/ARCHITECTURE.md`, `.planning/codebase/CONCERNS.md` — first-party project source of truth and known-flaws audit

### Secondary (MEDIUM confidence)
- https://github.com/flutter/flutter/issues/98404, #141847, #107302, #154141, #79849, #161288 — various open/closed GitHub issues on camera enumeration, recording exceptions, and keyboard-listener focus behavior
- https://pub.dev/packages/camera_desktop — community package docs, single-source WebFetch summary
- https://tanersener.medium.com/saying-goodbye-to-ffmpegkit-33ae939767e1 — `ffmpeg-kit` retirement announcement (Jan 2025)
- Community sources on Flutter Windows packaging (MSIX vs. Inno Setup) — multiple sources agree, no single authoritative comparison doc

### Tertiary (LOW confidence)
- https://github.com/yushulx/flutter_camera_windows — community fork, reference only, not evaluated as a real candidate
- Flutter mobile-platform texture-leak issue reports (#60409, #140503) — cited only as directional evidence for a bug category, not confirmed on Windows specifically

---
*Research completed: 2026-07-11*
*Ready for roadmap: yes*
