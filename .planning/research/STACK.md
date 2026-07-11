# Stack Research

**Domain:** Flutter Windows desktop app — barcode-triggered webcam video recording (port of ecom-py)
**Researched:** 2026-07-11
**Confidence:** MEDIUM-HIGH (camera recording pipeline is the one MEDIUM item; everything else HIGH)

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Flutter (stable channel) | 3.x current stable | UI framework, Windows desktop target | Already the project's chosen stack (see PROJECT.md); `flutter build windows` produces a self-contained native app, no runtime install needed — matches the "no Python runtime" distribution goal |
| Dart | bundled with Flutter SDK | Application language | No alternative; ships with Flutter |
| `camera` + `camera_windows` | `camera: ^0.12.0+1`, `camera_windows: ^0.2.6+4` (camera_windows published 2025-11-19) | Live preview + programmatic start/stop MP4 recording | This is the **official, Flutter-team-maintained** Windows camera implementation, built on Windows Media Foundation's Capture Engine with `TextureRegistrar`-based zero-copy preview rendering. It now supports `startVideoRecording()`/`stopVideoRecording()` producing `.mp4` directly — this is a materially different (better) state than older references suggesting Windows camera recording was preview-only. It integrates through the standard `camera_platform_interface`, so app code (`CameraController`) is portable and well-documented. **Recommend as PRIMARY approach.** |
| `sqflite_common_ffi` | `^2.4.2` | SQLite persistence on Windows | FFI-based `sqflite` implementation for desktop (Windows/Linux), using the same `sqflite`/`Database` API most Flutter devs already know. Directly reuses the existing hand-written SQL schema/queries from `ecom-py/database.py` almost verbatim (raw SQL, no ORM migration needed) — best fit for a straight port where schema compatibility with the Python app's `database.db` is a hard requirement. |
| `win32` | `^6.3.0` | Windows FFI bindings (DirectShow/registry fallback, process priority flags) | Needed as the fallback layer for camera enumeration edge cases and to replicate the Python app's `winreg`/`wmi`/process-priority behavior (`CREATE_NO_WINDOW`, `IDLE_PRIORITY_CLASS` equivalents) without shelling out. Actively maintained, current release 2026-05-22. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `window_manager` | `^0.5.2` | Window sizing, min-size, title bar, close-intercept (to warn if recording is active) | Use for all custom window chrome/behavior needs — actively maintained (2026-07-04), the de facto standard for Flutter Windows window control. |
| `path_provider` | `^2.1.6` | Resolve app-relative storage paths (videos dir, settings, logs) | Use instead of hardcoding paths; still need custom logic to mirror the Python app's "beside the executable" default (see Architecture note below). |
| `shared_preferences` | `^2.5.5` | Simple key-value settings, OR skip entirely | Only if settings are trivial. Given the Python app uses a structured `settings.json` with nested video/camera/storage/compression sections, prefer **hand-rolled JSON settings file** (via `dart:io File` + `dart:convert`) to keep parity with `settings_manager.py`'s deep-merge-over-defaults behavior and to keep `settings.json` human-editable/inspectable exactly as today. Do not use `shared_preferences`' Windows backend (JSON in a hidden per-user folder) if operators expect to see/edit `settings.json` next to the exe. |
| `intl` | latest matching Flutter SDK constraint | Date/time formatting for filenames (`YYYYMMDD_HHMMSS`) and search UI | Needed to replicate `strftime`-style formatting from Python. |
| `path` | latest | Cross-platform-safe path joining | Use everywhere instead of manual string concatenation for `videos/YYYY-MM-DD/...` paths. |
| `win32_registry` | `^3.0.3` | Typed wrapper over `win32` for registry reads | Only needed if camera friendly-name enumeration requires registry fallback (see Architecture below) — cleaner API than raw `win32` FFI calls for that narrow case. |
| `logging` (Dart core package) or hand-rolled file logger | latest | Replicate `logs/app.log` behavior | Use `dart:io` `File.writeAsString(mode: FileMode.append)` directly for simplicity, or the `logging` package if structured levels are wanted — no need for anything heavier. |
| `msix` | `^3.18.0` | MSIX packaging (Microsoft Store or sideload) | Only if distributing via Microsoft Store or an MDM/enterprise MSIX push. See packaging discussion below — likely NOT the right choice for this project's likely self-distribution model. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| `flutter_lints` | Standard Dart/Flutter lint rules | `^6.0.0`; enable in `analysis_options.yaml` from project start. |
| FFmpeg (external binary, unbundled or bundled alongside exe) | Post-recording video compression | Keep the exact same external-process approach as the Python app (`dart:io Process.run`/`Process.start` instead of Python's `subprocess`). No Dart FFmpeg wrapper package needed — `Process.start('ffmpeg.exe', [...])` with an absolute path is sufficient and matches existing operational knowledge (where to place `ffmpeg.exe`, PATH lookup, etc.). Avoid the `ffmpeg_cli` pub package — it's a thin, low-adoption convenience wrapper that adds a dependency for something 20 lines of `Process.start` code already does, and the team already knows the raw CLI flags from the Python implementation. |

## Installation

```bash
# Core camera + windowing
flutter pub add camera camera_windows window_manager

# Database
flutter pub add sqflite_common_ffi

# Windows FFI utilities
flutter pub add win32 win32_registry

# Path/date utilities
flutter pub add path path_provider intl

# Dev dependencies
flutter pub add -d flutter_lints
```

No `npm`/JS tooling applies — this is a pure Flutter/Dart project (`pubspec.yaml`, `flutter pub` only).

## The Hard Problem: Camera Preview + Recording on Windows

### Recommended approach: `camera` + `camera_windows` (Media Foundation, official plugin)

**Verdict: Use this as the primary path.** Confidence: MEDIUM-HIGH.

Findings:
- `camera_windows` (v0.2.6+4, published 2025-11-19) is the Flutter-team-maintained Windows federated implementation of the standard `camera` plugin. It is built on **Windows Media Foundation's Capture Engine** (`IMFCaptureEngine`), not the older DirectShow API — this matches Microsoft's own guidance that DirectShow is legacy and Media Foundation is the recommended modern capture API.
- It renders preview frames via Flutter's `TextureRegistrar`/`flutter::TextureVariant` pixel-buffer texture API — the same zero-copy GPU texture mechanism used by `camera_android`/`camera_avfoundation`, so preview performance should be solid (no manual image-stream-to-widget conversion needed, unlike the Python app's OpenCV→PIL→Tkinter frame-copy loop).
- It supports `startVideoRecording()` / `stopVideoRecording()` producing MP4 output directly — the core requirement is met by the official plugin, not just image preview.
- Known limitations (verified via pub.dev changelog and GitHub issues, both current as of mid-2026):
  - Pause/resume recording is unsupported ("Windows API limitations") — **not needed** for this app; the workflow is continuous start→stop→start, never pause.
  - Exposure/focus/flash controls are unimplemented — **the Python app already sets exposure/gain/brightness via OpenCV `cv2.VideoCapture.set()`**, which has no direct `camera_windows` equivalent yet. This is a real gap: verify during implementation whether manual exposure control is actually used in practice at the packing stations, or whether it can be dropped/deferred as a non-blocking parity gap.
  - `availableCameras()` has a long-standing open GitHub issue (#98404, filed 2022, still open, no recent activity) reporting it sometimes misses cameras that Windows itself lists (e.g., virtual cameras, some USB webcams). This is the single biggest risk to the "camera selection by name" requirement.
  - A release-build-only crash during camera initialization was reported (GitHub #161288, opened Jan 2025) and is marked closed/solved — treat as resolved in current versions, but validate on the actual target hardware/webcam models during Phase 1 spike, specifically testing `flutter build windows` (release) and not just `flutter run` (debug).

**Required mitigation:** Do a **1-2 day spike in Phase 1** (before committing the roadmap to this plugin) that specifically validates against the real hardware: (a) does `availableCameras()` return every camera the target packing-station PCs have, with usable friendly names; (b) does a release build (`flutter build windows`) reliably record without the exposure/manual-control features the Python app relies on. If camera enumeration proves unreliable, fall back to hybrid: use `win32`/`win32_registry` (DirectShow registry enumeration, same technique `pygrabber` uses under the hood in the Python app) purely for the friendly-name list show to the user, then map the selected friendly name to the `camera_windows`-provided `CameraDescription` by matching device paths.

### Alternative considered: `camera_desktop`

**Verdict: Credible fallback, not primary — re-evaluate if `camera_windows` spike fails.** Confidence: MEDIUM.

- Community package (publisher `hugo.ml`, verified publisher on pub.dev), v1.2.1, published 2026-06-13 (actively maintained, more recent release cadence than `camera_windows` itself).
- Also built on Media Foundation for Windows (same underlying API as `camera_windows`), plus GStreamer+V4L2 on Linux and AVFoundation on macOS — a genuine cross-desktop implementation of `camera_platform_interface`, useful if mobile/other-desktop reuse becomes a real goal later (noted as a motivation for choosing Flutter in PROJECT.md).
- Supports both camera enumeration and video recording on Windows per its own feature table.
- Smaller adoption (~3.75k downloads at research time) than the official plugin — less battle-tested, but being newer and more recently updated, it may have already fixed enumeration issues that the official plugin's stale open GitHub issue suggests are unresolved there.
- **Use this if** the Phase 1 spike shows `camera_windows` fails on real target hardware (enumeration gaps or recording reliability), since it's a drop-in replacement at the `camera_platform_interface` level — no application-code rewrite needed, just swap the platform package in `pubspec.yaml`.

### Rejected approach: custom FFI to Media Foundation

**Verdict: Do not build this. Reserve only as a last-resort escape hatch.** Confidence: HIGH (rejection confidence).

- Writing a custom `IMFCaptureEngine` C++ plugin with a `flutter::TextureVariant` bridge (the same architecture `camera_windows` itself uses internally) would fully replicate what the official plugin already does, at far higher cost — this is exactly the mistake the abandoned Qt6/C++ port made (see PROJECT.md: "C++ port was too slow to develop"). Only revisit this if BOTH `camera_windows` and `camera_desktop` fail the Phase 1 hardware spike in ways that cannot be worked around (e.g., a specific required exposure-control feature that neither plugin exposes and is confirmed essential to the packing workflow).

### Rejected approach: FFmpeg-based capture via dshow

**Verdict: Do not use for live preview + recording.** Confidence: HIGH.

- Piping `ffmpeg -f dshow -i video="..."` for capture would work for recording but provides no natural path to a live Flutter preview widget without an extra frame-extraction/streaming layer (e.g., piping raw frames back and rendering to a texture manually) — strictly more complexity than the `camera`/`camera_windows` texture-based preview that already exists for free. Reserve FFmpeg for its proper job in this app: **post-recording compression**, exactly as the Python app already does it (see below).

## SQLite: `sqflite_common_ffi` (recommended) vs `drift`

**Recommendation: `sqflite_common_ffi`.** Confidence: HIGH.

| Criterion | `sqflite_common_ffi` | `drift` |
|---|---|---|
| API style | Raw SQL via `Database.rawQuery`/`rawInsert`, same shape as Python's `sqlite3` cursor calls | Code-generated, type-safe query builder (build_runner codegen) |
| Fit for this port | Excellent — `database.py`'s existing SQL strings can be ported near-verbatim | Requires translating schema + queries into Drift's Dart DSL, then codegen |
| Schema compatibility requirement | PROJECT.md requires the DB schema to stay compatible with `ecom-py`'s `database.db` so existing archives remain searchable — raw SQL against the same `.db` file is the lowest-risk way to guarantee this | Also achievable, but adds an abstraction layer and generated-code build step for zero added benefit here |
| Reactivity (auto-updating UI on data change) | Not built in — must manually refresh after writes (which is fine; this app's UI already re-queries on explicit user actions like Search) | Built-in `Stream`-based reactive queries — a genuine feature, but not a stated requirement |
| Windows setup | `sqfliteFfiInit()` + `databaseFactoryFfi` at app startup; sqlite3 v3.x FFI package uses build_hooks to fetch/build `sqlite3.dll` automatically — no manual DLL bundling needed with current versions | Uses `package:sqlite3` (`drift/native.dart`) under the hood — same underlying native binding, same DLL story |
| Verdict | **Use this** — matches the "straight port" philosophy in PROJECT.md ("Reduce risk; parity is the measure of success") and avoids introducing a new query paradigm and build step for a database layer that's already simple (a handful of tables/queries) | Reasonable choice for a greenfield app with complex reactive state needs — not this app |

**Windows DLL note:** With `sqlite3` (the underlying native package) at v3.0.0+, `sqlite3.dll` is fetched/built automatically via build_hooks and should work in both debug and release without manual steps. If pinned to an older `sqlite3` transitively, release builds require manually placing `sqlite3.dll` beside the built `.exe` — verify the resolved `sqlite3` version in `pubspec.lock` during setup and pin explicitly if needed.

## Window Management, Settings, Packaging

### Window management: `window_manager`

Use for: fixed/min window size enforcement, custom title bar if desired, and — importantly — **intercepting the window close event** to warn the operator if a recording is currently in progress before allowing exit (a real operational safeguard the Python Tkinter app likely lacks explicitly; worth adding as a Flutter-side improvement, still within "parity + polish" scope from PROJECT.md).

### Settings persistence

**Do not use `shared_preferences`.** Recommend a hand-rolled JSON settings file (`dart:io` + `dart:convert`), placed beside the executable (mirroring `ecom-py/settings.json` next to `app_gui.py`/the frozen exe). Rationale:
- PROJECT.md requires behavior parity and operators are used to a human-readable, editable `settings.json`.
- `shared_preferences`'s Windows implementation stores data in a JSON file in a per-user AppData-style location, not beside the exe — this breaks the "settings travel with the app / are easy to inspect and back up" workflow the Python app supports.
- The deep-merge-over-defaults behavior in `settings_manager.py` is trivial to reimplement directly in Dart (recursive `Map` merge) without a dependency.

### Packaging: portable folder + Inno Setup installer (recommended), not MSIX

**Recommendation: `flutter build windows` output as a portable folder, wrapped in an Inno Setup `.exe` installer for distribution. Confidence: HIGH.**

Rationale:
- MSIX requires code-signing (a `.pfx` certificate) for any installation outside the Microsoft Store — the `msix` package's bundled test certificate is explicitly not installable/trustable outside dev machines. This project has no stated Microsoft Store distribution goal, and retail/warehouse deployment of a small internal tool is exactly the scenario where acquiring and maintaining a code-signing certificate is disproportionate overhead.
- The Python app's existing distribution model is PyInstaller `--onefile --windowed` producing a single `.exe`, run via `.bat` launchers — i.e., simple, cert-free, copy-and-run distribution to a handful of packing-station PCs. Inno Setup (or the newer `Inno Bundle` CLI wrapper) replicates this exact simplicity for Flutter's `build/windows/x64/runner/Release/` output: a self-extracting installer `.exe`, no store, no signing required for basic SmartScreen-tolerant internal use.
- `flutter build windows` alone produces a portable folder (exe + required DLLs + `data/` assets) that can also be zipped and copied directly to a machine with zero installer at all — worth keeping as the "quick internal test build" path even after an Inno Setup installer exists for the polished release.
- MSIX remains the right choice **only if** this app is ever pushed through Microsoft Store, Intune, or another MDM/enterprise deployment pipeline that specifically requires it — not indicated by anything in PROJECT.md.

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|--------------------------|
| `camera` + `camera_windows` | `camera_desktop` | If Phase 1 hardware spike shows official plugin's camera enumeration is unreliable on target machines, or if cross-desktop (Linux/macOS) reuse becomes a near-term goal |
| `camera` + `camera_windows` | Custom FFI Media Foundation plugin | Only if both above plugins fail on a hard requirement (e.g., manual exposure control proven essential) — high effort, avoid unless forced |
| `sqflite_common_ffi` | `drift` | If the app later needs reactive/streaming UI updates driven directly by DB changes, or much more complex relational queries than the current 1-2 table schema |
| Inno Setup installer + portable folder | MSIX (`msix` package) | If distributing via Microsoft Store, or an organization mandates MSIX/Intune deployment |
| Hand-rolled JSON settings | `shared_preferences` | If settings become simple, non-inspectable app-only preferences with no need to match the existing `settings.json` file location/format |
| `dart:io Process` for FFmpeg | `process_run` package | If richer process-management ergonomics (shell-like piping, better cross-platform executable resolution) are needed; not required for this project's straightforward `ffmpeg -i ... -crf ...` invocations |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|--------------|
| Building a custom C++/FFI Media Foundation capture plugin from scratch | This is precisely the kind of native-code complexity that sank the prior Qt6/C++ port attempt (per PROJECT.md); `camera_windows` already implements this correctly | `camera` + `camera_windows` (or `camera_desktop` as fallback) |
| `shared_preferences` for app settings | Stores data in an opaque per-user location, breaking the "editable settings.json beside the exe" workflow operators expect | Hand-rolled JSON file via `dart:io`/`dart:convert` |
| MSIX as the sole/default distribution format | Requires a code-signing certificate for any install outside the Microsoft Store; disproportionate for an internal packing-station tool | Portable folder + Inno Setup installer |
| `ffmpeg_cli` or other Dart FFmpeg wrapper packages | Low-adoption thin wrapper adding a dependency for what `Process.start('ffmpeg.exe', args)` already does cleanly, and the team already has working FFmpeg CLI invocations to port from `video_compressor.py` | `dart:io Process.start`/`Process.run` with the same CLI flags as the Python implementation |
| DirectShow-only camera access (raw `IGraphBuilder`/`ICaptureGraphBuilder2` FFI) | Microsoft's own guidance: DirectShow is legacy, Media Foundation is the modern recommended capture API — and it's already what `camera_windows`/`camera_desktop` use internally | `camera_windows`/`camera_desktop` (Media Foundation-based); use `win32`/DirectShow registry enumeration only as a narrow fallback for friendly-name lookups if `availableCameras()` proves incomplete |
| Bundling FFmpeg download/update logic as a Dart package dependency | No mature, current Dart package does this reliably; the Python app's own approach (external binary looked up on PATH / common install locations, install/config documented separately) is proven and simple | Keep FFmpeg as an unbundled external dependency exactly as `ecom-py` does — document install steps, optionally ship an `ffmpeg.exe` in a `tools/` folder beside the installer output |

## Stack Patterns by Variant

**If the Phase 1 camera spike passes on `camera_windows`:**
- Proceed with `camera` + `camera_windows` as the sole camera implementation.
- Because it's the official, best-documented option and avoids adding a second dependency for redundant coverage.

**If the Phase 1 camera spike fails specifically on `availableCameras()` enumeration gaps:**
- Keep `camera_windows` for preview/recording, but add `win32`/`win32_registry` DirectShow-registry enumeration purely to build the friendly-name picker list shown in Settings, then match the chosen device back to a `CameraDescription`.
- Because this isolates the one broken subsystem without discarding a working recording pipeline.

**If the Phase 1 camera spike fails on recording reliability or crashes in release builds:**
- Swap to `camera_desktop` (same `camera_platform_interface`, near-zero application code change).
- Because it's actively maintained with a more recent release cadence and may have already resolved issues present in the official plugin's current release.

**If manual exposure/gain/brightness control (used in `ecom-py/camera_handler.py`) proves to be an actual hard requirement at the packing stations (not just a nice-to-have):**
- Plan a small native FFI shim (not a full custom plugin) that calls `IAMCameraControl`/`IAMVideoProcAmp` COM interfaces via `win32`'s COM bindings, applied once at camera-open time — narrower and lower-risk than building a full replacement capture pipeline.
- Because this targets only the missing control surface rather than reimplementing preview+recording.

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|------------------|-------|
| `camera ^0.12.0+1` | `camera_windows ^0.2.6+4` | Verify `camera`'s `camera_platform_interface` version constraint matches what `camera_windows` implements at `flutter pub get` time — both current as of this research (camera: 2026-03-19, camera_windows: 2025-11-19). |
| `sqflite_common_ffi ^2.4.2` | underlying `sqlite3` (Dart package) v3.x | Confirm resolved `sqlite3` version in `pubspec.lock` is v3.0.0+ so `sqlite3.dll` is handled via build_hooks automatically; older resolved versions need manual DLL bundling for release builds. |
| Flutter stable SDK | `window_manager ^0.5.2`, `win32 ^6.3.0` | Both actively maintained against current Flutter stable (published within the last week of this research window); no known constraint conflicts. |
| `msix ^3.18.0` | N/A (not recommended as primary) | Only pull in if the packaging decision changes toward Store/MSIX distribution later. |

## Sources

- pub.dev API (`https://pub.dev/api/packages/<name>`) — live version/publish-date verification for `camera`, `camera_windows`, `camera_desktop`, `sqflite_common_ffi`, `drift`, `window_manager`, `msix`, `win32`, `win32_registry`, `file_picker`, `path_provider`, `flutter_lints`, `tray_manager`, `screen_retriever`, `bitsdojo_window`, `shared_preferences`, `hotkey_manager`, `flutter_acrylic` — HIGH confidence (direct API responses, current as of 2026-07-11)
- https://pub.dev/packages/camera_windows — changelog, limitations, feature status — HIGH confidence
- https://pub.dev/packages/camera_desktop — Windows Media Foundation backend confirmation, maturity signals — MEDIUM confidence (WebFetch-summarized, single source)
- https://github.com/flutter/flutter/issues/98404 — `availableCameras()` enumeration gap, confirmed still open — MEDIUM confidence (stale issue, 2022, but no evidence of resolution)
- https://github.com/flutter/flutter/issues/161288 — release-build camera init crash, confirmed closed/solved — MEDIUM confidence
- https://learn.microsoft.com/en-us/windows/win32/medfound/enumerating-video-capture-devices — Media Foundation as Microsoft's recommended (over DirectShow) capture API — HIGH confidence (official Microsoft docs)
- https://learn.microsoft.com/en-us/windows/win32/directshow/selecting-a-capture-device — DirectShow device enumeration via friendly names, confirms the mechanism `pygrabber`/Python app relies on — HIGH confidence (official Microsoft docs)
- https://pub.dev/packages/sqflite_common_ffi — Windows setup pattern, `sqlite3.dll` bundling behavior by version — HIGH confidence
- WebSearch: "Flutter Windows app packaging MSIX vs Inno Setup" — MSIX code-signing requirement for sideloading, Inno Setup/Inno Bundle as alternative — MEDIUM confidence (multiple community sources agree, no single official doc directly compares them)
- `.planning/PROJECT.md`, `.planning/codebase/STACK.md` — reference implementation stack and constraints — HIGH confidence (project's own source of truth)

---
*Stack research for: Flutter Windows desktop barcode-triggered video recording app*
*Researched: 2026-07-11*
