# Pitfalls Research

**Domain:** Flutter Windows desktop app — continuous webcam video recording + barcode-wedge input + FFmpeg compression (port of Python/OpenCV app)
**Researched:** 2026-07-11
**Confidence:** MEDIUM (camera/keyboard mechanics verified against official Flutter docs, GitHub issues, and pub.dev package docs; some Windows-desktop-specific behaviors have thin community coverage because this plugin combination is niche — flagged per-pitfall)

## Critical Pitfalls

### Pitfall 1: `camera_windows` (official plugin) cannot actually do this app's job

**What goes wrong:**
The team picks the official `camera` + `camera_windows` plugin because it's the "official" Flutter camera solution, builds the barcode-scan UI around it, and only discovers deep into implementation that critical features are missing or broken: no pause/resume of recording ("not supported due to Windows API limitations" — this is fine, the app doesn't need pause/resume, but it signals the API surface is incomplete), no image-stream support on Windows (blocks any custom frame-level processing, e.g. a live watermark/overlay equivalent to the Python app's preview overlay), no exposure/focus/flash controls (the Python app exposes camera exposure settings in its Settings dialog — parity gap), and multiple open GitHub issues of `PlatformException` on `startVideoRecording` with messages like "The data specified for this media type is invalid, inconsistent, or not supported by this object" — a Windows Media Foundation error that surfaces only with certain camera/resolution/codec combinations and is hard to reproduce without the exact hardware.

**Why it happens:**
`camera_windows` was built against Media Foundation's `CaptureEngine` API and is explicitly still described by its own maintainers as "under development." Windows desktop support was added years after the mobile/iOS implementations and has a much smaller contributor base testing against diverse webcam hardware (vs. the huge Android/iOS device matrix). Teams assume "official plugin" implies parity with mobile capabilities; it does not on Windows.

**How to avoid:**
Do not default to `camera_windows`. Evaluate `camera_desktop` (a newer, actively maintained community package implementing `camera_platform_interface` for Windows/macOS/Linux) as the primary candidate — it explicitly supports video recording with audio, custom frame rate, and bitrate control on Windows, which is closer to parity with the Python app's `cv2.VideoWriter` capabilities. Before committing, spike-test the actual target webcam hardware (the specific USB cameras used at packing stations) against both `camera_windows` and `camera_desktop` for: (a) `startVideoRecording`/`stopVideoRecording` reliability across dozens of rapid start/stop cycles (the core workflow), (b) resolution/FPS actually achieved vs. requested, (c) output file codec and playability. If both plugins fail the spike, fall back to a native FFI-based capture layer using the `win32` Dart package + hand-written Media Foundation C++ (same approach `camera_windows` itself uses internally) — this is the same order-of-magnitude effort as continuing to fight plugin bugs, so budget for it as a real possibility, not a last resort.

**Warning signs:**
- Spike test shows `PlatformException` on any of the target camera models during start/stop cycling
- Resolution/FPS settings from `CameraController` don't match what's actually written to the output file
- No way to read back "is a frame currently being written" state needed for the saving-progress dialog parity feature

**Phase to address:**
Phase 1 (foundation/spike) — before any UI is built. This is the single highest-risk unknown in the whole port and must be resolved with a working end-to-end record-and-save proof-of-concept before committing to a camera library.

---

### Pitfall 2: Codec/container mismatch breaks video parity and searchability

**What goes wrong:**
The Python app uses OpenCV's `cv2.VideoWriter` with a configurable FOURCC codec (commonly `mp4v` or `avc1`/H264 depending on settings) writing directly to `.mp4`. On the Flutter/Windows side, both `camera_windows` and `camera_desktop` go through Windows Media Foundation's `CaptureEngine`/sink writer, which has its own codec negotiation that does not necessarily match OpenCV's FOURCC output — different container metadata, different H.264 profile/level, or (if no certified hardware H.264 encoder is present) a fallback to a software encoder with different performance characteristics. The result: files that don't play in the same players, don't have the same size/quality tradeoff the operators are used to, or — worse — FFmpeg post-compression (which is kept for parity) chokes on an unexpected input codec/container combination and silently produces a bad or skipped compression job.

**Why it happens:**
"It's still an MP4" is a false equivalence. OpenCV on Windows typically uses the MSMF backend with FOURCC codes that map to specific Media Foundation transforms; Media Foundation's `CaptureEngine` (used by the Flutter plugins) picks its own encoder based on what's registered on the machine, preferring a certified hardware encoder if present. H.264 is natively available inbox on Windows via Media Foundation, but exact encoder behavior (bitrate control, keyframe interval, container muxing) differs from OpenCV's writer defaults.

**How to avoid:**
During the Phase 1 spike, record a test video with the Flutter capture path and run it through the exact FFmpeg compression command the Python app uses (`ecom-py/video_compressor.py`) unmodified. Confirm: output plays in the same players used in production, `ffprobe` reports a codec/profile the team is prepared to support long-term, and file sizes are in the same ballpark as the Python app's output for equivalent settings. If codec mismatch surfaces, standardize explicitly (e.g., force H.264 via FFmpeg re-encode immediately after capture rather than relying on the capture codec) rather than accepting whatever Media Foundation defaults to.

**Warning signs:**
- `ffprobe` on Flutter-captured files shows a different codec/profile than Python-captured files
- FFmpeg compression step throws errors or produces 0-byte/corrupt output on Flutter-captured input
- Video files play in VLC but not in the lightweight in-app player, or vice versa

**Phase to address:**
Phase 1 (foundation/spike), verified again in the compression-integration phase.

---

### Pitfall 3: Keyboard-wedge barcode scans get silently swallowed or duplicated depending on focus

**What goes wrong:**
Barcode scanners act as fast synthetic keyboard input (each character as a keydown/keyup, terminated by Enter). Flutter's *current* key-event API, `HardwareKeyboard`/`KeyEvent` (which replaced the deprecated `RawKeyboard`/`RawKeyEvent` system), only reliably delivers events to handlers when a focus node is focused and part of the active focus chain — `HardwareKeyboard.addHandler` is documented to be affected by this focus dependency, meaning a scan performed while the user's cursor is in a text field, a dialog is open, or literally nothing in the app has focus can be dropped entirely or partially captured (some characters land in a TextField, others get lost). This is exactly the failure mode most damaging to this app's core workflow: a missed or garbled scan means a video never stops/starts correctly.

**Why it happens:**
Flutter migrated away from `RawKeyboard`/`RawKeyboardListener` (deprecated, being removed) to `HardwareKeyboard`/`KeyboardListener`/`Focus.onKeyEvent`. The new system is architected around focus-scoped delivery for correctness in normal UI interaction, but that design assumption breaks for "global hotkey"-style needs like a keyboard-wedge scanner, where input must be captured regardless of which widget currently has focus (search dialog open, settings dialog open, or no explicit focus at all).

**How to avoid:**
Do not rely on a single focused `TextField` "catcher" pattern (a common but fragile trick from the JS/web barcode-scanner world). Instead: (1) install a top-level `HardwareKeyboard.instance.addHandler` in the app's root/bootstrap (not tied to any particular screen's focus), so raw key events are captured application-wide independent of what has focus; (2) buffer characters with a short inter-key timeout (barcode scanners send characters at machine speed, much faster than human typing — typically <30-50ms between characters) and flush/reset the buffer on `Enter` or on timeout, exactly mirroring the debounce logic already proven in `ecom-py/barcode_handler.py`; (3) explicitly test scanning while a modal dialog (Settings, Search) is open, since Flutter's focus traversal changes when a dialog is shown and could route/consume events differently than the main screen; (4) test scanning immediately after app launch before the user has clicked anything (no focus established yet). Confirm the handler is removed/disposed correctly on hot-reload/rebuild to avoid duplicate handlers double-processing every scan (a documented class of bug with `addHandler`).

