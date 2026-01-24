import cv2
import logging
import threading
import time
import os
import platform
from datetime import datetime
from typing import Optional
import config

logger = logging.getLogger(__name__)

# Suppress OpenCV MSMF warnings on Windows
os.environ["OPENCV_VIDEOIO_PRIORITY_MSMF"] = "0"


class CameraHandler:
    def __init__(self):
        self.camera = None
        self.recording = False
        self.video_writer = None
        self.current_filename = None
        self.recording_start_time = None
        self.lock = threading.Lock()
        self.frame = None
        self.current_label = None
        self.current_barcode = None
        self.current_label_folder = None
        self.frame_count = 0
        self.initialize_camera()

    def initialize_camera(self):
        """Initialize the camera."""
        try:
            # Use DirectShow on Windows to avoid MSMF errors
            # DirectShow is more stable and compatible with virtual cameras
            if platform.system() == 'Windows':
                self.camera = cv2.VideoCapture(config.CAMERA_INDEX, cv2.CAP_DSHOW)
                logger.info(f"Initializing camera {config.CAMERA_INDEX} with DirectShow backend")
            else:
                self.camera = cv2.VideoCapture(config.CAMERA_INDEX)
                logger.info(f"Initializing camera {config.CAMERA_INDEX} with default backend")

            if not self.camera.isOpened():
                raise Exception(f"Could not open camera at index {config.CAMERA_INDEX}")

            # Set camera resolution
            self.camera.set(cv2.CAP_PROP_FRAME_WIDTH, config.VIDEO_RESOLUTION[0])
            self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, config.VIDEO_RESOLUTION[1])

            # Set FPS
            self.camera.set(cv2.CAP_PROP_FPS, config.VIDEO_FPS)

            # Warm up camera
            time.sleep(config.CAMERA_WARMUP_TIME)

            # Verify camera is working by grabbing a test frame
            ret, frame = self.camera.read()
            if not ret or frame is None:
                logger.warning("Camera opened but cannot read frames")

            logger.info(f"Camera initialized successfully (Resolution: {config.VIDEO_RESOLUTION}, FPS: {config.VIDEO_FPS})")
        except Exception as e:
            logger.error(f"Error initializing camera: {e}")
            raise

    def get_frame(self):
        """Get the current frame from the camera."""
        with self.lock:
            if self.camera is None or not self.camera.isOpened():
                return None

            success, frame = self.camera.read()
            if success:
                self.frame = frame
                return frame
            return None

    def generate_frames(self):
        """Generator function for streaming frames to the web UI."""
        while True:
            frame = self.get_frame()
            if frame is None:
                continue

            # Encode frame as JPEG
            ret, buffer = cv2.imencode('.jpg', frame)
            if not ret:
                continue

            frame_bytes = buffer.tobytes()
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')

    def _get_label_folder_name(self, label: str) -> str:
        """Convert label to folder name."""
        label_folder_map = {
            "Return and Refund Unboxing": "Return and Refund",
            "Return Parcel Unboxing": "Return Parcel",
            "Normal (Standard)": "Normal"
        }
        return label_folder_map.get(label, "Normal")

    def start_recording(self, barcode: str, label: str = "Normal (Standard)") -> str:
        """
        Start recording video.

        Args:
            barcode: The barcode that triggered the recording
            label: The video label/category

        Returns:
            The filename of the video being recorded
        """
        with self.lock:
            if self.recording:
                raise Exception("Already recording")

            try:
                # Create date folder and label subfolder if they don't exist
                date_folder = datetime.now().strftime('%Y-%m-%d')
                label_folder = self._get_label_folder_name(label)
                video_folder = os.path.join(config.VIDEO_STORAGE_PATH, date_folder, label_folder)
                os.makedirs(video_folder, exist_ok=True)

                # Generate filename
                timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                self.current_filename = f"{timestamp}_{barcode}.mp4"
                video_path = os.path.join(video_folder, self.current_filename)

                # Store current label and barcode for watermark
                self.current_label = label
                self.current_barcode = barcode
                self.current_label_folder = label_folder
                self.frame_count = 0

                # Initialize video writer
                fourcc = cv2.VideoWriter_fourcc(*config.VIDEO_CODEC)
                self.video_writer = cv2.VideoWriter(
                    video_path,
                    fourcc,
                    config.VIDEO_FPS,
                    config.VIDEO_RESOLUTION
                )

                if not self.video_writer.isOpened():
                    raise Exception("Could not open video writer")

                self.recording = True
                self.recording_start_time = time.time()

                # Start recording thread
                self.recording_thread = threading.Thread(target=self._record_frames)
                self.recording_thread.start()

                logger.info(f"Started recording: {self.current_filename} (Label: {label})")
                return self.current_filename

            except Exception as e:
                logger.error(f"Error starting recording: {e}")
                self.recording = False
                self.video_writer = None
                raise

    def _add_timestamp_watermark(self, frame):
        """Add timestamp and label watermark to frame."""
        # Get current timestamp
        timestamp_text = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        # Get frame dimensions
        height, width = frame.shape[:2]

        # Font settings
        font = cv2.FONT_HERSHEY_SIMPLEX
        font_scale = 0.6
        thickness = 2

        # Add semi-transparent background for better readability
        # Timestamp at top-left
        ts_text_size = cv2.getTextSize(timestamp_text, font, font_scale, thickness)[0]
        ts_x, ts_y = 10, 30
        cv2.rectangle(frame, (ts_x - 5, ts_y - ts_text_size[1] - 5),
                     (ts_x + ts_text_size[0] + 5, ts_y + 5), (0, 0, 0), -1)
        cv2.putText(frame, timestamp_text, (ts_x, ts_y), font, font_scale, (255, 255, 255), thickness)

        # Label at top-right
        if self.current_label:
            label_text = self.current_label
            label_text_size = cv2.getTextSize(label_text, font, font_scale, thickness)[0]
            label_x = width - label_text_size[0] - 15
            label_y = 30
            cv2.rectangle(frame, (label_x - 5, label_y - label_text_size[1] - 5),
                         (label_x + label_text_size[0] + 5, label_y + 5), (102, 126, 234), -1)
            cv2.putText(frame, label_text, (label_x, label_y), font, font_scale, (255, 255, 255), thickness)

        # Barcode at bottom-left
        if self.current_barcode:
            barcode_text = f"Barcode: {self.current_barcode}"
            barcode_text_size = cv2.getTextSize(barcode_text, font, font_scale, thickness)[0]
            barcode_x = 10
            barcode_y = height - 15
            cv2.rectangle(frame, (barcode_x - 5, barcode_y - barcode_text_size[1] - 5),
                         (barcode_x + barcode_text_size[0] + 5, barcode_y + 5), (0, 0, 0), -1)
            cv2.putText(frame, barcode_text, (barcode_x, barcode_y), font, font_scale, (255, 255, 255), thickness)

        return frame

    def _record_frames(self):
        """Internal method to continuously record frames with proper timing."""
        frame_duration = 1.0 / config.VIDEO_FPS
        next_frame_time = time.time()

        while self.recording:
            current_time = time.time()

            # Wait until it's time for the next frame
            if current_time < next_frame_time:
                sleep_time = next_frame_time - current_time
                if sleep_time > 0:
                    time.sleep(sleep_time)

            frame = self.get_frame()
            if frame is not None and self.video_writer is not None:
                # Resize frame to match video resolution if needed
                if frame.shape[1] != config.VIDEO_RESOLUTION[0] or frame.shape[0] != config.VIDEO_RESOLUTION[1]:
                    frame = cv2.resize(frame, config.VIDEO_RESOLUTION)

                # Add timestamp watermark
                frame = self._add_timestamp_watermark(frame)

                self.video_writer.write(frame)
                self.frame_count += 1

            # Schedule next frame
            next_frame_time += frame_duration

            # If we've fallen behind, reset timing to avoid catching up rapidly
            if time.time() > next_frame_time + frame_duration:
                next_frame_time = time.time()

    def stop_recording(self) -> dict:
        """
        Stop recording video.

        Returns:
            Dictionary with recording details (filename, duration, file_size)
        """
        with self.lock:
            if not self.recording:
                raise Exception("Not currently recording")

            try:
                self.recording = False

                # Wait for recording thread to finish
                if hasattr(self, 'recording_thread') and self.recording_thread.is_alive():
                    self.recording_thread.join(timeout=2.0)

                # Release video writer
                if self.video_writer is not None:
                    self.video_writer.release()
                    self.video_writer = None

                # Calculate duration
                duration = int(time.time() - self.recording_start_time)

                # Get file size (include label folder in path)
                date_folder = datetime.now().strftime('%Y-%m-%d')
                label_folder = self.current_label_folder if self.current_label_folder else "Normal"
                video_path = os.path.join(
                    config.VIDEO_STORAGE_PATH,
                    date_folder,
                    label_folder,
                    self.current_filename
                )
                file_size_mb = os.path.getsize(video_path) / (1024 * 1024)

                result = {
                    'filename': self.current_filename,
                    'duration': duration,
                    'file_size_mb': round(file_size_mb, 2),
                    'label_folder': label_folder
                }

                logger.info(f"Stopped recording: {self.current_filename} ({duration}s, {file_size_mb:.2f}MB) in {label_folder}")

                self.current_filename = None
                self.recording_start_time = None
                self.current_label_folder = None

                return result

            except Exception as e:
                logger.error(f"Error stopping recording: {e}")
                raise

    def is_recording(self) -> bool:
        """Check if currently recording."""
        return self.recording

    def get_recording_duration(self) -> Optional[int]:
        """Get the current recording duration in seconds."""
        if self.recording and self.recording_start_time:
            return int(time.time() - self.recording_start_time)
        return None

    def reinitialize(self):
        """
        Reinitialize the camera with new settings.
        This will reload configuration and restart the camera.
        """
        with self.lock:
            if self.recording:
                logger.warning("Cannot reinitialize camera while recording")
                raise Exception("Cannot reinitialize camera while recording")

            try:
                # Release current camera
                if self.camera is not None:
                    self.camera.release()
                    self.camera = None
                    time.sleep(0.5)  # Give camera time to release

                # Reload configuration
                import importlib
                importlib.reload(config)

                # Reinitialize camera with new settings
                self.initialize_camera()

                logger.info("Camera reinitialized successfully")
                return True

            except Exception as e:
                logger.error(f"Error reinitializing camera: {e}")
                # Try to recover by initializing with current settings
                try:
                    self.initialize_camera()
                except:
                    pass
                raise

    def cleanup(self):
        """Clean up camera resources."""
        with self.lock:
            if self.recording:
                try:
                    self.stop_recording()
                except:
                    pass

            if self.camera is not None:
                self.camera.release()
                self.camera = None

            logger.info("Camera resources cleaned up")
