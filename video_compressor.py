"""
Video Compressor - Background compression worker using FFmpeg
"""
import os
import subprocess
import threading
import queue
import logging
import shutil
import time
from typing import Dict, Optional, Callable, Tuple
from dataclasses import dataclass
from enum import Enum

logger = logging.getLogger(__name__)

# Windows process priority flags
PRIORITY_FLAGS = {
    'low': 0x00000040,         # IDLE_PRIORITY_CLASS
    'below_normal': 0x00004000, # BELOW_NORMAL_PRIORITY_CLASS
    'normal': 0x00000020        # NORMAL_PRIORITY_CLASS
}


class CompressionStatus(Enum):
    """Status of compression jobs."""
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"
    SKIPPED = "skipped"


@dataclass
class CompressionJob:
    """Represents a compression job in the queue."""
    video_path: str
    transaction_id: int
    settings: Dict
    output_path: Optional[str] = None


class VideoCompressor:
    """Background video compression worker using FFmpeg."""

    def __init__(self, on_complete: Optional[Callable] = None):
        """
        Initialize the video compressor.

        Args:
            on_complete: Callback function called when compression completes.
                        Signature: on_complete(transaction_id, success, result_data)
        """
        self._queue = queue.Queue()
        self._worker_thread: Optional[threading.Thread] = None
        self._running = False
        self._current_job: Optional[CompressionJob] = None
        self._on_complete = on_complete
        self._ffmpeg_path: Optional[str] = None
        self._ffmpeg_available: Optional[bool] = None
        self._lock = threading.Lock()

    def start(self):
        """Start the background compression worker."""
        if self._running:
            return

        self._running = True
        self._worker_thread = threading.Thread(target=self._worker_loop, daemon=True)
        self._worker_thread.start()
        logger.info("Video compressor worker started")

    def stop(self):
        """Stop the background compression worker gracefully."""
        self._running = False
        # Add None to queue to unblock worker
        self._queue.put(None)

        if self._worker_thread and self._worker_thread.is_alive():
            self._worker_thread.join(timeout=5.0)

        logger.info("Video compressor worker stopped")

    def check_ffmpeg_installed(self) -> Tuple[bool, str]:
        """
        Check if FFmpeg is installed and accessible.

        Returns:
            Tuple of (is_available, message)
        """
        if self._ffmpeg_available is not None:
            if self._ffmpeg_available:
                return True, f"FFmpeg found at: {self._ffmpeg_path}"
            else:
                return False, "FFmpeg not found. Please install FFmpeg to enable compression."

        # Try to find ffmpeg
        ffmpeg_cmd = "ffmpeg"

        # Get the directory where this script is located
        script_dir = os.path.dirname(os.path.abspath(__file__))

        # Check common locations on Windows
        if os.name == 'nt':
            common_paths = [
                # Check local project folder first
                os.path.join(script_dir, "ffmpeg.exe"),
                os.path.join(script_dir, "ffmpeg", "ffmpeg.exe"),
                os.path.join(script_dir, "ffmpeg", "bin", "ffmpeg.exe"),
                # Then check system paths
                r"C:\ffmpeg\bin\ffmpeg.exe",
                r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
                r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe",
                os.path.expanduser(r"~\ffmpeg\bin\ffmpeg.exe"),
            ]

            for path in common_paths:
                if os.path.isfile(path):
                    ffmpeg_cmd = path
                    logger.info(f"Found FFmpeg at: {path}")
                    break

        try:
            # Set up flags to hide console window on Windows
            creationflags = 0
            startupinfo = None
            if os.name == 'nt':
                creationflags = 0x08000000  # CREATE_NO_WINDOW
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = subprocess.SW_HIDE

            result = subprocess.run(
                [ffmpeg_cmd, "-version"],
                capture_output=True,
                text=True,
                timeout=10,
                creationflags=creationflags,
                startupinfo=startupinfo
            )

            if result.returncode == 0:
                self._ffmpeg_available = True
                self._ffmpeg_path = ffmpeg_cmd
                version_line = result.stdout.split('\n')[0] if result.stdout else "Unknown version"
                logger.info(f"FFmpeg found: {version_line}")
                return True, f"FFmpeg available: {version_line}"
            else:
                self._ffmpeg_available = False
                return False, "FFmpeg found but returned an error"

        except FileNotFoundError:
            self._ffmpeg_available = False
            return False, "FFmpeg not found. Please install FFmpeg and add it to your PATH."
        except subprocess.TimeoutExpired:
            self._ffmpeg_available = False
            return False, "FFmpeg check timed out"
        except Exception as e:
            self._ffmpeg_available = False
            return False, f"Error checking FFmpeg: {str(e)}"

    def queue_compression(
        self,
        video_path: str,
        transaction_id: int,
        settings: Dict
    ) -> bool:
        """
        Queue a video for compression.

        Args:
            video_path: Path to the video file to compress
            transaction_id: Database transaction ID for status updates
            settings: Compression settings dict with keys:
                     - enabled: bool
                     - codec: 'h264' or 'h265'
                     - crf: int (18-35)
                     - preset: str (ultrafast/fast/medium/slow)
                     - delete_original: bool

        Returns:
            True if job was queued, False otherwise
        """
        if not settings.get('enabled', False):
            logger.info(f"Compression disabled, skipping {video_path}")
            if self._on_complete:
                self._on_complete(transaction_id, True, {
                    'status': CompressionStatus.SKIPPED.value,
                    'message': 'Compression disabled'
                })
            return False

        # Check if ffmpeg is available
        available, _ = self.check_ffmpeg_installed()
        if not available:
            logger.warning(f"FFmpeg not available, skipping compression for {video_path}")
            if self._on_complete:
                self._on_complete(transaction_id, False, {
                    'status': CompressionStatus.SKIPPED.value,
                    'message': 'FFmpeg not installed'
                })
            return False

        # Validate video file exists
        if not os.path.isfile(video_path):
            logger.error(f"Video file not found: {video_path}")
            if self._on_complete:
                self._on_complete(transaction_id, False, {
                    'status': CompressionStatus.FAILED.value,
                    'message': 'Video file not found'
                })
            return False

        job = CompressionJob(
            video_path=video_path,
            transaction_id=transaction_id,
            settings=settings
        )

        self._queue.put(job)
        logger.info(f"Queued compression job for transaction {transaction_id}: {video_path}")
        return True

    def get_queue_status(self) -> Dict:
        """
        Get the current status of the compression queue.

        Returns:
            Dict with queue status information
        """
        with self._lock:
            return {
                'queue_size': self._queue.qsize(),
                'is_processing': self._current_job is not None,
                'current_transaction_id': self._current_job.transaction_id if self._current_job else None,
                'worker_running': self._running
            }

    def _worker_loop(self):
        """Main worker loop that processes compression jobs."""
        logger.info("Compression worker loop started")

        while self._running:
            try:
                # Wait for a job with timeout
                job = self._queue.get(timeout=1.0)

                if job is None:
                    # Shutdown signal
                    break

                with self._lock:
                    self._current_job = job

                # Process the job
                self._process_job(job)

                with self._lock:
                    self._current_job = None

                self._queue.task_done()

            except queue.Empty:
                continue
            except Exception as e:
                logger.error(f"Error in compression worker: {e}")
                with self._lock:
                    self._current_job = None

        logger.info("Compression worker loop ended")

    def _process_job(self, job: CompressionJob):
        """
        Process a single compression job.

        Args:
            job: The compression job to process
        """
        logger.info(f"Processing compression job for transaction {job.transaction_id}")

        try:
            # Generate output path
            base_path, ext = os.path.splitext(job.video_path)
            output_path = f"{base_path}_compressed{ext}"
            job.output_path = output_path

            # Get original file size
            original_size = os.path.getsize(job.video_path)
            original_size_mb = original_size / (1024 * 1024)

            # Run compression
            success, message = self._compress_video(job)

            if success and os.path.isfile(output_path):
                # Get compressed file size
                compressed_size = os.path.getsize(output_path)
                compressed_size_mb = compressed_size / (1024 * 1024)
                compression_ratio = (1 - (compressed_size / original_size)) * 100 if original_size > 0 else 0

                logger.info(
                    f"Compression complete: {original_size_mb:.2f}MB -> {compressed_size_mb:.2f}MB "
                    f"({compression_ratio:.1f}% reduction)"
                )

                # Handle original file
                compressed_filename = os.path.basename(output_path)
                if job.settings.get('delete_original', True):
                    try:
                        os.remove(job.video_path)
                        # Rename compressed file to original name
                        os.rename(output_path, job.video_path)
                        compressed_filename = os.path.basename(job.video_path)
                        logger.info(f"Replaced original file with compressed version")
                    except Exception as e:
                        logger.error(f"Error replacing original file: {e}")

                # Callback with success
                if self._on_complete:
                    self._on_complete(job.transaction_id, True, {
                        'status': CompressionStatus.COMPLETED.value,
                        'compressed_file_size_mb': compressed_size_mb,
                        'compression_ratio': compression_ratio,
                        'compressed_filename': compressed_filename,
                        'message': f'Compressed successfully ({compression_ratio:.1f}% reduction)'
                    })
            else:
                # Compression failed
                logger.error(f"Compression failed: {message}")

                # Clean up partial output if exists
                if os.path.isfile(output_path):
                    try:
                        os.remove(output_path)
                    except:
                        pass

                if self._on_complete:
                    self._on_complete(job.transaction_id, False, {
                        'status': CompressionStatus.FAILED.value,
                        'message': message
                    })

        except Exception as e:
            logger.error(f"Error processing compression job: {e}")
            if self._on_complete:
                self._on_complete(job.transaction_id, False, {
                    'status': CompressionStatus.FAILED.value,
                    'message': str(e)
                })

    def _compress_video(self, job: CompressionJob) -> Tuple[bool, str]:
        """
        Execute FFmpeg compression command with low priority to avoid blocking main app.

        Args:
            job: The compression job with settings

        Returns:
            Tuple of (success, message)
        """
        settings = job.settings
        codec = settings.get('codec', 'h264')
        crf = settings.get('crf', 23)
        preset = settings.get('preset', 'medium')
        priority = settings.get('priority', 'below_normal')

        # Build FFmpeg command
        ffmpeg_cmd = self._ffmpeg_path or 'ffmpeg'

        # Select video codec
        if codec == 'h265':
            video_codec = 'libx265'
        else:
            video_codec = 'libx264'

        # Use faster preset and limit CPU threads to reduce impact on main app
        cmd = [
            ffmpeg_cmd,
            '-i', job.video_path,
            '-c:v', video_codec,
            '-crf', str(crf),
            '-preset', preset,
            '-threads', '2',  # Limit CPU threads
            '-c:a', 'aac',
            '-b:a', '128k',
            '-y',  # Overwrite output
            job.output_path
        ]

        logger.info(f"Running FFmpeg command (priority: {priority}): {' '.join(cmd)}")
        logger.info(f"Input file: {job.video_path} (exists: {os.path.isfile(job.video_path)})")
        logger.info(f"Output file: {job.output_path}")

        try:
            # Set up process creation flags for Windows
            creationflags = 0
            startupinfo = None
            if os.name == 'nt':
                # CREATE_NO_WINDOW = 0x08000000 (hide console window)
                priority_flag = PRIORITY_FLAGS.get(priority, 0x00004000)
                creationflags = 0x08000000 | priority_flag

                # Also use startupinfo to ensure no window
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = subprocess.SW_HIDE

            # Use Popen for non-blocking execution with low priority and no window
            # Redirect all output to DEVNULL to prevent pipe buffer blocking
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                creationflags=creationflags,
                startupinfo=startupinfo
            )

            # Wait for completion with timeout (non-blocking check every 2 seconds)
            timeout_seconds = 3600  # 1 hour
            elapsed = 0
            last_log = 0
            while elapsed < timeout_seconds:
                retcode = process.poll()
                if retcode is not None:
                    break
                time.sleep(2)
                elapsed += 2
                # Log progress every 30 seconds
                if elapsed - last_log >= 30:
                    logger.info(f"Compression in progress... ({elapsed}s elapsed)")
                    last_log = elapsed

            if process.poll() is None:
                # Process still running after timeout, kill it
                process.kill()
                process.wait()
                return False, "Compression timed out (exceeded 1 hour)"

            # Get the return code
            returncode = process.returncode
            logger.info(f"FFmpeg process completed with return code: {returncode}")

            if returncode == 0:
                return True, "Compression successful"
            else:
                logger.error(f"FFmpeg failed with return code {returncode}")
                return False, f"FFmpeg error (return code {returncode})"

        except Exception as e:
            return False, f"Error running FFmpeg: {str(e)}"