**Warning signs:**
- Scans work fine on the main screen but drop/garble when a dialog is open
- Occasional single missing character at the start or end of a scanned barcode (classic sign of focus-transition race)
- Duplicate barcode processing after hot reload during development (leftover handler not removed)
- Works during manual testing (slow typing) but fails with the real scanner hardware (fast synthetic input) — always test with actual scanner hardware, not keyboard simulation

**Phase to address:**
Phase 2 (core recording workflow) — this is core-value-critical per PROJECT.md ("every scanned barcode reliably stops... and starts... without missing frames or losing videos"). Should have a dedicated verification step: scripted rapid-fire scan test (real hardware) across all screens/dialog states before the phase is considered done.

---

### Pitfall 4: Long-running recording session memory/handle growth goes undetected until a multi-hour kiosk shift

**What goes wrong:**
The app is meant to run unattended for full packing-station shifts, continuously previewing + repeatedly starting/stopping recordings on every scan. Flutter's `Texture`-based camera preview pipeline (how `camera_windows`/`camera_desktop` push native frames to the Dart UI layer) has a documented history of leaks elsewhere in the Flutter ecosystem when textures are registered/unregistered repeatedly (seen on other platforms' texture implementations); the concern is directly relevant here because every stop/start cycle on this app could plausibly re-touch the texture/surface lifecycle, not just a one-time registration at app start. Combined with FFmpeg being spawned as a new OS process per compression job (proven pattern in the Python app, kept for parity) and repeated `Process.start` calls in Dart, a session that runs for 8+ hours with dozens/hundreds of scan cycles is exactly the stress profile that surfaces slow leaks demos never catch.

