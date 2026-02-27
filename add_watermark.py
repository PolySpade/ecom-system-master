"""
Two-step watermark tool:
  STEP 1 - FFmpeg rotates portrait video to horizontal (saves to_modify_horizontal.mp4)
  STEP 2 - OpenCV adds app-style watermarks and encodes final output
"""
import cv2
import subprocess
import sys
import os
import threading
from datetime import datetime, timedelta

# ── Config ────────────────────────────────────────────────────────────────────
BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
INPUT       = os.path.join(BASE_DIR, "to_modify.mp4")
HORIZONTAL  = os.path.join(BASE_DIR, "to_modify_horizontal.mp4")   # intermediate
OUTPUT      = os.path.join(BASE_DIR, "to_modify_watermarked.mp4")
FFMPEG      = os.path.join(BASE_DIR, "ffmpeg", "bin", "ffmpeg.exe")
BARCODE     = "MP1431079227"
START_TIME  = datetime(2026, 1, 26, 14, 37, 9)

# Font – matches camera_handler._add_timestamp_watermark()
FONT        = cv2.FONT_HERSHEY_SIMPLEX
FONT_SCALE  = 0.6
THICKNESS   = 2
# ─────────────────────────────────────────────────────────────────────────────


def add_watermark(frame, current_time: datetime, barcode: str):
    h, w = frame.shape[:2]

    # Timestamp – top-left, black bg, white text
    ts_text = current_time.strftime('%Y-%m-%d %H:%M:%S')
    ts_size = cv2.getTextSize(ts_text, FONT, FONT_SCALE, THICKNESS)[0]
    tx, ty  = 10, 30
    cv2.rectangle(frame, (tx-5, ty-ts_size[1]-5), (tx+ts_size[0]+5, ty+5), (0, 0, 0), -1)
    cv2.putText(frame, ts_text, (tx, ty), FONT, FONT_SCALE, (255, 255, 255), THICKNESS)

    # Barcode – bottom-left, black bg, white text
    bc_text = f"Barcode: {barcode}"
    bc_size = cv2.getTextSize(bc_text, FONT, FONT_SCALE, THICKNESS)[0]
    bx, by  = 10, h - 15
    cv2.rectangle(frame, (bx-5, by-bc_size[1]-5), (bx+bc_size[0]+5, by+5), (0, 0, 0), -1)
    cv2.putText(frame, bc_text, (bx, by), FONT, FONT_SCALE, (255, 255, 255), THICKNESS)

    return frame


# ── STEP 1: Rotate to horizontal with FFmpeg ──────────────────────────────────
def step1_rotate():
    print("=" * 60)
    print("STEP 1: Rotating portrait video to horizontal via FFmpeg")
    print("=" * 60)

    # scale=iw*sar:ih  -> apply SAR so pixels are square
    # setsar=1         -> mark pixels as square
    # transpose=1      -> rotate 90 deg clockwise
    cmd = [
        FFMPEG, "-y",
        "-i", INPUT,
        "-vf", "scale=608:1080,setsar=1,transpose=1",
        "-c:v", "libx264", "-crf", "18", "-preset", "fast",
        "-c:a", "aac", "-b:a", "128k",
        HORIZONTAL,
    ]
    print("Running:", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        print(result.stderr.decode("utf-8", errors="replace"))
        sys.exit("STEP 1 FAILED")

    size_mb = os.path.getsize(HORIZONTAL) / 1024 / 1024
    print(f"Step 1 done -> {HORIZONTAL}  ({size_mb:.1f} MB)\n")


# ── STEP 2: Add watermarks with OpenCV ────────────────────────────────────────
def step2_watermark():
    print("=" * 60)
    print("STEP 2: Adding watermarks with OpenCV")
    print("=" * 60)

    cap = cv2.VideoCapture(HORIZONTAL)
    if not cap.isOpened():
        sys.exit(f"Cannot open {HORIZONTAL}")

    fps    = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total  = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    vid_w  = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    vid_h  = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"Horizontal video: {vid_w}x{vid_h}  {fps:.2f} fps  {total} frames")
    print(f"Barcode : {BARCODE}")
    print(f"Start ts: {START_TIME}")
    print()

    # FFmpeg encodes the watermarked frames; audio copied from intermediate file
    cmd = [
        FFMPEG, "-y",
        # raw frames piped from Python
        "-f", "rawvideo", "-vcodec", "rawvideo",
        "-s", f"{vid_w}x{vid_h}", "-pix_fmt", "bgr24", "-r", str(fps),
        "-i", "pipe:0",
        # audio source
        "-i", HORIZONTAL,
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p",
        "-c:a", "copy",
        "-shortest",
        OUTPUT,
    ]

    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    # Drain FFmpeg stderr in background thread to prevent pipe deadlock
    stderr_buf = []
    def _drain():
        for line in proc.stderr:
            stderr_buf.append(line)
    drain_thread = threading.Thread(target=_drain, daemon=True)
    drain_thread.start()

    frame_num = 0
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            ts    = START_TIME + timedelta(seconds=frame_num / fps)
            frame = add_watermark(frame, ts, BARCODE)
            proc.stdin.write(frame.tobytes())

            frame_num += 1
            if frame_num % 150 == 0 or frame_num == total:
                pct = int(100 * frame_num / total) if total else 0
                print(f"  [{pct:3d}%] frame {frame_num}/{total}", flush=True)

    except BrokenPipeError:
        print("FFmpeg pipe closed early")
    finally:
        cap.release()
        proc.stdin.close()

    proc.wait()
    drain_thread.join(timeout=5)

    if proc.returncode != 0:
        print("\nFFmpeg stderr:")
        print(b"".join(stderr_buf).decode("utf-8", errors="replace"))
        sys.exit(f"STEP 2 FAILED (ffmpeg exit code {proc.returncode})")

    size_mb = os.path.getsize(OUTPUT) / 1024 / 1024
    print(f"\nStep 2 done -> {OUTPUT}  ({size_mb:.1f} MB)")


if __name__ == "__main__":
    step1_rotate()
    step2_watermark()
    print("\nAll done!")
