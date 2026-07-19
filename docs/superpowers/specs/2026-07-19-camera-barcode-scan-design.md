# Camera Barcode Scan Mode — Design

**Date:** 2026-07-19 · **Status:** Approved (approach chosen by user; execution delegated)

## Goal

Let the operator scan barcodes with the recording webcam itself instead of a
separate USB wedge scanner. Chosen UX (user decisions):

- **Button-armed scan**: an on-screen Scan button **and** a hotkey (F2) arm a
  short scan window; the first barcode decoded within it triggers.
- **Full parity**: an armed scan works while recording and feeds the exact
  same `processBarcode` path as the USB wedge (stop & save current video,
  start next).
- **Symbologies**: all common formats (Code 128 / Code 39 emphasized, plus
  EAN/UPC/QR etc.).

## Approach (A — native preview-frame tap)

The stock `camera_windows` plugin has no image stream, but we already vendor
it (`packages/camera_windows`, existing "ECOM PATCH"). The preview pipeline
delivers every frame to `TextureHandler::UpdateBuffer` as MFVideoFormat_RGB32
(BGRA), guarded by `buffer_mutex_` — and preview keeps running during
recording, which is what makes full parity possible.

### Components

1. **Native frame tap (C++ ECOM PATCH #2)**
   - `TextureHandler::GrabLatestFrame(out_bytes, out_w, out_h)` — copies
     `source_buffer_` + dimensions under the existing mutex. The source
     buffer is the *unmirrored* raw frame (mirroring happens only in the
     texture conversion), which is what a decoder wants.
   - `CaptureController::GetLatestPreviewFrame(...)` virtual, implemented by
     `CaptureControllerImpl` delegating to its `TextureHandler`.
   - A second, plugin-private `MethodChannel` `"ecom/camera_frame_tap"`
     (StandardMethodCodec) registered in `CameraPlugin::RegisterWithRegistrar`.
     One method: `grabFrame(cameraId)` → `{width, height, bytes (BGRA)}`,
     error `no_frame` when no preview frame exists yet. Pigeon is NOT touched.

2. **Dart frame grabber** (`lib/core/camera_frame_tap.dart`)
   - Thin `MethodChannel` wrapper: `grabFrame(cameraId) → GrabbedFrame?`
     (`bytes`, `width`, `height`). Returns null on `no_frame`/errors.

3. **Decoder** (`lib/core/barcode_decoder.dart`)
   - `zxing2` (pure-Dart ZXing port), `MultiFormatReader` with tryHarder,
     all common formats. BGRA → luminance/RGB conversion; retry with a
     90°-rotated copy so vertically-held 1D codes decode. Runs in a
     background isolate (`Isolate.run`) so UI/recording stay smooth.
     Frames wider than ~1600px are downscaled 2× before decode.

4. **Scanner service** (`lib/core/camera_barcode_scanner.dart`)
   - `arm()`: polls grab→decode every ~250 ms until first hit or the scan
     window ends (default 6 s). Publishes state (`idle`/`armed` + seconds
     remaining) via `ValueNotifier` for the UI. Re-arming while armed
     restarts the window. First decoded value disarms and fires
     `onBarcode(value)`.
   - Injectable seams (grabber, decoder, clock/interval) for unit tests —
     same style as `VideoCompressor`.

5. **UI wiring** (`main_screen.dart` / `main.dart`)
   - Scan button next to the preview; shows armed state + countdown.
   - F2 hotkey arms (registered alongside the existing HardwareKeyboard
     wedge listener; F2 produces no character so it cannot corrupt wedge
     buffering).
   - `onBarcode` calls the same `processBarcode` entry the wedge listener
     uses — zero new orchestration. Status bar shows "Scanning…", "Scanned
     <code>", or "No barcode found".

### Error handling

- No camera / preview not started → `grabFrame` errors → scanner treats as
  "no frame", keeps polling until timeout, then reports "No barcode found".
- Decode exceptions are caught per-attempt (a bad frame never kills the arm
  loop).
- The tap is read-only; it cannot affect recording. Worst case the scan
  window simply expires.

### Testing

- Unit tests (TDD): scanner service arm/timeout/hit/re-arm with fake
  grabber+decoder; decoder test with a synthesized Code 39 frame (generated
  in-test from the Code 39 pattern table) proving the BGRA→zxing pipeline
  end-to-end; frame-tap wrapper test via mock method channel.
- Native patch verified by `flutter build windows` (compile) and the
  existing `integration_test/` harness on real hardware (manual checkpoint —
  dev machine has a camera).

### Out of scope (YAGNI)

- Continuous auto-scan mode, ROI overlays, beep sounds, multi-barcode
  disambiguation, settings UI for scan window/interval (constants for now).