**Why it happens:**
Short manual QA sessions (a few minutes, a handful of scans) never accumulate enough repetitions to notice a few-MB-per-cycle leak. It only becomes visible as OS-level memory/handle growth over hours, by which point it looks like "random slowdown" rather than a specific bug, and reproducing it requires actually running the app for hours — something devs rarely do until a field report comes in.

**How to avoid:**
Build an automated or semi-automated long-run soak test as part of the recording-pipeline phase: script hundreds of scan-simulated stop/start cycles in a loop (can drive via the same keyboard-wedge handler with synthetic key events, or a debug-only "simulate scan" button) and monitor Windows Task Manager / Process Explorer for the app's working set, handle count, and GDI/USER object count over that run — not just Dart heap via DevTools (native Windows handles/textures won't show up in the Dart memory profiler at all). Also explicitly verify FFmpeg child processes are fully reaped (no zombie/orphaned `ffmpeg.exe` processes accumulating in Task Manager) after each compression job, matching a concern already flagged in the Python reference (`CONCERNS.md`: FFmpeg processes run serially via a queue — replicate that serialization, don't parallelize compression jobs without an explicit process-count cap).

**Warning signs:**
- Working-set memory or handle count in Task Manager climbs monotonically over a multi-hour soak run and never plateaus
- Frame drops or preview stutter appear only after dozens of scan cycles, not at app start
- `ffmpeg.exe` processes visible in Task Manager after their jobs should have completed

**Phase to address:**
Phase 2/3 (recording pipeline + compression integration) for building the soak-test harness; treat "passes an N-hour soak test with flat memory" as an explicit exit criterion before calling the recording pipeline done, not an afterthought.

---

### Pitfall 5: UI-thread stalls during compression/DB work drop frames or delay barcode processing

**What goes wrong:**
Flutter's rendering and platform-channel dispatch (including the camera texture updates and, more importantly, keyboard event delivery for the barcode wedge) run on/through the main isolate. If barcode processing, database writes, or file operations (e.g., checking file existence, moving files into `YYYY-MM-DD` folders) are done synchronously on that isolate — a very natural thing to do since it's "just SQLite, it's fast" — a slow disk I/O moment (the exact "slow storage" scenario already flagged in `CONCERNS.md` for the Python app's `stop_and_start` race) can stall the isolate long enough to miss or delay a keyboard event, which for a keyboard-wedge scanner reading at machine speed can mean losing characters mid-scan.

**Why it happens:**
Dart's single-isolate-by-default model makes it easy to write everything inline without thinking about it, and SQLite operations look instant in dev testing on a fast NVMe dev machine — the failure mode only appears on slower kiosk-station storage or under disk contention (which is precisely the condition the Python `CONCERNS.md` document already flags as a known risk area to not repeat).

**How to avoid:**
Use `sqflite_common_ffi`'s isolate-backed factory (`databaseFactoryFfi`, which is isolate-based by default, not `databaseFactoryFfiNoIsolate`) so DB operations don't block the main isolate. Keep file-system operations (move/copy video files, existence checks) off the main isolate too, via `compute()` or a dedicated worker isolate, especially the file finalization step that runs right when a new scan arrives and the previous recording must be closed out. Treat the barcode-scan-to-recording-transition path as latency-critical and audit every `await` in that path for anything that could block on disk/DB under load.

**Warning signs:**
- Barcode scans missed/garbled specifically under simulated slow-disk conditions (test by pointing storage path at a slow USB drive or network share, matching a scenario already flagged in the Python app)
- Preview frame rate visibly drops right at the moment of a scan (should be constant regardless of scan events)

**Phase to address:**
Phase 2 (core recording workflow) — the isolate/threading model for DB and file I/O should be decided architecturally at the start of this phase, not retrofitted later.

---

### Pitfall 6: Destructive video file replacement during compression (repeating a known Python-app bug)

**What goes wrong:**
`CONCERNS.md` already documents this exact bug in the Python reference app: `video_compressor.py` does `os.remove(original)` then `os.rename(compressed, original)` — if the process is killed or crashes between those two lines (power loss, forced termination — realistic on an unattended kiosk PC), the original video is permanently deleted and the compressed replacement never lands. PROJECT.md explicitly calls out that the port should fix this ("compress to temp file and atomically swap instead"), but it is easy for a from-scratch Flutter implementation to reintroduce the identical bug independently, since "delete old, rename new" is the naive/obvious way to write this logic in Dart too.

**Why it happens:**
It's the most direct translation of the intent ("replace this file with the compressed version") and the two-step delete-then-rename pattern isn't obviously wrong until you think through the crash-between-lines case — exactly the trap that caught the original implementation.

**How to avoid:**
Use `File.rename()` (or platform `MoveFileEx`/`ReplaceFile` semantics via a package that supports atomic replace) to swap the compressed output into the original's path in a single atomic operation, with no intermediate delete step — Dart's `File.rename()` on the same volume is backed by the OS rename call and is atomic on Windows/NTFS when source and destination are on the same volume. Never call `File.delete()` on the original before the replacement file is confirmed fully written and closed (flushed) at its temp path.

**Warning signs:**
- Code review finds any sequence of `delete()` followed by `rename()`/`copy()` in the compression finalize step
- Testing compression finalize under a simulated kill (e.g., force-kill the app mid-compression in a test run) results in a missing video with no compressed replacement

**Phase to address:**
Phase 3 (compression integration) — explicit code-review gate against this exact anti-pattern, since it is a known, named, previously-occurring bug in the same codebase family.

---

### Pitfall 7: FFmpeg bundling/discovery breaks silently in release builds (and priority isn't set, competing with the camera capture thread)

**What goes wrong:**
Two related traps: (1) FFmpeg is an external runtime dependency in the Python app already, with documented soft-fail behavior (`CONCERNS.md`: if FFmpeg is missing, compression is silently skipped with no hard user-facing error) — a Flutter rewrite that doesn't deliberately fix this will likely reproduce the same silent-skip UX gap, and additionally must decide bundling strategy (ship `ffmpeg.exe` alongside the Flutter build output vs. relying on a system PATH install) since Flutter's Windows build output is a plain folder of files, not something with an installer-managed dependency system by default; (2) FFmpeg run at default process priority competes for CPU with the live camera capture/encode path during simultaneous record+compress, causing dropped frames on the video currently being recorded — this exact tradeoff is why the Python app deliberately serializes compression to a single background worker thread rather than running compression jobs in parallel.

**Why it happens:**
Dart's `Process.start` doesn't expose a first-class "set process priority class" parameter the way Win32 `CreateProcess` does with flags like `BELOW_NORMAL_PRIORITY_CLASS`; achieving lowered priority on Windows requires either shelling out through a wrapper (e.g., `start /belownormal ffmpeg.exe ...` via `cmd.exe`, matching what a search of Windows tooling forums recommends), calling `SetPriorityClass` via Win32 FFI (`win32` package) against the spawned process's handle, or accepting default priority and relying on serialization alone (as the Python app does) to bound the CPU-contention risk. Teams that don't know this often just spawn FFmpeg at default priority and rely purely on "it's fast enough on my dev machine."

**How to avoid:**
Bundle `ffmpeg.exe` inside the app's own installation folder (next to the built `.exe`, e.g. a `ffmpeg/` subfolder shipped via the build/packaging step) and resolve its path relative to `Platform.resolvedExecutable`, not a hardcoded absolute path or bare PATH lookup — this avoids the "works on dev machine, missing on a fresh kiosk PC" class of failure the Python app already has search-multiple-hardcoded-paths logic to work around. Fail loudly (persistent UI banner, not just a status label) if the bundled binary is missing at startup, rather than silently skipping compression — an explicit fix over the Python app's documented soft-fail gap. For priority, replicate the Python app's serialized single-worker-queue approach as the primary defense (proven in production), and additionally set `BELOW_NORMAL_PRIORITY_CLASS` on the spawned FFmpeg process via `win32` FFI (`CreateProcess`/`SetPriorityClass`) if frame drops are observed during simultaneous record+compress in testing.

**Warning signs:**
- App works on the dev machine but compression silently never runs on a clean test VM/fresh install (FFmpeg path resolution failure)
- Recording frame drops or preview stutter specifically correlate with a compression job actively running in the background
- No visible warning anywhere in the UI when FFmpeg is missing — user only discovers it when noticing videos aren't shrinking, days later

**Phase to address:**
Phase 3 (compression integration) for bundling/path-resolution and the fail-loud UX; verify the CPU-priority mitigation during the same soak test used for Pitfall 4.

---

### Pitfall 8: MSIX packaging breaks or complicates access to the configured video storage folder

**What goes wrong:**
If the team later chooses MSIX for distribution (a natural choice given `msix` is the standard pub.dev package for Flutter Windows packaging), classic desktop apps packaged as MSIX are *not* fully sandboxed like UWP apps and retain real file-system access — but MSIX still virtualizes `AppData` writes (redirected to a private per-package `LocalCache` location) and the package's own install directory is read-only at runtime. If any part of the app's default settings/config storage naively assumes it can write next to the `.exe` (a pattern that works fine for the current unpackaged debug/release build) or assumes an unvirtualized `%LOCALAPPDATA%` path, behavior will silently differ between an MSIX-installed copy and a plain zipped/portable build — and QA done only against the unpackaged build won't catch it.

**Why it happens:**
MSIX's file-system behavior ("looks like real AppData, actually private copy-on-write per app") is intentionally transparent to naive code, so it "just works" for typical AppData reads/writes without anyone realizing virtualization is happening — until something inspects the file from outside the package context (e.g., an admin browsing `%LOCALAPPDATA%` directly, or another tool trying to read the same settings file) and can't find it where expected. Additionally, since this app's `video_path`/`storage.video_path` (per `PROJECT.md`) is user-configurable and likely points at a Documents/D:\ drive location outside the package — which does work fine under MSIX since non-package/non-AppData locations aren't virtualized — the risk is specifically in *default* paths and *settings file* discovery logic, not user-chosen video storage locations.

**How to avoid:**
Decide distribution format early (MSIX vs. plain portable zip/installer via something like Inno Setup) rather than defaulting to MSIX without evaluating tradeoffs — a plain unpackaged build avoids this entire class of gotcha and matches the Python app's current distribution model (a folder you copy/run, no installer sandboxing concerns) which may be the pragmatic parity choice for a kiosk-style deployment. If MSIX is chosen, explicitly resolve config/database default paths via Windows' actual known-folder APIs (e.g., `path_provider`'s `getApplicationSupportDirectory()`) rather than a path computed relative to the executable, and test the installed (not just debug-run) MSIX package against real disk read/write for both default paths and a user-configured external video folder.

**Warning signs:**
- Settings/database file can't be found by an admin browsing the expected `%LOCALAPPDATA%\<AppName>` path after installing via MSIX (it's actually under `AppData\Local\Packages\<PackageFamilyName>\LocalCache`)
- App behaves correctly when run from the build output folder but fails to persist settings after MSIX install
- Video files saved to a default (non-user-configured) path aren't visible to other tools expecting them at the "real" AppData location

**Phase to address:**
Whichever phase handles distribution/packaging (typically a late phase) — but the *path-resolution architecture decision* (use `path_provider`, never hardcode relative-to-exe paths for config/DB) should be made in Phase 1 so it doesn't require rework later regardless of eventual packaging choice.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|-----------------|------------------|
| Use `camera_windows` (official) without spike-testing target hardware first | Feels like the "supported" path, less initial research | Discover mid-build that recording is unreliable on target webcams, forcing a plugin swap after UI is already built around it | Never — always spike first (Pitfall 1) |
| Single focused-widget keystroke catcher for barcode input (web-style trick) | Simple, works in demos | Breaks the moment a dialog opens or nothing has focus — exactly the core-value workflow | Never for this app; acceptable only for throwaway prototypes |
| Run FFmpeg compression jobs in parallel for speed | Faster backlog clearing on multi-core kiosk PCs | CPU contention with live recording causes frame drops; the Python app deliberately avoided this | Only after the soak test proves no frame-drop impact, and only with an explicit CPU-budget cap |
| Write settings/DB files relative to the executable path | Simple, works in unpackaged dev/release builds | Breaks under MSIX packaging and complicates future portable-vs-installed distribution flexibility | Acceptable only if MSIX/installer packaging is permanently ruled out |
| Rely on default SQLite journal mode (no WAL) since it's "just single-user desktop" | No extra setup | If GUI and any future secondary process (e.g., a debug tool, or a revived web view) ever open the DB concurrently, same `database is locked` risk the Python app already has | Acceptable for v1 single-process desktop use; revisit if any second consumer of the DB is added |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|-----------------|-------------------|
| `camera_windows` / `camera_desktop` | Assuming feature parity with mobile `camera` plugin (exposure, image streaming, pause/resume) | Explicitly inventory which Settings-dialog camera controls from the Python app are actually exposed by the chosen plugin before committing to full parity claims; some (exposure control) may need to be dropped or done via a native FFI fallback |
| `sqflite_common_ffi` | Using `sqfliteFfiInit()`/`databaseFactoryFfi` in debug only, forgetting `sqlite3.dll` must ship alongside the release `.exe` | Confirm `sqlite3.dll` is present next to the built executable in the actual release build output (not just `flutter run`), and add this to a release-build smoke-test checklist |
| FFmpeg (bundled binary) | Hardcoding an absolute dev-machine path or relying on system PATH | Resolve path relative to `Platform.resolvedExecutable`, ship the binary inside the app's own output folder, fail loudly if missing |
| Barcode scanner (keyboard wedge) | Testing input handling only via manual keyboard typing, not real scanner hardware | Always validate with the actual USB scanner hardware at full scan speed — synthetic fast keystroke timing is part of the bug surface (inter-key debounce/timeout logic) |
| MSIX packaging (`msix` package) | Defaulting to MSIX without checking AppData virtualization impact on config/DB file discovery | Decide packaging format deliberately; if MSIX, use `path_provider` for all default storage paths, never relative-to-exe |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|-----------------|
| Synchronous DB/file I/O on the main isolate in the scan-to-recording-transition path | Preview stutter or dropped scan characters right at the moment of a scan | Use isolate-backed `databaseFactoryFfi` and offload file finalization to `compute()`/a worker isolate | Under slow storage (USB/network share) or during compression contention — matches an already-flagged Python-app risk |
| Repeated texture registration/unregistration on every recording start/stop cycle | Slow memory/handle growth over a multi-hour session, not visible in short test runs | Soak-test with hundreds of simulated scan cycles, monitor native handle/working-set counts in Task Manager, not just Dart heap | Becomes visible only after dozens-to-hundreds of stop/start cycles — i.e., after a real shift-length session |
| Parallel FFmpeg compression jobs | Frame drops in the currently-recording video whenever a compression backlog is being cleared | Keep single-worker serialized compression queue (parity with Python app); cap concurrency explicitly if ever increased | Breaks as soon as more than one compression job runs concurrently with active recording on a CPU-constrained kiosk PC |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Carrying forward the Python app's unauthenticated local surface if any network/API layer is ever added to the Flutter app | Out of scope per PROJECT.md (no web interface planned), but if a future milestone adds any local server/API for automation, it would inherit the same unauthenticated-by-default risk documented in `CONCERNS.md` | If any network-facing surface is ever added, bind to localhost by default and require explicit opt-in + auth for wider exposure, same recommendation already given for the Python app |
| Storing FFmpeg/compression settings or camera credentials (if any) in a plain file without validating it's excluded from version control | Accidental commit of local machine-specific settings | Mirror the Python app's `.gitignore` pattern for `settings.json`-equivalent config, database file, and video output folder in the new `ecom-flutter/` project |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|--------------|-------------------|
| Silent FFmpeg-missing skip (Python app's current behavior) carried into the Flutter port | Storage fills up faster than expected with nobody noticing compression stopped working | Persistent, hard-to-dismiss banner/indicator when FFmpeg isn't found at startup, not just a status label |
| No feedback during the brief video-finalization moment between "scan received" and "new recording started" | Operator scans next barcode before previous save fully completes, unsure if it worked | Keep parity with the Python app's `SavingProgressDialog` pattern; make sure it can't be skipped/raced if scans arrive very close together |
| Assuming the recording indicator / preview frame rate stays visually smooth during a background compression job | Operator perceives the app as "frozen" or laggy mid-shift, loses trust in the tool | Explicit soak/perf testing of preview smoothness during active compression, not just during idle |

## "Looks Done But Isn't" Checklist

- [ ] **Camera recording:** Often "works" in a 2-minute demo — verify with a real multi-hour soak test of repeated start/stop cycles on the actual target webcam hardware, not just the dev machine's built-in camera
- [ ] **Barcode scan handling:** Often tested only via manual keyboard typing — verify with the real USB scanner hardware at full speed, and specifically while a Settings/Search dialog is open and while nothing has focus
- [ ] **Video codec parity:** Often assumed "it's an MP4, it's fine" — verify with `ffprobe` that codec/profile/container match expectations and that the existing FFmpeg compression command works unmodified against Flutter-captured output
- [ ] **Atomic file replacement in compression:** Often reimplemented as delete-then-rename by accident — verify via code review and a simulated mid-operation kill test that no delete happens before the replacement is fully written
- [ ] **FFmpeg bundling:** Often works because it happens to be installed on the dev machine's PATH — verify on a clean VM/fresh Windows install with nothing but the built app folder
- [ ] **SQLite release build:** Often works in `flutter run` (debug) but missing `sqlite3.dll` in the actual release output folder — verify by running the built release `.exe` from a fresh folder with nothing else present
- [ ] **Settings/DB storage paths:** Often relative-to-exe, works unpackaged — verify explicitly if/when MSIX packaging is introduced

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|----------------|------------------|
| Chosen camera plugin proves unreliable after significant UI work is built around it | HIGH | Isolate camera/recording logic behind a clean interface/abstraction from day one (Phase 1) specifically so the underlying plugin can be swapped (or replaced with a native FFI implementation) without rewriting UI/business logic |
| Barcode focus-handling bug ships to production and drops scans intermittently | MEDIUM | Add scan-attempt/scan-success logging (timestamp + raw buffer) from day one so field issues can be diagnosed from logs rather than reproduced blind; ship a hotfix build with the top-level `HardwareKeyboard` handler fix |
| Delete-then-rename data-loss bug reintroduced in compression finalize | MEDIUM | Since originals are deleted before the swap, recovery is only possible from the not-yet-deleted `temp` compressed file if the crash happened before delete; add a recovery scan on startup that looks for orphaned temp/compressed files with no corresponding original and offers to restore them |
| Memory/handle leak discovered only after production deployment | MEDIUM | Instrument with a lightweight periodic health-check log (memory/handle counts) from v1 so a field report of "app gets slow after a few hours" can be correlated with actual growth data instead of guessed at |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|--------------------|----------------|
| Camera plugin can't reliably do the job (Pitfall 1) | Phase 1 (foundation spike) | End-to-end record/stop/save proof-of-concept on real target hardware before UI work begins; document plugin choice with evidence |
| Codec/container mismatch breaks compression (Pitfall 2) | Phase 1 spike, re-verified in compression phase | `ffprobe` comparison of Flutter-captured vs. Python-captured output; existing FFmpeg command runs unmodified |
| Barcode scans dropped due to focus (Pitfall 3) | Phase 2 (core recording workflow) | Scripted rapid-fire real-hardware scan test across all screens/dialog states |
| Long-run memory/handle growth (Pitfall 4) | Phase 2/3 (recording + compression pipeline) | Multi-hour soak test with hundreds of simulated scan cycles; flat memory/handle count is an explicit exit criterion |
| Main-isolate stalls drop scan input (Pitfall 5) | Phase 2 (core recording workflow) | Simulated slow-disk test (network share/slow USB) confirms no dropped/garbled scans |
| Delete-then-rename data loss in compression (Pitfall 6) | Phase 3 (compression integration) | Code review gate + simulated kill-mid-compression test confirms no original-file loss |
| FFmpeg bundling/priority issues (Pitfall 7) | Phase 3 (compression integration) | Clean-VM test confirms bundled FFmpeg resolves correctly; soak test confirms no frame drops during concurrent record+compress |
| MSIX packaging breaks storage paths (Pitfall 8) | Phase 1 (path-resolution architecture) + packaging/distribution phase | Installed MSIX package (not just debug run) tested for default and user-configured storage path read/write |

## Sources

- [camera_windows | Flutter package (pub.dev)](https://pub.dev/packages/camera_windows) — MEDIUM confidence (official package docs, but package self-describes as "under development")
- [camera_desktop | Flutter package (pub.dev)](https://pub.dev/packages/camera_desktop) — MEDIUM confidence (official package docs; newer/less battle-tested than camera_windows but more feature-complete for Windows recording)
- [camera | Flutter package (pub.dev)](https://pub.dev/packages/camera) — HIGH confidence (official Flutter camera plugin interface docs)
- [flutter/flutter#141847 — camera_windows startVideoRecording PlatformException](https://github.com/flutter/flutter/issues/141847) — MEDIUM confidence (specific reported bug, hardware-dependent)
- [flutter/flutter#107302 — camera_windows can't find cameras](https://github.com/flutter/flutter/issues/107302) — MEDIUM confidence (reported issue, illustrates hardware-detection fragility)
- [Migrate RawKeyEvent/RawKeyboard to KeyEvent/HardwareKeyboard — Flutter official breaking-change doc](https://docs.flutter.dev/release/breaking-changes/key-event-migration) — HIGH confidence (official Flutter documentation)
- [HardwareKeyboard class — Flutter API docs](https://api.flutter.dev/flutter/services/HardwareKeyboard-class.html) — HIGH confidence (official API reference)
- [flutter/flutter#154141 — Global Key Event Listening / Impact of RawKeyboard Deprecation](https://github.com/flutter/flutter/issues/154141) — MEDIUM confidence (open issue confirming focus-dependency concern for global listeners)
- [flutter/flutter#79849 — Flutter Windows Keyboard Issue using external barcode scanner](https://github.com/flutter/flutter/issues/79849) — MEDIUM confidence (directly on-topic historical issue)
- [sqflite_common_ffi | Dart package (pub.dev)](https://pub.dev/packages/sqflite_common_ffi) — HIGH confidence (official package docs)
- [tekartik/sqflite#574 — strange behavior deploying Windows app with sqflite_common_ffi](https://github.com/tekartik/sqflite/issues/574) — MEDIUM confidence (community-reported release-build DLL issue)
- [Using Windows Media Foundation to encode h264 — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/1060279/using-windows-media-foundation-to-encode-h264-(lic) — MEDIUM confidence (Microsoft forum, not formal docs, but consistent with official MF documentation on inbox H.264 support)
- [MicrosoftDocs/win32 — H.264 Video Encoder MFT docs](https://github.com/MicrosoftDocs/win32/blob/docs/desktop-src/medfound/h-264-video-encoder.md) — HIGH confidence (official Microsoft documentation source)
- [Building Windows apps with Flutter — official docs](https://docs.flutter.dev/platform-integration/windows/building) — HIGH confidence
- [msix | Dart package (pub.dev)](https://pub.dev/packages/msix) — HIGH confidence (official package docs)
- [Understanding how packaged desktop apps run on Windows — Microsoft Learn (MSIX)](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes) — HIGH confidence (official Microsoft documentation)
- Project-internal: `.planning/codebase/CONCERNS.md` — HIGH confidence (direct audit of the reference implementation this project ports; source of the delete-then-rename, FFmpeg soft-fail, slow-disk race, and no-WAL-mode known issues)
- `flutter run`/`camera` plugin general leak reports (flutter/flutter#60409, #140503) — LOW confidence (mobile-platform-specific reports, cited only as directional evidence that texture lifecycle leaks are a real category of bug in this plugin family, not confirmed on Windows specifically)

---
*Pitfalls research for: Flutter Windows desktop camera/video recording app (Ecom Video Tracker port)*
*Researched: 2026-07-11*
