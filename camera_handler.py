import cv2
import logging
import threading
import time
import os
import platform
from datetime import datetime
from typing import Optional
from collections import deque
import config

logger = logging.getLogger(__name__)

# MSMF (Media Foundation) is preferred on Windows for lower latency


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

        # Frame capture thread variables
        self.capture_thread = None
        self.capture_running = False
        self.latest_frame = None
        self.frame_lock = threading.Lock()

        # Frame buffer for recording (thread-safe queue)
        self.frame_buffer = deque(maxlen=60)  # Buffer up to 2 seconds at 30fps
        self.buffer_lock = threading.Lock()

        # Actual FPS tracking
        self.actual_fps = config.VIDEO_FPS
        self.fps_sample_times = deque(maxlen=30)  # Track last 30 frame times

        self.initialize_camera()

    def initialize_camera(self):
        """Initialize the camera."""
        try:
            # Use MSMF (Media Foundation) on Windows for lower latency
            # MSMF is Microsoft's modern camera API with better performance than DirectShow
            if platform.system() == 'Windows':
                self.camera = cv2.VideoCapture(config.CAMERA_INDEX, cv2.CAP_MSMF)
                logger.info(f"Initializing camera {config.CAMERA_INDEX} with MSMF backend")
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

            # Set buffer size to minimum to reduce latency
            self.camera.set(cv2.CAP_PROP_BUFFERSIZE, 1)

            # ===== Light sensitivity settings =====
            # Apply exposure settings from config
            self.apply_exposure_settings()

            # Warm up camera
            time.sleep(config.CAMERA_WARMUP_TIME)

            # Verify camera is working by grabbing a test frame
            ret, frame = self.camera.read()
            if not ret or frame is None:
                logger.warning("Camera opened but cannot read frames")
            else:
                self.latest_frame = frame

            # Start the background capture thread
            self._start_capture_thread()

            logger.info(f"Camera initialized successfully (Resolution: {config.VIDEO_RESOLUTION}, FPS: {config.VIDEO_FPS})")
        except Exception as e:
            logger.error(f"Error initializing camera: {e}")
            raise

    def _start_capture_thread(self):
        """Start the background frame capture thread."""
        if self.capture_thread is not None and self.capture_thread.is_alive():
            return

        self.capture_running = True
        self.capture_thread = threading.Thread(target=self._capture_frames, daemon=True)
        self.capture_thread.start()
        logger.info("Frame capture thread started")

    def _stop_capture_thread(self):
        """Stop the background frame capture thread."""
        self.capture_running = False
        if self.capture_thread is not None:
            self.capture_thread.join(timeout=2.0)
            self.capture_thread = None
        logger.info("Frame capture thread stopped")

    def _capture_frames(self):
        """Background thread that continuously captures frames from the camera."""
        while self.capture_running:
            if self.camera is None or not self.camera.isOpened():
                time.sleep(0.01)
                continue

            try:
                ret, frame = self.camera.read()
                if ret and frame is not None:
                    current_time = time.time()

                    # Update the latest frame for display (thread-safe)
                    with self.frame_lock:
                        self.latest_frame = frame

                    # Track FPS
                    self.fps_sample_times.append(current_time)
                    if len(self.fps_sample_times) >= 2:
                        elapsed = self.fps_sample_times[-1] - self.fps_sample_times[0]
                        if elapsed > 0:
                            self.actual_fps = (len(self.fps_sample_times) - 1) / elapsed

                    # Add to recording buffer if recording
                    if self.recording:
                        with self.buffer_lock:
                            self.frame_buffer.append((frame.copy(), current_time))
                else:
                    # Small sleep to avoid spinning on failed reads
                    time.sleep(0.001)

            except Exception as e:
                logger.error(f"Error capturing frame: {e}")
                time.sleep(0.01)

    def get_frame(self):
        """Get the current frame from the camera (non-blocking, returns cached frame)."""
        with self.frame_lock:
            if self.latest_frame is not None:
                return self.latest_frame.copy()
            return None

    def get_preview_frame(self, max_width: int = 640, max_height: int = 480):
        """
        Get a downscaled preview frame for display (reduces lag).

        Args:
            max_width: Maximum width for preview
            max_height: Maximum height for preview

        Returns:
            Downscaled frame for preview display
        """
        # Get frame reference quickly under lock
        with self.frame_lock:
            if self.latest_frame is None:
                return None
            # Copy frame data while under lock (fast operation)
            frame = self.latest_frame

        # Do expensive resize operation outside the lock
        height, width = frame.shape[:2]

        # Calculate scale to fit within max dimensions while preserving aspect ratio
        scale_w = max_width / width
        scale_h = max_height / height
        scale = min(scale_w, scale_h, 1.0)  # Don't upscale

        if scale < 1.0:
            new_width = int(width * scale)
            new_height = int(height * scale)
            # Use INTER_NEAREST for fastest downscaling (no interpolation)
            return cv2.resize(frame, (new_width, new_height), interpolation=cv2.INTER_NEAREST)

        return frame.copy()

    def get_actual_fps(self):
        """Get the actual measured FPS of the camera."""
        return self.actual_fps

    def apply_exposure_settings(self, auto_exposure=None, exposure=None, gain=None, brightness=None):
        """
        Apply camera exposure settings.

        If no parameters are provided, reads from config.
        If parameters are provided, applies those values directly (for real-time preview).

        Args:
            auto_exposure: True for auto, False for manual mode
            exposure: Manual exposure value (-13 to -1, lower = darker)
            gain: Gain value (0 to 255, lower = less noise)
            brightness: Brightness value (0 to 255)
        """
        if self.camera is None or not self.camera.isOpened():
            logger.warning("Cannot apply exposure settings - camera not available")
            return False

        try:
            # Use provided values or load from config
            if auto_exposure is None:
                auto_exposure = config.settings_manager.get_camera_auto_exposure()
            if exposure is None:
                exposure = config.settings_manager.get_camera_exposure()
            if gain is None:
                gain = config.settings_manager.get_camera_gain()
            if brightness is None:
                brightness = config.settings_manager.get_camera_brightness()

            # Apply auto-exposure setting
            # 0 or 0.25 = manual mode (varies by camera)
            # 1 or 3 = auto mode (varies by camera)
            if auto_exposure:
                self.camera.set(cv2.CAP_PROP_AUTO_EXPOSURE, 3)  # Auto mode
                logger.info("Camera set to auto-exposure mode")
            else:
                self.camera.set(cv2.CAP_PROP_AUTO_EXPOSURE, 1)  # Manual mode

                # Apply manual exposure value
                self.camera.set(cv2.CAP_PROP_EXPOSURE, exposure)
                logger.info(f"Camera exposure set to {exposure}")

            # Apply gain
            self.camera.set(cv2.CAP_PROP_GAIN, gain)
            logger.info(f"Camera gain set to {gain}")

            # Apply brightness
            self.camera.set(cv2.CAP_PROP_BRIGHTNESS, brightness)
            logger.info(f"Camera brightness set to {brightness}")

            return True

        except Exception as e:
            logger.error(f"Error applying exposure settings: {e}")
            return False

    def get_current_exposure_settings(self):
        """
        Get the current camera exposure settings from the camera hardware.

        Returns:
            dict: Current exposure settings from camera
        """
        if self.camera is None or not self.camera.isOpened():
            return None

        try:
            return {
                'auto_exposure': self.camera.get(cv2.CAP_PROP_AUTO_EXPOSURE),
                'exposure': self.camera.get(cv2.CAP_PROP_EXPOSURE),
                'gain': self.camera.get(cv2.CAP_PROP_GAIN),
                'brightness': self.camera.get(cv2.CAP_PROP_BRIGHTNESS)
            }
        except Exception as e:
            logger.error(f"Error getting exposure settings: {e}")
            return None

    def generate_frames(self):
        """Generator function for streaming frames to the web UI (uses preview for performance)."""
        while True:
            # Use preview frame for web streaming (lighter weight)
            frame = self.get_preview_frame(max_width=800, max_height=600)
            if frame is None:
                time.sleep(0.01)  # Wait a bit if no frame available
                continue

            # Encode frame as JPEG with reduced quality for faster streaming
            encode_params = [cv2.IMWRITE_JPEG_QUALITY, 70]
            ret, buffer = cv2.imencode('.jpg', frame, encode_params)
            if not ret:
                continue

            frame_bytes = buffer.tobytes()
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')

            # Small delay to control stream rate (~30 FPS max)
            time.sleep(0.033)

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

                # Clear the frame buffer before starting
                with self.buffer_lock:
                    self.frame_buffer.clear()

                # Use actual measured FPS for the video file to ensure correct playback speed
                # Fall back to config FPS if we don't have enough samples yet
                recording_fps = self.actual_fps if self.actual_fps > 0 else config.VIDEO_FPS
                # Clamp FPS to reasonable range
                recording_fps = max(10, min(60, recording_fps))
                self.recording_fps = recording_fps

                # Initialize video writer with actual FPS
                fourcc = cv2.VideoWriter_fourcc(*config.VIDEO_CODEC)
                self.video_writer = cv2.VideoWriter(
                    video_path,
                    fourcc,
                    recording_fps,
                    config.VIDEO_RESOLUTION
                )

                if not self.video_writer.isOpened():
                    raise Exception("Could not open video writer")

                self.recording = True
                self.recording_start_time = time.time()

                # Start recording thread
                self.recording_thread = threading.Thread(target=self._record_frames, daemon=True)
                self.recording_thread.start()

                logger.info(f"Started recording: {self.current_filename} (Label: {label}, FPS: {recording_fps:.1f})")
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
        """Internal method to continuously record frames from the buffer."""
        while self.recording:
            frame_to_write = None

            # Get frame from buffer
            with self.buffer_lock:
                if self.frame_buffer:
                    frame_to_write, _ = self.frame_buffer.popleft()

            if frame_to_write is not None and self.video_writer is not None:
                try:
                    # Resize frame to match video resolution if needed
                    if frame_to_write.shape[1] != config.VIDEO_RESOLUTION[0] or frame_to_write.shape[0] != config.VIDEO_RESOLUTION[1]:
                        frame_to_write = cv2.resize(frame_to_write, config.VIDEO_RESOLUTION)

                    # Add timestamp watermark
                    frame_to_write = self._add_timestamp_watermark(frame_to_write)

                    self.video_writer.write(frame_to_write)
                    self.frame_count += 1
                except Exception as e:
                    logger.error(f"Error writing frame: {e}")
            else:
                # No frame in buffer, sleep briefly to avoid spinning
                time.sleep(0.005)

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

                # Write any remaining frames in the buffer
                if self.video_writer is not None:
                    with self.buffer_lock:
                        while self.frame_buffer:
                            frame, _ = self.frame_buffer.popleft()
                            if frame.shape[1] != config.VIDEO_RESOLUTION[0] or frame.shape[0] != config.VIDEO_RESOLUTION[1]:
                                frame = cv2.resize(frame, config.VIDEO_RESOLUTION)
                            frame = self._add_timestamp_watermark(frame)
                            self.video_writer.write(frame)
                            self.frame_count += 1

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

                # Get actual recorded FPS
                recorded_fps = getattr(self, 'recording_fps', config.VIDEO_FPS)

                result = {
                    'filename': self.current_filename,
                    'duration': duration,
                    'file_size_mb': round(file_size_mb, 2),
                    'label_folder': label_folder,
                    'fps': recorded_fps,
                    'frame_count': self.frame_count
                }

                logger.info(f"Stopped recording: {self.current_filename} ({duration}s, {file_size_mb:.2f}MB, {self.frame_count} frames at {recorded_fps:.1f}fps) in {label_folder}")

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
                # Stop the capture thread first
                self._stop_capture_thread()

                # Release current camera
                if self.camera is not None:
                    self.camera.release()
                    self.camera = None
                    time.sleep(0.5)  # Give camera time to release

                # Clear the frame
                with self.frame_lock:
                    self.latest_frame = None

                # Reload configuration
                import importlib
                importlib.reload(config)

                # Reset FPS tracking
                self.fps_sample_times.clear()
                self.actual_fps = config.VIDEO_FPS

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
        # Stop capture thread first (outside of lock to avoid deadlock)
        self._stop_capture_thread()

        with self.lock:
            if self.recording:
                try:
                    self.recording = False
                    if hasattr(self, 'recording_thread') and self.recording_thread.is_alive():
                        self.recording_thread.join(timeout=1.0)
                    if self.video_writer is not None:
                        self.video_writer.release()
                        self.video_writer = None
                except:
                    pass

            if self.camera is not None:
                self.camera.release()
                self.camera = None

            logger.info("Camera resources cleaned up")
