import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext, filedialog
import cv2
from PIL import Image, ImageTk
import threading
import time
import logging
import os
import subprocess
import platform
from datetime import datetime
from tkcalendar import DateEntry
from camera_handler import CameraHandler
from barcode_handler import BarcodeHandler
from database import Database
from video_compressor import VideoCompressor
import config
from settings_manager import SettingsManager
from camera_utils import get_available_cameras, get_available_cameras_fast, refresh_cameras_async

# Configure logging
os.makedirs(config.LOG_PATH, exist_ok=True)
logging.basicConfig(
    level=getattr(logging, config.LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(config.LOG_FILE),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)


class SavingProgressDialog:
    """Progress dialog shown while saving recordings."""

    def __init__(self, parent, title="Saving Recording"):
        self.parent = parent
        self.cancelled = False
        self.result = None
        self.error = None

        # Create dialog
        self.dialog = tk.Toplevel(parent)
        self.dialog.title(title)
        self.dialog.transient(parent)
        self.dialog.resizable(False, False)

        # Prevent closing
        self.dialog.protocol("WM_DELETE_WINDOW", lambda: None)

        # Center on parent
        self.dialog.geometry("350x120")
        self.dialog.update_idletasks()
        x = parent.winfo_x() + (parent.winfo_width() - 350) // 2
        y = parent.winfo_y() + (parent.winfo_height() - 120) // 2
        self.dialog.geometry(f"+{x}+{y}")

        # Content
        frame = ttk.Frame(self.dialog, padding=20)
        frame.pack(fill=tk.BOTH, expand=True)

        self.status_label = ttk.Label(frame, text="Saving recording...", font=("Arial", 11))
        self.status_label.pack(pady=(0, 15))

        self.progress = ttk.Progressbar(frame, mode='indeterminate', length=300)
        self.progress.pack(pady=(0, 10))
        self.progress.start(10)

        self.detail_label = ttk.Label(frame, text="Writing remaining frames...", font=("Arial", 9), foreground="gray")
        self.detail_label.pack()

        # Force display
        self.dialog.update()

    def update_status(self, text, detail=None):
        """Update the status text."""
        self.status_label.configure(text=text)
        if detail:
            self.detail_label.configure(text=detail)
        self.dialog.update()

    def close(self):
        """Close the dialog."""
        self.progress.stop()
        self.dialog.destroy()


class EcomVideoTrackerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Ecom Video Tracker")
        self.root.geometry("1000x800")
        self.root.minsize(800, 600)  # Minimum window size
        self.root.resizable(True, True)

        # Set window icon (optional - will use default if no icon)
        try:
            # You can add an icon file later: self.root.iconbitmap('icon.ico')
            pass
        except:
            pass

        # Initialize handlers
        self.camera = CameraHandler()
        self.barcode_handler = BarcodeHandler()
        self.db = Database()

        # Initialize video compressor
        self.compressor = VideoCompressor(on_complete=self.on_compression_complete)
        self.compressor.start()

        # State variables
        self.current_transaction_id = None
        self.recording_start_time = None
        self.update_running = True
        self.compression_status = ""  # For displaying compression status

        # Resize handling
        self._resize_pending = False
        self._last_size = (0, 0)

        # Setup UI
        self.setup_ui()

        # Bind resize event with debouncing
        self.root.bind('<Configure>', self._on_window_configure)

        # Start camera feed
        self.update_camera_feed()

        # Start status updates
        self.update_status()

        # Load initial recordings
        self.load_recordings()

        # Handle window close
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

        logger.info("GUI Application started")

    def _on_window_configure(self, event):
        """Handle window resize with debouncing."""
        # Only handle root window resize events
        if event.widget != self.root:
            return

        new_size = (event.width, event.height)
        if new_size == self._last_size:
            return

        self._last_size = new_size

        # Debounce: only update after resize stops
        if not self._resize_pending:
            self._resize_pending = True
            self.root.after(100, self._handle_resize)

    def _handle_resize(self):
        """Handle resize after debounce delay."""
        self._resize_pending = False
        # Clear cached container size to force recalculation
        if hasattr(self, '_cached_container_size'):
            del self._cached_container_size

    def setup_ui(self):
        """Setup the user interface."""
        # Configure style with modern colors
        style = ttk.Style()
        style.theme_use('clam')

        # Configure button styles
        style.configure('Primary.TButton',
                       background='#667eea',
                       foreground='white',
                       padding=(15, 8),
                       font=('Arial', 10, 'bold'))
        style.map('Primary.TButton',
                 background=[('active', '#5568d3')])

        style.configure('Danger.TButton',
                       background='#dc2626',
                       foreground='white',
                       padding=(15, 8),
                       font=('Arial', 10, 'bold'))
        style.map('Danger.TButton',
                 background=[('active', '#b91c1c')])

        style.configure('Success.TButton',
                       background='#10b981',
                       foreground='white',
                       padding=(15, 8),
                       font=('Arial', 10, 'bold'))
        style.map('Success.TButton',
                 background=[('active', '#059669')])

        # Set window background color
        self.root.configure(bg='#f0f4f8')

        # Main container with gradient-like background
        main_frame = tk.Frame(self.root, bg='#f0f4f8')
        main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), padx=0, pady=0)

        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        main_frame.columnconfigure(0, weight=1)
        main_frame.rowconfigure(1, weight=1)

        # Header
        self.create_header(main_frame)

        # Content area (two columns)
        content_frame = tk.Frame(main_frame, bg='#f0f4f8')
        content_frame.grid(row=1, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), padx=15, pady=15)
        content_frame.columnconfigure(0, weight=3)
        content_frame.columnconfigure(1, weight=2)
        content_frame.rowconfigure(0, weight=1)

        # Left panel - Camera feed
        self.create_camera_panel(content_frame)

        # Right panel - Controls and info
        self.create_control_panel(content_frame)

        # Status bar
        self.create_status_bar(main_frame)

    def create_header(self, parent):
        """Create beautiful gradient header."""
        header_frame = tk.Frame(parent, bg='#667eea')
        header_frame.grid(row=0, column=0, sticky=(tk.W, tk.E))
        header_frame.columnconfigure(0, weight=1)

        # Title
        title_label = tk.Label(
            header_frame,
            text="📹 Ecom Video Tracker",
            font=("Arial", 24, "bold"),
            bg='#667eea',
            fg='white'
        )
        title_label.grid(row=0, column=0, sticky=tk.W, padx=20, pady=20)

        # Settings button with modern styling
        settings_btn = tk.Button(
            header_frame,
            text="⚙️ Settings",
            command=self.open_settings,
            font=("Arial", 11, "bold"),
            bg='#5568d3',
            fg='white',
            bd=0,
            padx=20,
            pady=10,
            cursor='hand2',
            relief=tk.FLAT
        )
        settings_btn.grid(row=0, column=1, sticky=tk.E, padx=20, pady=20)

    def create_camera_panel(self, parent):
        """Create beautiful camera feed panel."""
        # White card with shadow effect
        camera_frame = tk.Frame(parent, bg='white', relief=tk.FLAT, bd=0)
        camera_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), padx=(0, 8))
        camera_frame.rowconfigure(1, weight=1)
        camera_frame.columnconfigure(0, weight=1)

        # Header
        header = tk.Frame(camera_frame, bg='white')
        header.grid(row=0, column=0, sticky=(tk.W, tk.E), padx=15, pady=(15, 10))

        title = tk.Label(
            header,
            text="📹 Camera Feed",
            font=("Arial", 14, "bold"),
            bg='white',
            fg='#333'
        )
        title.pack(side=tk.LEFT)

        # Camera display container
        self.camera_container = tk.Frame(camera_frame, bg='#000', relief=tk.SOLID, bd=2)
        self.camera_container.grid(row=1, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), padx=15, pady=(0, 15))
        self.camera_container.rowconfigure(0, weight=1)
        self.camera_container.columnconfigure(0, weight=1)

        # Camera display
        self.camera_label = tk.Label(self.camera_container, text="Initializing camera...", bg='#000', fg='white', anchor=tk.CENTER)
        self.camera_label.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))

        # Recording indicator
        self.recording_indicator = tk.Label(
            self.camera_container,
            text="",
            font=("Arial", 12, "bold"),
            fg="white",
            bg="#dc2626",
            anchor=tk.CENTER,
            relief=tk.FLAT,
            padx=15,
            pady=5
        )
        # Will be shown when recording starts

    def create_control_panel(self, parent):
        """Create beautiful control and information panel."""
        control_frame = tk.Frame(parent, bg='#f0f4f8')
        control_frame.grid(row=0, column=1, sticky=(tk.W, tk.E, tk.N, tk.S), padx=(8, 0))
        control_frame.columnconfigure(0, weight=1)
        control_frame.rowconfigure(3, weight=1)  # Make recordings list expandable

        # Barcode input section
        self.create_barcode_input(control_frame)

        # Search button (opens separate window)
        self.create_search_button(control_frame)

        # System info section
        self.create_system_info(control_frame)

        # Recordings list section
        self.create_recordings_list(control_frame)

    def create_barcode_input(self, parent):
        """Create beautiful barcode input section."""
        # White card
        input_frame = tk.Frame(parent, bg='white', relief=tk.FLAT, bd=0)
        input_frame.grid(row=0, column=0, sticky=(tk.W, tk.E), pady=(0, 12))

        # Header
        header = tk.Frame(input_frame, bg='white')
        header.pack(fill=tk.X, padx=15, pady=(15, 10))

        title = tk.Label(
            header,
            text="📦 Barcode Input",
            font=("Arial", 13, "bold"),
            bg='white',
            fg='#333'
        )
        title.pack(anchor=tk.W)

        # Content
        content = tk.Frame(input_frame, bg='white')
        content.pack(fill=tk.X, padx=15, pady=(0, 15))

        # Video Label selection
        tk.Label(
            content,
            text="Video Label:",
            font=("Arial", 10, "bold"),
            bg='white',
            fg='#555'
        ).pack(anchor=tk.W, pady=(0, 5))

        # Label dropdown
        self.label_var = tk.StringVar(value="Normal (Standard)")
        self.label_options = [
            "Return and Refund Unboxing",
            "Return Parcel Unboxing",
            "Normal (Standard)"
        ]

        label_frame = tk.Frame(content, bg='white')
        label_frame.pack(fill=tk.X, pady=(0, 10))

        self.label_combo = ttk.Combobox(
            label_frame,
            textvariable=self.label_var,
            values=self.label_options,
            state='readonly',
            font=("Arial", 10)
        )
        self.label_combo.pack(fill=tk.X)

        # Barcode entry label
        tk.Label(
            content,
            text="Scan or Enter Barcode:",
            font=("Arial", 10),
            bg='white',
            fg='#555'
        ).pack(anchor=tk.W, pady=(0, 5))

        # Entry field
        self.barcode_entry = tk.Entry(
            content,
            font=("Arial", 12),
            relief=tk.SOLID,
            bd=2,
            highlightthickness=0
        )
        self.barcode_entry.pack(fill=tk.X, pady=(0, 10))
        self.barcode_entry.bind('<Return>', lambda e: self.process_barcode())
        self.barcode_entry.focus()

        # Help text
        help_label = tk.Label(
            content,
            text="Scan continuously: Each barcode stops the\nprevious recording and starts a new one.",
            font=("Arial", 9),
            bg='white',
            fg='#888',
            justify=tk.LEFT
        )
        help_label.pack(anchor=tk.W, pady=(0, 12))

        # Buttons
        button_frame = tk.Frame(content, bg='white')
        button_frame.pack(fill=tk.X)

        self.submit_button = tk.Button(
            button_frame,
            text="▶ Submit Barcode",
            command=self.process_barcode,
            font=("Arial", 10, "bold"),
            bg='#667eea',
            fg='white',
            bd=0,
            padx=15,
            pady=8,
            cursor='hand2',
            relief=tk.FLAT
        )
        self.submit_button.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))

        self.stop_button = tk.Button(
            button_frame,
            text="⏹ Stop Recording",
            command=self.manual_stop,
            font=("Arial", 10, "bold"),
            bg='#dc2626',
            fg='white',
            bd=0,
            padx=15,
            pady=8,
            cursor='hand2',
            state=tk.DISABLED,
            relief=tk.FLAT
        )
        self.stop_button.pack(side=tk.LEFT, fill=tk.X, expand=True)

    def create_search_button(self, parent):
        """Create beautiful search button."""
        search_frame = tk.Frame(parent, bg='#f0f4f8')
        search_frame.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 12))

        search_btn = tk.Button(
            search_frame,
            text="🔍 Search Recordings",
            command=self.open_search_window,
            font=("Arial", 11, "bold"),
            bg='#10b981',
            fg='white',
            bd=0,
            padx=20,
            pady=12,
            cursor='hand2',
            relief=tk.FLAT
        )
        search_btn.pack(fill=tk.X)

        help_label = tk.Label(
            search_frame,
            text="Click to search and view recordings",
            font=("Arial", 9),
            bg='#f0f4f8',
            fg='#888'
        )
        help_label.pack(pady=(5, 0))

    def create_system_info(self, parent):
        """Create beautiful system information section."""
        # White card
        info_frame = tk.Frame(parent, bg='white', relief=tk.FLAT, bd=0)
        info_frame.grid(row=2, column=0, sticky=(tk.W, tk.E), pady=(0, 12))

        # Header
        header = tk.Frame(info_frame, bg='white')
        header.pack(fill=tk.X, padx=15, pady=(15, 10))

        title = tk.Label(
            header,
            text="📊 System Status",
            font=("Arial", 13, "bold"),
            bg='white',
            fg='#333'
        )
        title.pack(anchor=tk.W)

        # Content
        content = tk.Frame(info_frame, bg='white')
        content.pack(fill=tk.X, padx=15, pady=(0, 15))

        # Info rows
        info_data = [
            ("⚡ Status:", "status_label", "Idle", "#6b7280"),
            ("📄 Current File:", "filename_label", "-", "#6b7280"),
            ("⏱️ Duration:", "duration_label", "00:00", "#6b7280"),
            ("💾 Storage Used:", "storage_label", "0 MB", "#6b7280"),
            ("🗜️ Compression:", "compression_label", "Ready", "#6b7280")
        ]

        for icon_label, attr_name, default_text, color in info_data:
            row = tk.Frame(content, bg='white')
            row.pack(fill=tk.X, pady=4)

            tk.Label(
                row,
                text=icon_label,
                font=("Arial", 10, "bold"),
                bg='white',
                fg='#555',
                width=15,
                anchor=tk.W
            ).pack(side=tk.LEFT)

            label = tk.Label(
                row,
                text=default_text,
                font=("Arial", 10),
                bg='white',
                fg=color,
                anchor=tk.W
            )
            label.pack(side=tk.LEFT, fill=tk.X, expand=True)
            setattr(self, attr_name, label)

    def create_recordings_list(self, parent):
        """Create beautiful recent recordings list section."""
        # White card
        list_frame = tk.Frame(parent, bg='white', relief=tk.FLAT, bd=0)
        list_frame.grid(row=3, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))

        # Header
        header = tk.Frame(list_frame, bg='white')
        header.pack(fill=tk.X, padx=15, pady=(15, 10))

        title = tk.Label(
            header,
            text="📝 Recent Recordings",
            font=("Arial", 13, "bold"),
            bg='white',
            fg='#333'
        )
        title.pack(anchor=tk.W)

        # Content
        content = tk.Frame(list_frame, bg='white')
        content.pack(fill=tk.BOTH, expand=True, padx=15, pady=(0, 15))

        # Scrolled text for recordings (no fixed width/height for proper scaling)
        self.recordings_text = scrolledtext.ScrolledText(
            content,
            wrap=tk.WORD,
            font=("Courier", 9),
            state=tk.DISABLED,
            bg='#f8f9fa',
            relief=tk.SOLID,
            bd=1
        )
        self.recordings_text.pack(fill=tk.BOTH, expand=True)

    def create_status_bar(self, parent):
        """Create beautiful status bar."""
        status_frame = tk.Frame(parent, bg='#e5e7eb')
        status_frame.grid(row=2, column=0, sticky=(tk.W, tk.E))

        self.status_bar = tk.Label(
            status_frame,
            text="🟢 Ready",
            anchor=tk.W,
            font=("Arial", 9),
            bg='#e5e7eb',
            fg='#374151',
            padx=15
        )
        self.status_bar.pack(fill=tk.BOTH, expand=True)

    def update_camera_feed(self):
        """Update the camera feed display with lightweight preview - optimized for real-time."""
        if not self.update_running:
            return

        try:
            # Initialize frame count
            if not hasattr(self, '_frame_count'):
                self._frame_count = 0
            self._frame_count += 1

            # Cache container dimensions (recalculate every 60 frames or when resize pending)
            should_recalc = (
                not hasattr(self, '_cached_container_size') or
                self._frame_count % 60 == 0 or
                self._resize_pending
            )

            if should_recalc:
                try:
                    container_width = self.camera_container.winfo_width()
                    container_height = self.camera_container.winfo_height()

                    # Use minimum dimensions if container not yet sized
                    if container_width > 100 and container_height > 100:
                        self._cached_container_size = (container_width - 4, container_height - 4)
                    elif not hasattr(self, '_cached_container_size'):
                        self._cached_container_size = (640, 480)
                except:
                    if not hasattr(self, '_cached_container_size'):
                        self._cached_container_size = (640, 480)

            max_display_width, max_display_height = self._cached_container_size

            # Get preview frame (already downscaled for performance)
            frame = self.camera.get_preview_frame(max_display_width, max_display_height)

            if frame is not None:
                # Convert BGR to RGB
                frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

                # Convert to PIL Image and PhotoImage
                img = Image.fromarray(frame_rgb)
                photo = ImageTk.PhotoImage(image=img)

                # Update label
                self.camera_label.configure(image=photo)
                self.camera_label.image = photo

        except Exception as e:
            # Silently ignore frame errors to maintain smooth display
            pass

        # Schedule next update (33ms = ~30 FPS display rate - reduces CPU load while still smooth)
        self.root.after(33, self.update_camera_feed)

    def update_status(self):
        """Update status information."""
        if not self.update_running:
            return

        try:
            # Update recording duration
            if self.camera.is_recording() and self.recording_start_time:
                duration = int(time.time() - self.recording_start_time)
                mins = duration // 60
                secs = duration % 60
                self.duration_label.configure(text=f"{mins:02d}:{secs:02d}")

            # Update storage info
            storage_mb = self.db.get_total_storage_used()
            self.storage_label.configure(text=f"{storage_mb:.2f} MB")

            # Update compression status
            queue_status = self.compressor.get_queue_status()
            if queue_status['is_processing']:
                self.compression_label.configure(text="Processing...", fg="#f59e0b")
                # Refresh recordings list every 5 seconds while compressing
                if not hasattr(self, '_last_refresh') or time.time() - self._last_refresh > 5:
                    self._last_refresh = time.time()
                    self.load_recordings()
            elif queue_status['queue_size'] > 0:
                self.compression_label.configure(text=f"Queued: {queue_status['queue_size']}", fg="#3b82f6")
            elif self.compression_status:
                self.compression_label.configure(text=self.compression_status, fg="#10b981")
                # Refresh one more time after completion
                if hasattr(self, '_last_refresh'):
                    del self._last_refresh
                    self.load_recordings()
            else:
                self.compression_label.configure(text="Ready", fg="#6b7280")

        except Exception as e:
            logger.error(f"Error updating status: {e}")

        # Schedule next update
        self.root.after(1000, self.update_status)

    def process_barcode(self):
        """Process barcode input."""
        barcode_input = self.barcode_entry.get().strip()

        if not barcode_input:
            messagebox.showwarning("Input Required", "Please enter a barcode")
            return

        try:
            # Get selected label
            selected_label = self.label_var.get()

            # Process barcode with current recording state
            result = self.barcode_handler.process_barcode(barcode_input, self.camera.is_recording())

            if result['action'] == 'invalid':
                messagebox.showerror("Invalid Barcode", "The barcode entered is invalid")
                return

            if result['action'] == 'start':
                # Start recording with label
                filename = self.camera.start_recording(result['barcode'], selected_label)

                # Create database transaction with label
                self.current_transaction_id = self.db.create_transaction(result['barcode'], filename, selected_label)

                # Update UI
                self.recording_start_time = time.time()
                self.update_ui_recording(True, filename, selected_label)
                self.set_status_bar(f"Recording started: {result['barcode']} ({selected_label})", "success")

                # Clear input
                self.barcode_entry.delete(0, tk.END)
                self.barcode_entry.focus()

            elif result['action'] == 'stop_and_start':
                # Stop and start new recording - use progress dialog
                def on_stop_complete(recording_info):
                    if recording_info:
                        # Start new recording
                        try:
                            new_filename = self.camera.start_recording(result['barcode'], selected_label)
                            self.current_transaction_id = self.db.create_transaction(result['barcode'], new_filename, selected_label)

                            # Update UI
                            self.recording_start_time = time.time()
                            self.update_ui_recording(True, new_filename, selected_label)
                            self.set_status_bar(
                                f"Switched to: {result['barcode']} ({selected_label}) (Saved: {recording_info['duration']}s)",
                                "success"
                            )
                            self.load_recordings()
                        except Exception as e:
                            logger.error(f"Error starting new recording: {e}")
                            messagebox.showerror("Error", f"Failed to start new recording: {str(e)}")

                    self.barcode_entry.delete(0, tk.END)
                    self.barcode_entry.focus()

                self._stop_recording_with_progress('barcode', on_stop_complete)

            elif result['action'] == 'stop':
                # Stop recording with progress dialog
                def on_stop_complete(recording_info):
                    if recording_info:
                        self.recording_start_time = None
                        self.current_transaction_id = None
                        self.update_ui_recording(False)
                        self.set_status_bar(
                            f"Recording stopped: {recording_info['duration']}s, {recording_info['file_size_mb']:.2f}MB",
                            "success"
                        )
                        self.load_recordings()

                    self.barcode_entry.delete(0, tk.END)
                    self.barcode_entry.focus()

                self._stop_recording_with_progress('barcode', on_stop_complete)

        except Exception as e:
            logger.error(f"Error processing barcode: {e}")
            messagebox.showerror("Error", f"Failed to process barcode: {str(e)}")

    def _stop_recording_with_progress(self, stop_type='manual', callback=None):
        """
        Stop recording with a progress dialog to prevent UI freeze.

        Args:
            stop_type: 'manual' or 'barcode' for database logging
            callback: Optional function to call with recording_info when done
        """
        if not self.camera.is_recording():
            if callback:
                callback(None)
            return

        # Show progress dialog
        progress = SavingProgressDialog(self.root, "Saving Recording")

        def do_stop():
            try:
                # Stop recording (this can take time if buffer has frames)
                recording_info = self.camera.stop_recording()
                progress.result = recording_info
            except Exception as e:
                progress.error = str(e)
                logger.error(f"Error stopping recording: {e}")

        def check_complete():
            if thread.is_alive():
                # Still running, check again
                self.root.after(50, check_complete)
            else:
                # Done - close dialog and process result
                progress.close()

                if progress.error:
                    messagebox.showerror("Error", f"Failed to save recording: {progress.error}")
                    if callback:
                        callback(None)
                    return

                recording_info = progress.result
                if recording_info:
                    # Update database
                    completed_transaction_id = self.current_transaction_id
                    if self.current_transaction_id:
                        self.db.complete_transaction(
                            self.current_transaction_id,
                            recording_info['duration'],
                            recording_info['file_size_mb'],
                            stop_type
                        )
                        # Queue compression
                        self.queue_video_compression(
                            recording_info['filename'],
                            completed_transaction_id,
                            recording_info.get('label_folder', 'Normal')
                        )

                if callback:
                    callback(recording_info)

        # Start stop in background thread
        thread = threading.Thread(target=do_stop, daemon=True)
        thread.start()

        # Check for completion
        self.root.after(50, check_complete)

    def manual_stop(self):
        """Manually stop recording."""
        if not self.camera.is_recording():
            messagebox.showwarning("Not Recording", "No recording in progress")
            return

        def on_stop_complete(recording_info):
            if recording_info:
                # Update UI
                self.recording_start_time = None
                self.current_transaction_id = None
                self.update_ui_recording(False)
                self.set_status_bar(
                    f"Recording stopped: {recording_info['duration']}s, {recording_info['file_size_mb']:.2f}MB",
                    "success"
                )
                # Reload recordings list
                self.load_recordings()
            self.barcode_entry.focus()

        self._stop_recording_with_progress('manual', on_stop_complete)

    def update_ui_recording(self, recording, filename="-", label=None):
        """Update UI based on recording state."""
        if recording:
            # Show recording indicator with label
            indicator_text = f"🔴 RECORDING: {filename}"
            if label:
                indicator_text += f" [{label}]"
            self.recording_indicator.configure(text=indicator_text)
            self.recording_indicator.grid(row=1, column=0, sticky=(tk.W, tk.E, tk.S), pady=(0, 5))

            # Update status
            self.status_label.configure(text="Recording", fg="red")
            self.filename_label.configure(text=filename, fg="red")

            # Keep input enabled for continuous scanning
            # User can scan next barcode to auto-stop-and-start
            self.submit_button.configure(state=tk.NORMAL)
            self.barcode_entry.configure(state=tk.NORMAL)
            self.stop_button.configure(state=tk.NORMAL)

        else:
            # Hide recording indicator
            self.recording_indicator.grid_forget()

            # Update status
            self.status_label.configure(text="Idle", fg="#6b7280")
            self.filename_label.configure(text="-", fg="#6b7280")
            self.duration_label.configure(text="00:00")

            # Keep input enabled, disable stop button
            self.submit_button.configure(state=tk.NORMAL)
            self.barcode_entry.configure(state=tk.NORMAL)
            self.stop_button.configure(state=tk.DISABLED)

    def load_recordings(self):
        """Load and display recent recordings with compression status."""
        try:
            recordings = self.db.get_recent_transactions(10)

            self.recordings_text.configure(state=tk.NORMAL)
            self.recordings_text.delete(1.0, tk.END)

            if not recordings:
                self.recordings_text.insert(tk.END, "No recordings yet.\n")
            else:
                for rec in recordings:
                    start_time = datetime.fromisoformat(rec['start_time']).strftime('%Y-%m-%d %H:%M:%S')
                    duration = rec['duration_seconds'] if rec['duration_seconds'] else 0
                    file_size = rec['file_size_mb'] if rec['file_size_mb'] else 0
                    label = rec.get('label') or 'Normal (Standard)'

                    # Get compression info
                    comp_status = rec.get('compression_status', 'pending')
                    comp_ratio = rec.get('compression_ratio')
                    comp_size = rec.get('compressed_file_size_mb')

                    # Format compression status display
                    if comp_status == 'completed' and comp_ratio:
                        comp_display = f"✓ Compressed ({comp_ratio:.1f}% smaller)"
                        if comp_size:
                            comp_display += f" → {comp_size:.2f}MB"
                    elif comp_status == 'processing':
                        comp_display = "⏳ Compressing..."
                    elif comp_status == 'pending':
                        comp_display = "⏳ Queued"
                    elif comp_status == 'failed':
                        comp_display = "✗ Failed"
                    elif comp_status == 'skipped':
                        comp_display = "⊘ Skipped"
                    else:
                        comp_display = f"? {comp_status}"

                    self.recordings_text.insert(tk.END, f"Barcode: {rec['barcode']}\n", "bold")
                    self.recordings_text.insert(tk.END, f"  Label: {label}\n")
                    self.recordings_text.insert(tk.END, f"  Started: {start_time}\n")
                    self.recordings_text.insert(tk.END, f"  Duration: {duration}s | Size: {file_size:.2f}MB\n")
                    self.recordings_text.insert(tk.END, f"  Compression: {comp_display}\n")
                    self.recordings_text.insert(tk.END, f"  File: {rec['video_filename']}\n")
                    self.recordings_text.insert(tk.END, "\n")

            self.recordings_text.configure(state=tk.DISABLED)

        except Exception as e:
            logger.error(f"Error loading recordings: {e}")

    def open_search_window(self):
        """Open the search recordings window."""
        SearchWindow(self.root, self.db, self)

    def open_video(self, video_path):
        """Open video file with default player."""
        try:
            # Normalize path separators for the current OS
            video_path = os.path.normpath(video_path)

            if not os.path.exists(video_path):
                messagebox.showerror("Error", f"Video file not found:\n{video_path}")
                return

            system = platform.system()
            if system == 'Windows':
                os.startfile(video_path)
            elif system == 'Darwin':  # macOS
                subprocess.run(['open', video_path])
            else:  # Linux
                subprocess.run(['xdg-open', video_path])

            logger.info(f"Opened video: {video_path}")
        except Exception as e:
            logger.error(f"Error opening video: {e}")
            messagebox.showerror("Error", f"Failed to open video: {str(e)}")

    def show_in_folder(self, video_path):
        """Show video file in folder."""
        try:
            # Normalize path separators for the current OS
            video_path = os.path.normpath(video_path)

            if not os.path.exists(video_path):
                messagebox.showerror("Error", f"Video file not found:\n{video_path}")
                return

            folder_path = os.path.dirname(video_path)
            system = platform.system()

            if system == 'Windows':
                subprocess.run(['explorer', '/select,', video_path])
            elif system == 'Darwin':  # macOS
                subprocess.run(['open', '-R', video_path])
            else:  # Linux
                subprocess.run(['xdg-open', folder_path])

            logger.info(f"Opened folder: {folder_path}")
        except Exception as e:
            logger.error(f"Error opening folder: {e}")
            messagebox.showerror("Error", f"Failed to open folder: {str(e)}")

    def set_status_bar(self, message, status_type="info"):
        """Set status bar message."""
        self.status_bar.configure(text=message)

        # Auto-clear after 5 seconds
        self.root.after(5000, lambda: self.status_bar.configure(text="Ready"))

    def open_settings(self):
        """Open settings dialog."""
        try:
            SettingsDialog(self.root, config.settings_manager, self)
        except Exception as e:
            logger.error(f"Error opening settings: {e}")
            messagebox.showerror("Error", f"Failed to open settings: {str(e)}")

    def on_compression_complete(self, transaction_id: int, success: bool, result_data: dict):
        """Callback when compression completes."""
        try:
            status = result_data.get('status', 'failed')
            compressed_size = result_data.get('compressed_file_size_mb')
            ratio = result_data.get('compression_ratio')
            filename = result_data.get('compressed_filename')

            self.db.update_compression_status(
                transaction_id=transaction_id,
                status=status,
                compressed_file_size_mb=compressed_size,
                compression_ratio=ratio,
                compressed_filename=filename
            )

            if success:
                self.compression_status = f"Compressed: {ratio:.1f}% reduction"
                logger.info(f"Compression completed for transaction {transaction_id}: {result_data.get('message', '')}")
            else:
                self.compression_status = f"Compression failed"
                logger.warning(f"Compression failed for transaction {transaction_id}: {result_data.get('message', '')}")

            # Update UI on main thread
            self.root.after(0, self.load_recordings)

        except Exception as e:
            logger.error(f"Error in compression callback: {e}")

    def queue_video_compression(self, video_filename: str, transaction_id: int, label_folder: str = "Normal"):
        """Queue a video for compression after recording completes."""
        try:
            # Build full video path (includes label folder)
            date_folder = datetime.now().strftime('%Y-%m-%d')
            video_path = os.path.join(config.VIDEO_STORAGE_PATH, date_folder, label_folder, video_filename)

            # Get compression settings
            compression_settings = config.settings_manager.settings.get('compression', {})

            if not compression_settings.get('enabled', False):
                logger.info("Compression disabled, skipping")
                return

            # Mark as processing in database
            self.db.update_compression_status(transaction_id, 'pending')

            # Queue the compression
            self.compressor.queue_compression(
                video_path=video_path,
                transaction_id=transaction_id,
                settings=compression_settings
            )

            self.compression_status = "Compression queued..."
            logger.info(f"Queued compression for {video_filename}")

        except Exception as e:
            logger.error(f"Error queuing video compression: {e}")

    def on_closing(self):
        """Handle application closing."""
        if self.camera.is_recording():
            if messagebox.askokcancel("Recording in Progress", "A recording is in progress. Stop and exit?"):
                try:
                    self.camera.stop_recording()
                except:
                    pass
            else:
                return

        self.update_running = False
        self.compressor.stop()  # Stop the compressor
        self.camera.cleanup()
        self.root.destroy()
        logger.info("Application closed")


class SearchWindow:
    """Beautiful search window for recordings."""

    def __init__(self, parent, database, main_app):
        """Initialize search window."""
        self.db = database
        self.main_app = main_app

        # Create window
        self.window = tk.Toplevel(parent)
        self.window.title("Search Recordings - Ecom Video Tracker")
        self.window.geometry("1000x700")
        self.window.minsize(700, 500)
        self.window.transient(parent)

        # Center window
        self.center_window()

        # Setup UI
        self.setup_ui()

        # Bind keyboard shortcuts
        self.window.bind('<Escape>', lambda e: self.window.destroy())
        self.window.bind('<Control-f>', lambda e: self.barcode_entry.focus())
        self.window.bind('<F5>', lambda e: self.perform_search())

        # Focus on barcode entry
        self.barcode_entry.focus()

        logger.info("Search window opened")

    def center_window(self):
        """Center the window on screen."""
        self.window.update_idletasks()
        width = self.window.winfo_width()
        height = self.window.winfo_height()
        x = (self.window.winfo_screenwidth() // 2) - (width // 2)
        y = (self.window.winfo_screenheight() // 2) - (height // 2)
        self.window.geometry(f'{width}x{height}+{x}+{y}')

    def setup_ui(self):
        """Setup the search window UI."""
        # Configure style
        style = ttk.Style()

        # Main container with gradient-like background
        main_frame = tk.Frame(self.window, bg='#f0f4f8')
        main_frame.pack(fill=tk.BOTH, expand=True)

        # Header
        self.create_header(main_frame)

        # Search filters
        self.create_filters(main_frame)

        # Results area
        self.create_results_area(main_frame)

        # Footer with stats
        self.create_footer(main_frame)

    def create_header(self, parent):
        """Create beautiful header."""
        header = tk.Frame(parent, bg='#667eea', height=80)
        header.pack(fill=tk.X)
        header.pack_propagate(False)

        # Title
        title_label = tk.Label(
            header,
            text="🔍 Search Recordings",
            font=("Arial", 20, "bold"),
            bg='#667eea',
            fg='white'
        )
        title_label.pack(side=tk.LEFT, padx=20, pady=20)

        # Close button
        close_btn = tk.Button(
            header,
            text="✕",
            font=("Arial", 16, "bold"),
            bg='#5568d3',
            fg='white',
            bd=0,
            cursor='hand2',
            width=3,
            command=self.window.destroy
        )
        close_btn.pack(side=tk.RIGHT, padx=20, pady=20)

        # Keyboard shortcuts hint
        hint_label = tk.Label(
            header,
            text="Press ESC to close | Ctrl+F to focus search | F5 to refresh",
            font=("Arial", 9),
            bg='#667eea',
            fg='white'
        )
        hint_label.pack(side=tk.RIGHT, padx=20)

    def create_filters(self, parent):
        """Create search filters section."""
        filters_frame = tk.Frame(parent, bg='white', pady=20)
        filters_frame.pack(fill=tk.X, padx=20, pady=(20, 10))

        # Filters container
        container = tk.Frame(filters_frame, bg='white')
        container.pack(fill=tk.X, padx=20)

        # Row 1: Barcode, Label, and dates
        row1 = tk.Frame(container, bg='white')
        row1.pack(fill=tk.X, pady=(0, 15))

        # Barcode
        barcode_frame = tk.Frame(row1, bg='white')
        barcode_frame.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10))

        tk.Label(
            barcode_frame,
            text="Barcode:",
            font=("Arial", 10, "bold"),
            bg='white',
            fg='#333'
        ).pack(anchor=tk.W, pady=(0, 5))

        self.barcode_entry = ttk.Entry(barcode_frame, font=("Arial", 11))
        self.barcode_entry.pack(fill=tk.X)
        self.barcode_entry.bind('<Return>', lambda e: self.perform_search())

        # Label filter
        label_frame = tk.Frame(row1, bg='white')
        label_frame.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10))

        tk.Label(
            label_frame,
            text="Label:",
            font=("Arial", 10, "bold"),
            bg='white',
            fg='#333'
        ).pack(anchor=tk.W, pady=(0, 5))

        self.search_label_var = tk.StringVar(value="All Labels")
        label_options = [
            "All Labels",
            "Return and Refund Unboxing",
            "Return Parcel Unboxing",
            "Normal (Standard)"
        ]
        self.search_label_combo = ttk.Combobox(
            label_frame,
            textvariable=self.search_label_var,
            values=label_options,
            state='readonly',
            font=("Arial", 10)
        )
        self.search_label_combo.pack(fill=tk.X)

        # Start Date with Calendar Picker
        start_frame = tk.Frame(row1, bg='white')
        start_frame.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10))

        tk.Label(
            start_frame,
            text="📅 Start Date:",
            font=("Arial", 10, "bold"),
            bg='white',
            fg='#333'
        ).pack(anchor=tk.W, pady=(0, 5))

        self.start_date_entry = DateEntry(
            start_frame,
            font=("Arial", 11),
            background='#667eea',
            foreground='white',
            borderwidth=2,
            date_pattern='yyyy-mm-dd',
            showweeknumbers=False,
            firstweekday='sunday',
            year=datetime.now().year,
            month=datetime.now().month,
            day=datetime.now().day
        )
        self.start_date_entry.pack(fill=tk.X)
        # Clear the date initially (optional filter)
        self.start_date_entry.delete(0, tk.END)

        # End Date with Calendar Picker
        end_frame = tk.Frame(row1, bg='white')
        end_frame.pack(side=tk.LEFT, fill=tk.X, expand=True)

        tk.Label(
            end_frame,
            text="📅 End Date:",
            font=("Arial", 10, "bold"),
            bg='white',
            fg='#333'
        ).pack(anchor=tk.W, pady=(0, 5))

        self.end_date_entry = DateEntry(
            end_frame,
            font=("Arial", 11),
            background='#667eea',
            foreground='white',
            borderwidth=2,
            date_pattern='yyyy-mm-dd',
            showweeknumbers=False,
            firstweekday='sunday',
            year=datetime.now().year,
            month=datetime.now().month,
            day=datetime.now().day
        )
        self.end_date_entry.pack(fill=tk.X)
        # Clear the date initially (optional filter)
        self.end_date_entry.delete(0, tk.END)

        # Row 2: Sort and actions
        row2 = tk.Frame(container, bg='white')
        row2.pack(fill=tk.X)

        # Sort by
        sort_frame = tk.Frame(row2, bg='white')
        sort_frame.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10))

        tk.Label(
            sort_frame,
            text="Sort By:",
            font=("Arial", 10, "bold"),
            bg='white',
            fg='#333'
        ).pack(anchor=tk.W, pady=(0, 5))

        self.sort_var = tk.StringVar(value="Date (Newest)")
        sort_options = ["Date (Newest)", "Date (Oldest)", "Barcode", "Duration", "File Size"]
        sort_combo = ttk.Combobox(sort_frame, textvariable=self.sort_var, values=sort_options, state='readonly', font=("Arial", 10))
        sort_combo.pack(fill=tk.X)

        # Buttons
        btn_frame = tk.Frame(row2, bg='white')
        btn_frame.pack(side=tk.LEFT, pady=(20, 0))

        search_btn = tk.Button(
            btn_frame,
            text="🔍 Search",
            font=("Arial", 11, "bold"),
            bg='#667eea',
            fg='white',
            cursor='hand2',
            bd=0,
            padx=30,
            pady=10,
            command=self.perform_search
        )
        search_btn.pack(side=tk.LEFT, padx=(0, 10))

        clear_btn = tk.Button(
            btn_frame,
            text="Clear",
            font=("Arial", 11),
            bg='#6b7280',
            fg='white',
            cursor='hand2',
            bd=0,
            padx=20,
            pady=10,
            command=self.clear_filters
        )
        clear_btn.pack(side=tk.LEFT)

    def create_results_area(self, parent):
        """Create results display area."""
        results_frame = tk.Frame(parent, bg='#f0f4f8')
        results_frame.pack(fill=tk.BOTH, expand=True, padx=20, pady=(0, 10))

        # Results header
        results_header = tk.Frame(results_frame, bg='white', pady=10)
        results_header.pack(fill=tk.X)

        self.results_label = tk.Label(
            results_header,
            text="Enter search criteria and click Search",
            font=("Arial", 11),
            bg='white',
            fg='#666'
        )
        self.results_label.pack(padx=20)

        # Scrollable results area
        canvas_frame = tk.Frame(results_frame, bg='#f0f4f8')
        canvas_frame.pack(fill=tk.BOTH, expand=True)

        # Canvas with scrollbar
        self.canvas = tk.Canvas(canvas_frame, bg='#f0f4f8', highlightthickness=0)
        scrollbar = ttk.Scrollbar(canvas_frame, orient="vertical", command=self.canvas.yview)
        self.scrollable_frame = tk.Frame(self.canvas, bg='#f0f4f8')

        self.scrollable_frame.bind(
            "<Configure>",
            lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all"))
        )

        self.canvas.create_window((0, 0), window=self.scrollable_frame, anchor="nw")
        self.canvas.configure(yscrollcommand=scrollbar.set)

        self.canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        # Mouse wheel scrolling
        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)

    def create_footer(self, parent):
        """Create footer with stats."""
        footer = tk.Frame(parent, bg='white', height=40)
        footer.pack(fill=tk.X)
        footer.pack_propagate(False)

        self.stats_label = tk.Label(
            footer,
            text="Ready to search",
            font=("Arial", 10),
            bg='white',
            fg='#666'
        )
        self.stats_label.pack(side=tk.LEFT, padx=20, pady=10)

    def clear_placeholder(self, entry, placeholder):
        """Clear placeholder text on focus."""
        if entry.get() == placeholder:
            entry.delete(0, tk.END)

    def _on_mousewheel(self, event):
        """Handle mouse wheel scrolling."""
        self.canvas.yview_scroll(int(-1*(event.delta/120)), "units")

    def clear_filters(self):
        """Clear all search filters."""
        self.barcode_entry.delete(0, tk.END)
        # Clear date entries (DateEntry widgets)
        self.start_date_entry.delete(0, tk.END)
        self.end_date_entry.delete(0, tk.END)
        self.search_label_var.set("All Labels")
        self.sort_var.set("Date (Newest)")

        # Clear results
        for widget in self.scrollable_frame.winfo_children():
            widget.destroy()

        self.results_label.config(text="Enter search criteria and click Search")
        self.stats_label.config(text="Ready to search")

    def perform_search(self):
        """Perform the search."""
        try:
            # Get search parameters
            barcode = self.barcode_entry.get().strip()
            start_date = self.start_date_entry.get().strip()
            end_date = self.end_date_entry.get().strip()
            label_filter = self.search_label_var.get()
            sort_option = self.sort_var.get()

            # Validate dates (DateEntry returns empty string if cleared)
            if not start_date:
                start_date = None
            if not end_date:
                end_date = None

            # Validate label filter
            if label_filter == "All Labels":
                label_filter = None

            # Parse sort option
            sort_by = "created_at"
            sort_order = "DESC"

            if sort_option == "Date (Oldest)":
                sort_by = "created_at"
                sort_order = "ASC"
            elif sort_option == "Barcode":
                sort_by = "barcode"
                sort_order = "ASC"
            elif sort_option == "Duration":
                sort_by = "duration_seconds"
                sort_order = "DESC"
            elif sort_option == "File Size":
                sort_by = "file_size_mb"
                sort_order = "DESC"

            # Perform search
            results = self.db.advanced_search(
                barcode=barcode if barcode else None,
                start_date=start_date,
                end_date=end_date,
                label=label_filter,
                sort_by=sort_by,
                sort_order=sort_order,
                limit=100
            )

            # Clear previous results
            for widget in self.scrollable_frame.winfo_children():
                widget.destroy()

            # Display results
            recordings = results['results']
            total = results['total']

            if not recordings:
                self.results_label.config(text="No recordings found")
                self.stats_label.config(text="0 results")
                return

            self.results_label.config(text=f"Found {total} recording(s)")
            self.stats_label.config(text=f"Showing {len(recordings)} of {total} results")

            # Display each recording as a card
            for idx, rec in enumerate(recordings):
                self.create_result_card(rec, idx)

        except Exception as e:
            logger.error(f"Error performing search: {e}")
            messagebox.showerror("Search Error", f"Failed to search: {str(e)}")

    def create_result_card(self, recording, index):
        """Create a beautiful card for each recording."""
        # Card frame with shadow effect
        card = tk.Frame(
            self.scrollable_frame,
            bg='white',
            relief=tk.FLAT,
            bd=0
        )
        card.pack(fill=tk.X, padx=10, pady=8)

        # Add hover effect
        card.bind("<Enter>", lambda e: card.config(bg='#f8f9fa'))
        card.bind("<Leave>", lambda e: card.config(bg='white'))

        # Inner padding
        inner = tk.Frame(card, bg='white')
        inner.pack(fill=tk.BOTH, padx=15, pady=15)

        # Header row
        header_row = tk.Frame(inner, bg='white')
        header_row.pack(fill=tk.X, pady=(0, 10))

        # Barcode (large and prominent)
        barcode_label = tk.Label(
            header_row,
            text=f"📦 {recording['barcode']}",
            font=("Arial", 14, "bold"),
            bg='white',
            fg='#667eea'
        )
        barcode_label.pack(side=tk.LEFT)

        # Label badge - handle None values from database
        label = recording.get('label') or 'Normal (Standard)'
        label_colors = {
            'Return and Refund Unboxing': '#dc2626',
            'Return Parcel Unboxing': '#f59e0b',
            'Normal (Standard)': '#10b981'
        }
        badge_color = label_colors.get(label, '#10b981')

        label_badge = tk.Label(
            header_row,
            text=label,
            font=("Arial", 9),
            bg=badge_color,
            fg='white',
            padx=8,
            pady=2
        )
        label_badge.pack(side=tk.RIGHT)

        # Details row
        details_row = tk.Frame(inner, bg='white')
        details_row.pack(fill=tk.X, pady=(0, 10))

        # Format details
        start_time = datetime.fromisoformat(recording['start_time']).strftime('%Y-%m-%d %H:%M:%S')
        duration = recording['duration_seconds'] if recording['duration_seconds'] else 0
        file_size = recording['file_size_mb'] if recording['file_size_mb'] else 0

        details_text = f"📅 {start_time}   |   ⏱️ {duration}s   |   💾 {file_size:.2f}MB"

        details_label = tk.Label(
            details_row,
            text=details_text,
            font=("Arial", 10),
            bg='white',
            fg='#666'
        )
        details_label.pack(side=tk.LEFT)

        # Filename row
        filename_label = tk.Label(
            inner,
            text=f"📄 {recording['video_filename']}",
            font=("Courier", 9),
            bg='white',
            fg='#888'
        )
        filename_label.pack(anchor=tk.W, pady=(0, 10))

        # Action buttons
        actions_frame = tk.Frame(inner, bg='white')
        actions_frame.pack(fill=tk.X)

        # Build video path - check both new (with label folder) and old (without) paths
        date_folder = datetime.fromisoformat(recording['start_time']).strftime('%Y-%m-%d')
        label_folder_map = {
            "Return and Refund Unboxing": "Return and Refund",
            "Return Parcel Unboxing": "Return Parcel",
            "Normal (Standard)": "Normal"
        }
        label_folder = label_folder_map.get(label, "Normal")

        # Try new path with label folder first
        video_path = os.path.join(config.VIDEO_STORAGE_PATH, date_folder, label_folder, recording['video_filename'])

        # Fall back to old path without label folder if not found
        if not os.path.exists(video_path):
            video_path = os.path.join(config.VIDEO_STORAGE_PATH, date_folder, recording['video_filename'])

        # Play button
        play_btn = tk.Button(
            actions_frame,
            text="▶️ Play Video",
            font=("Arial", 10, "bold"),
            bg='#667eea',
            fg='white',
            cursor='hand2',
            bd=0,
            padx=15,
            pady=8,
            command=lambda vp=video_path: self.main_app.open_video(vp)
        )
        play_btn.pack(side=tk.LEFT, padx=(0, 10))

        # Folder button
        folder_btn = tk.Button(
            actions_frame,
            text="📁 Show in Folder",
            font=("Arial", 10),
            bg='#6b7280',
            fg='white',
            cursor='hand2',
            bd=0,
            padx=15,
            pady=8,
            command=lambda vp=video_path: self.main_app.show_in_folder(vp)
        )
        folder_btn.pack(side=tk.LEFT)

        # Separator line
        separator = tk.Frame(self.scrollable_frame, bg='#e5e7eb', height=1)
        separator.pack(fill=tk.X, padx=10)


class SettingsDialog:
    """Settings dialog window."""

    RESOLUTION_PRESETS = [
        ("640x480", (640, 480)),
        ("1280x720 (HD)", (1280, 720)),
        ("1920x1080 (Full HD)", (1920, 1080)),
        ("2560x1440 (2K)", (2560, 1440)),
        ("3840x2160 (4K)", (3840, 2160))
    ]

    CODEC_OPTIONS = [
        ("MP4V (Recommended)", "mp4v"),
        ("H264", "avc1"),
        ("XVID", "XVID"),
        ("MJPEG", "MJPG")
    ]

    FPS_OPTIONS = [15, 24, 30, 60]

    def __init__(self, parent, settings_manager: SettingsManager, main_app):
        """Initialize settings dialog."""
        self.settings_manager = settings_manager
        self.main_app = main_app

        # Create dialog window
        self.dialog = tk.Toplevel(parent)
        self.dialog.title("Settings - Ecom Video Tracker")
        self.dialog.resizable(True, True)
        self.dialog.minsize(450, 400)
        self.dialog.transient(parent)
        # Don't use grab_set() - it causes UI lag with continuous camera updates

        # Load current settings
        self.current_settings = settings_manager.get_all()

        # Setup UI
        self.setup_ui()

        # Auto-size to content and center dialog
        self.dialog.update_idletasks()
        width = self.dialog.winfo_reqwidth()
        height = self.dialog.winfo_reqheight()
        x = (self.dialog.winfo_screenwidth() // 2) - (width // 2)
        y = (self.dialog.winfo_screenheight() // 2) - (height // 2)
        self.dialog.geometry(f"{width}x{height}+{x}+{y}")

    def setup_ui(self):
        """Setup dialog UI."""
        # Main container
        main_frame = ttk.Frame(self.dialog, padding="20")
        main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        main_frame.columnconfigure(0, weight=1)

        # Title
        title_label = ttk.Label(
            main_frame,
            text="Application Settings",
            font=("Arial", 14, "bold")
        )
        title_label.grid(row=0, column=0, sticky=tk.W, pady=(0, 20))

        # Notebook for tabs
        notebook = ttk.Notebook(main_frame)
        notebook.grid(row=1, column=0, sticky=(tk.W, tk.E, tk.N, tk.S), pady=(0, 20))

        # Create tabs
        self.create_video_tab(notebook)
        self.create_camera_tab(notebook)
        self.create_compression_tab(notebook)
        self.create_storage_tab(notebook)
        self.create_app_tab(notebook)

        # Buttons
        button_frame = ttk.Frame(main_frame)
        button_frame.grid(row=2, column=0, sticky=(tk.W, tk.E))
        button_frame.columnconfigure(0, weight=1)
        button_frame.columnconfigure(1, weight=1)
        button_frame.columnconfigure(2, weight=1)

        reset_btn = ttk.Button(
            button_frame,
            text="Reset to Defaults",
            command=self.reset_defaults
        )
        reset_btn.grid(row=0, column=0, sticky=(tk.W, tk.E), padx=(0, 5))

        cancel_btn = ttk.Button(
            button_frame,
            text="Cancel",
            command=self.dialog.destroy
        )
        cancel_btn.grid(row=0, column=1, sticky=(tk.W, tk.E), padx=5)

        save_btn = ttk.Button(
            button_frame,
            text="Save & Apply",
            command=self.save_settings
        )
        save_btn.grid(row=0, column=2, sticky=(tk.W, tk.E), padx=(5, 0))

    def create_video_tab(self, notebook):
        """Create video settings tab."""
        tab = ttk.Frame(notebook, padding="10")
        notebook.add(tab, text="Video")

        # Resolution
        ttk.Label(tab, text="Resolution:", font=("Arial", 10, "bold")).grid(
            row=0, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.resolution_var = tk.StringVar()
        current_res = self.current_settings['video']['resolution_width'], \
                     self.current_settings['video']['resolution_height']

        # Find matching preset
        selected_preset = "1280x720 (HD)"
        for name, res in self.RESOLUTION_PRESETS:
            if res == current_res:
                selected_preset = name
                break

        self.resolution_var.set(selected_preset)

        resolution_combo = ttk.Combobox(
            tab,
            textvariable=self.resolution_var,
            values=[name for name, _ in self.RESOLUTION_PRESETS],
            state='readonly',
            width=28
        )
        resolution_combo.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        # FPS
        ttk.Label(tab, text="FPS (Frames Per Second):", font=("Arial", 10, "bold")).grid(
            row=2, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.fps_var = tk.IntVar(value=self.current_settings['video']['fps'])

        fps_frame = ttk.Frame(tab)
        fps_frame.grid(row=3, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        for fps in self.FPS_OPTIONS:
            rb = ttk.Radiobutton(
                fps_frame,
                text=f"{fps} FPS",
                variable=self.fps_var,
                value=fps
            )
            rb.pack(side=tk.LEFT, padx=(0, 10))

        # Codec
        ttk.Label(tab, text="Video Codec:", font=("Arial", 10, "bold")).grid(
            row=4, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.codec_var = tk.StringVar()
        current_codec = self.current_settings['video']['codec']

        # Find matching codec
        selected_codec = "MP4V (Recommended)"
        for name, codec in self.CODEC_OPTIONS:
            if codec == current_codec:
                selected_codec = name
                break

        self.codec_var.set(selected_codec)

        codec_combo = ttk.Combobox(
            tab,
            textvariable=self.codec_var,
            values=[name for name, _ in self.CODEC_OPTIONS],
            state='readonly',
            width=28
        )
        codec_combo.grid(row=5, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        # Info text
        info_label = ttk.Label(
            tab,
            text="Note: Higher resolution and FPS require more storage.",
            font=("Arial", 9, "italic"),
            foreground="gray"
        )
        info_label.grid(row=6, column=0, sticky=tk.W, pady=(5, 0))

    def create_camera_tab(self, notebook):
        """Create camera settings tab."""
        tab = ttk.Frame(notebook, padding="10")
        notebook.add(tab, text="Camera")

        # Camera selection
        ttk.Label(tab, text="Select Camera:", font=("Arial", 10, "bold")).grid(
            row=0, column=0, sticky=tk.W, pady=(0, 3)
        )

        # Get available cameras (use fast method to avoid lag)
        self.available_cameras = get_available_cameras_fast()

        camera_frame = ttk.Frame(tab)
        camera_frame.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 10))
        camera_frame.columnconfigure(0, weight=1)

        # Create camera selection dropdown
        self.camera_var = tk.StringVar()

        # Build camera options
        camera_options = []
        current_index = self.current_settings['camera']['index']
        selected_option = None

        for cam in self.available_cameras:
            status = "✓" if cam['working'] else "✗"
            option = f"{status} {cam['name']} (Index {cam['index']}) - {cam['resolution']}"
            camera_options.append(option)

            if cam['index'] == current_index:
                selected_option = option

        if selected_option is None and camera_options:
            selected_option = camera_options[0]

        self.camera_var.set(selected_option if selected_option else "No cameras detected")

        camera_combo = ttk.Combobox(
            camera_frame,
            textvariable=self.camera_var,
            values=camera_options,
            state='readonly',
            width=60
        )
        camera_combo.grid(row=0, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        # Refresh cameras button
        refresh_btn = ttk.Button(
            camera_frame,
            text="Refresh Cameras",
            command=self.refresh_cameras
        )
        refresh_btn.grid(row=1, column=0, sticky=tk.W)

        # Camera info
        info_label = ttk.Label(
            tab,
            text="Click 'Refresh' if camera not shown.",
            font=("Arial", 9),
            foreground="gray",
            justify=tk.LEFT
        )
        info_label.grid(row=2, column=0, sticky=tk.W, pady=(5, 0))

        # Separator
        separator = ttk.Separator(tab, orient='horizontal')
        separator.grid(row=3, column=0, sticky=(tk.W, tk.E), pady=15)

        # ===== Exposure Settings Section =====
        ttk.Label(tab, text="Exposure Settings:", font=("Arial", 10, "bold")).grid(
            row=4, column=0, sticky=tk.W, pady=(0, 10)
        )

        # Get current exposure settings
        camera_settings = self.current_settings.get('camera', {})

        # Auto-exposure checkbox
        self.auto_exposure_var = tk.BooleanVar(value=camera_settings.get('auto_exposure', True))
        auto_exp_check = ttk.Checkbutton(
            tab,
            text="Auto Exposure (uncheck for manual control)",
            variable=self.auto_exposure_var,
            command=self._toggle_exposure_controls
        )
        auto_exp_check.grid(row=5, column=0, sticky=tk.W, pady=(0, 10))

        # Manual exposure controls frame
        self.exposure_controls_frame = ttk.Frame(tab)
        self.exposure_controls_frame.grid(row=6, column=0, sticky=(tk.W, tk.E), pady=(0, 5))

        # Exposure slider (-13 to -1)
        exp_row = ttk.Frame(self.exposure_controls_frame)
        exp_row.pack(fill=tk.X, pady=2)
        ttk.Label(exp_row, text="Exposure:", width=12).pack(side=tk.LEFT)
        self.exposure_var = tk.IntVar(value=camera_settings.get('exposure', -4))
        self.exposure_scale = ttk.Scale(
            exp_row, from_=-13, to=-1, variable=self.exposure_var,
            orient=tk.HORIZONTAL, length=180,
            command=lambda v: self._on_exposure_change()
        )
        self.exposure_scale.pack(side=tk.LEFT, padx=(0, 10))
        self.exposure_value_label = ttk.Label(exp_row, text=f"{self.exposure_var.get()}", width=4)
        self.exposure_value_label.pack(side=tk.LEFT)
        ttk.Label(exp_row, text="(darker <-> brighter)", font=("Arial", 8), foreground="gray").pack(side=tk.LEFT, padx=(10, 0))

        # Gain slider (0 to 255)
        gain_row = ttk.Frame(self.exposure_controls_frame)
        gain_row.pack(fill=tk.X, pady=2)
        ttk.Label(gain_row, text="Gain:", width=12).pack(side=tk.LEFT)
        self.gain_var = tk.IntVar(value=camera_settings.get('gain', 0))
        self.gain_scale = ttk.Scale(
            gain_row, from_=0, to=255, variable=self.gain_var,
            orient=tk.HORIZONTAL, length=180,
            command=lambda v: self._on_exposure_change()
        )
        self.gain_scale.pack(side=tk.LEFT, padx=(0, 10))
        self.gain_value_label = ttk.Label(gain_row, text=f"{self.gain_var.get()}", width=4)
        self.gain_value_label.pack(side=tk.LEFT)
        ttk.Label(gain_row, text="(amplification)", font=("Arial", 8), foreground="gray").pack(side=tk.LEFT, padx=(10, 0))

        # Brightness slider (0 to 255)
        bright_row = ttk.Frame(self.exposure_controls_frame)
        bright_row.pack(fill=tk.X, pady=2)
        ttk.Label(bright_row, text="Brightness:", width=12).pack(side=tk.LEFT)
        self.brightness_var = tk.IntVar(value=camera_settings.get('brightness', 128))
        self.brightness_scale = ttk.Scale(
            bright_row, from_=0, to=255, variable=self.brightness_var,
            orient=tk.HORIZONTAL, length=180,
            command=lambda v: self._on_exposure_change()
        )
        self.brightness_scale.pack(side=tk.LEFT, padx=(0, 10))
        self.brightness_value_label = ttk.Label(bright_row, text=f"{self.brightness_var.get()}", width=4)
        self.brightness_value_label.pack(side=tk.LEFT)
        ttk.Label(bright_row, text="(image brightness)", font=("Arial", 8), foreground="gray").pack(side=tk.LEFT, padx=(10, 0))

        # Live preview checkbox
        self.live_preview_var = tk.BooleanVar(value=True)
        live_preview_check = ttk.Checkbutton(
            tab,
            text="Live Preview (apply changes immediately)",
            variable=self.live_preview_var
        )
        live_preview_check.grid(row=7, column=0, sticky=tk.W, pady=(10, 5))

        # Exposure info
        exp_info_label = ttk.Label(
            tab,
            text="Tip: Lower exposure and gain reduce light sensitivity and noise.",
            font=("Arial", 8, "italic"),
            foreground="gray"
        )
        exp_info_label.grid(row=8, column=0, sticky=tk.W, pady=(5, 0))

        # Initialize control state
        self._toggle_exposure_controls()

    def _toggle_exposure_controls(self):
        """Enable or disable manual exposure controls based on auto-exposure checkbox."""
        state = 'disabled' if self.auto_exposure_var.get() else 'normal'
        for child in self.exposure_controls_frame.winfo_children():
            for widget in child.winfo_children():
                if isinstance(widget, (ttk.Scale, ttk.Entry)):
                    widget.configure(state=state)
        # Apply change immediately if live preview enabled
        if hasattr(self, 'live_preview_var') and self.live_preview_var.get():
            self._apply_live_exposure()

    def _on_exposure_change(self):
        """Handle exposure slider changes with throttling."""
        # Update value labels immediately
        self.exposure_value_label.configure(text=f"{int(self.exposure_var.get())}")
        self.gain_value_label.configure(text=f"{int(self.gain_var.get())}")
        self.brightness_value_label.configure(text=f"{int(self.brightness_var.get())}")

        # Throttle camera updates to avoid lag
        if hasattr(self, 'live_preview_var') and self.live_preview_var.get():
            # Cancel any pending exposure update
            if hasattr(self, '_exposure_update_id') and self._exposure_update_id:
                self.dialog.after_cancel(self._exposure_update_id)
            # Schedule update after 100ms of no changes
            self._exposure_update_id = self.dialog.after(100, self._apply_live_exposure)

    def _apply_live_exposure(self):
        """Apply exposure settings to camera in real-time."""
        try:
            if self.main_app and hasattr(self.main_app, 'camera') and self.main_app.camera:
                self.main_app.camera.apply_exposure_settings(
                    auto_exposure=self.auto_exposure_var.get(),
                    exposure=int(self.exposure_var.get()),
                    gain=int(self.gain_var.get()),
                    brightness=int(self.brightness_var.get())
                )
        except Exception as e:
            logger.warning(f"Could not apply live exposure settings: {e}")

    def create_compression_tab(self, notebook):
        """Create compression settings tab."""
        tab = ttk.Frame(notebook, padding="10")
        notebook.add(tab, text="Compression")

        # Get current compression settings
        compression_settings = self.current_settings.get('compression', {})

        # Enable compression checkbox
        self.compression_enabled_var = tk.BooleanVar(value=compression_settings.get('enabled', True))
        enable_check = ttk.Checkbutton(
            tab,
            text="Enable Auto-Compression (requires FFmpeg)",
            variable=self.compression_enabled_var
        )
        enable_check.grid(row=0, column=0, sticky=tk.W, pady=(0, 15))

        # FFmpeg status
        ffmpeg_frame = ttk.Frame(tab)
        ffmpeg_frame.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 15))

        self.ffmpeg_status_label = ttk.Label(
            ffmpeg_frame,
            text="Checking FFmpeg...",
            font=("Arial", 9)
        )
        self.ffmpeg_status_label.pack(side=tk.LEFT)

        # Check FFmpeg status
        self._check_ffmpeg_status()

        # Codec selection
        ttk.Label(tab, text="Compression Codec:", font=("Arial", 10, "bold")).grid(
            row=2, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.compression_codec_var = tk.StringVar(value=compression_settings.get('codec', 'h264'))
        codec_frame = ttk.Frame(tab)
        codec_frame.grid(row=3, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        ttk.Radiobutton(
            codec_frame, text="H.264 (Faster, Compatible)",
            variable=self.compression_codec_var, value='h264'
        ).pack(side=tk.LEFT, padx=(0, 15))
        ttk.Radiobutton(
            codec_frame, text="H.265/HEVC (Smaller, Slower)",
            variable=self.compression_codec_var, value='h265'
        ).pack(side=tk.LEFT)

        # Quality (CRF)
        ttk.Label(tab, text="Quality (CRF):", font=("Arial", 10, "bold")).grid(
            row=4, column=0, sticky=tk.W, pady=(0, 3)
        )

        crf_frame = ttk.Frame(tab)
        crf_frame.grid(row=5, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        self.compression_crf_var = tk.IntVar(value=compression_settings.get('crf', 23))
        crf_scale = ttk.Scale(
            crf_frame, from_=18, to=35, variable=self.compression_crf_var,
            orient=tk.HORIZONTAL, length=200
        )
        crf_scale.pack(side=tk.LEFT)

        self.crf_value_label = ttk.Label(crf_frame, text=f"{self.compression_crf_var.get()}")
        self.crf_value_label.pack(side=tk.LEFT, padx=(10, 0))

        # Update label when scale changes
        def update_crf_label(*args):
            self.crf_value_label.configure(text=f"{int(self.compression_crf_var.get())}")
        self.compression_crf_var.trace('w', update_crf_label)

        ttk.Label(
            tab, text="Lower = Better Quality, Larger File | Higher = Lower Quality, Smaller File",
            font=("Arial", 8), foreground="gray"
        ).grid(row=6, column=0, sticky=tk.W, pady=(0, 10))

        # Preset
        ttk.Label(tab, text="Encoding Speed:", font=("Arial", 10, "bold")).grid(
            row=7, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.compression_preset_var = tk.StringVar(value=compression_settings.get('preset', 'medium'))
        preset_combo = ttk.Combobox(
            tab,
            textvariable=self.compression_preset_var,
            values=['ultrafast', 'fast', 'medium', 'slow'],
            state='readonly',
            width=20
        )
        preset_combo.grid(row=8, column=0, sticky=tk.W, pady=(0, 10))

        ttk.Label(
            tab, text="Slower = Better compression ratio",
            font=("Arial", 8), foreground="gray"
        ).grid(row=9, column=0, sticky=tk.W, pady=(0, 10))

        # Delete original checkbox
        self.compression_delete_original_var = tk.BooleanVar(
            value=compression_settings.get('delete_original', True)
        )
        delete_check = ttk.Checkbutton(
            tab,
            text="Delete original file after successful compression",
            variable=self.compression_delete_original_var
        )
        delete_check.grid(row=10, column=0, sticky=tk.W, pady=(0, 10))

        # Process Priority
        ttk.Label(tab, text="Process Priority:", font=("Arial", 10, "bold")).grid(
            row=11, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.compression_priority_var = tk.StringVar(value=compression_settings.get('priority', 'below_normal'))
        priority_combo = ttk.Combobox(
            tab,
            textvariable=self.compression_priority_var,
            values=['low', 'below_normal', 'normal'],
            state='readonly',
            width=20
        )
        priority_combo.grid(row=12, column=0, sticky=tk.W, pady=(0, 10))

        ttk.Label(
            tab, text="Lower priority = Less system impact during compression",
            font=("Arial", 8), foreground="gray"
        ).grid(row=13, column=0, sticky=tk.W, pady=(0, 10))

    def _check_ffmpeg_status(self):
        """Check and update FFmpeg status label."""
        try:
            from video_compressor import VideoCompressor
            temp_compressor = VideoCompressor()
            available, message = temp_compressor.check_ffmpeg_installed()
            if available:
                self.ffmpeg_status_label.configure(text=f"✓ {message}", foreground="green")
            else:
                self.ffmpeg_status_label.configure(text=f"✗ {message}", foreground="red")
        except Exception as e:
            self.ffmpeg_status_label.configure(text=f"✗ Error: {str(e)}", foreground="red")

    def create_storage_tab(self, notebook):
        """Create storage settings tab."""
        tab = ttk.Frame(notebook, padding="10")
        notebook.add(tab, text="Storage")

        # Video storage path
        ttk.Label(tab, text="Video Storage Path:", font=("Arial", 10, "bold")).grid(
            row=0, column=0, sticky=tk.W, pady=(0, 3)
        )

        video_path_frame = ttk.Frame(tab)
        video_path_frame.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 10))
        video_path_frame.columnconfigure(0, weight=1)

        self.video_path_var = tk.StringVar(value=self.current_settings['storage']['video_path'])

        video_path_entry = ttk.Entry(video_path_frame, textvariable=self.video_path_var, width=35)
        video_path_entry.grid(row=0, column=0, sticky=(tk.W, tk.E), padx=(0, 5))

        video_browse_btn = ttk.Button(
            video_path_frame,
            text="Browse",
            command=lambda: self.browse_folder(self.video_path_var)
        )
        video_browse_btn.grid(row=0, column=1)

        # Database path
        ttk.Label(tab, text="Database Path:", font=("Arial", 10, "bold")).grid(
            row=2, column=0, sticky=tk.W, pady=(0, 3)
        )

        db_path_frame = ttk.Frame(tab)
        db_path_frame.grid(row=3, column=0, sticky=(tk.W, tk.E), pady=(0, 10))
        db_path_frame.columnconfigure(0, weight=1)

        self.db_path_var = tk.StringVar(value=self.current_settings['storage']['database_path'])

        db_path_entry = ttk.Entry(db_path_frame, textvariable=self.db_path_var, width=35)
        db_path_entry.grid(row=0, column=0, sticky=(tk.W, tk.E), padx=(0, 5))

        db_browse_btn = ttk.Button(
            db_path_frame,
            text="Browse",
            command=lambda: self.browse_file(self.db_path_var, [("Database", "*.db"), ("All files", "*.*")])
        )
        db_browse_btn.grid(row=0, column=1)

        # Log path
        ttk.Label(tab, text="Log Storage Path:", font=("Arial", 10, "bold")).grid(
            row=4, column=0, sticky=tk.W, pady=(0, 3)
        )

        log_path_frame = ttk.Frame(tab)
        log_path_frame.grid(row=5, column=0, sticky=(tk.W, tk.E), pady=(0, 10))
        log_path_frame.columnconfigure(0, weight=1)

        self.log_path_var = tk.StringVar(value=self.current_settings['storage']['log_path'])

        log_path_entry = ttk.Entry(log_path_frame, textvariable=self.log_path_var, width=35)
        log_path_entry.grid(row=0, column=0, sticky=(tk.W, tk.E), padx=(0, 5))

        log_browse_btn = ttk.Button(
            log_path_frame,
            text="Browse",
            command=lambda: self.browse_folder(self.log_path_var)
        )
        log_browse_btn.grid(row=0, column=1)

        # Info text
        info_label = ttk.Label(
            tab,
            text="Use relative or absolute paths. Restart app after changes.",
            font=("Arial", 9, "italic"),
            foreground="gray"
        )
        info_label.grid(row=6, column=0, sticky=tk.W, pady=(5, 0))

    def create_app_tab(self, notebook):
        """Create application settings tab."""
        tab = ttk.Frame(notebook, padding="10")
        notebook.add(tab, text="Web App")

        # Flask host
        ttk.Label(tab, text="Flask Host:", font=("Arial", 10, "bold")).grid(
            row=0, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.flask_host_var = tk.StringVar(value=self.current_settings['app']['flask_host'])

        host_entry = ttk.Entry(tab, textvariable=self.flask_host_var, width=25)
        host_entry.grid(row=1, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        # Flask port
        ttk.Label(tab, text="Flask Port:", font=("Arial", 10, "bold")).grid(
            row=2, column=0, sticky=tk.W, pady=(0, 3)
        )

        self.flask_port_var = tk.IntVar(value=self.current_settings['app']['flask_port'])

        port_spinbox = ttk.Spinbox(
            tab,
            from_=1024,
            to=65535,
            textvariable=self.flask_port_var,
            width=25
        )
        port_spinbox.grid(row=3, column=0, sticky=(tk.W, tk.E), pady=(0, 10))

        # Debug mode
        self.debug_mode_var = tk.BooleanVar(value=self.current_settings['app']['debug_mode'])

        debug_check = ttk.Checkbutton(
            tab,
            text="Enable Debug Mode",
            variable=self.debug_mode_var
        )
        debug_check.grid(row=4, column=0, sticky=tk.W, pady=(0, 10))

        # Info text
        info_label = ttk.Label(
            tab,
            text="0.0.0.0 = network access | 127.0.0.1 = localhost only",
            font=("Arial", 9),
            foreground="gray"
        )
        info_label.grid(row=5, column=0, sticky=tk.W, pady=(5, 0))

    def browse_folder(self, var):
        """Browse for folder."""
        folder = filedialog.askdirectory()
        if folder:
            var.set(folder)

    def browse_file(self, var, filetypes):
        """Browse for file."""
        filename = filedialog.askopenfilename(filetypes=filetypes)
        if filename:
            var.set(filename)

    def refresh_cameras(self):
        """Refresh the list of available cameras in background."""
        # Show refreshing status
        self.camera_var.set("Refreshing cameras...")

        def on_cameras_found(cameras):
            """Callback when camera detection completes."""
            try:
                self.available_cameras = cameras

                # Rebuild camera options
                camera_options = []
                current_index = self.current_settings['camera']['index']
                selected_option = None

                for cam in cameras:
                    status = "✓" if cam['working'] else "✗"
                    option = f"{status} {cam['name']} (Index {cam['index']}) - {cam['resolution']}"
                    camera_options.append(option)

                    if cam['index'] == current_index:
                        selected_option = option

                if selected_option is None and camera_options:
                    selected_option = camera_options[0]

                # Update combobox (schedule on main thread)
                def update_ui():
                    for widget in self.dialog.winfo_children():
                        if isinstance(widget, ttk.Notebook):
                            notebook = widget
                            camera_tab = notebook.nametowidget(notebook.tabs()[1])
                            for child in camera_tab.winfo_children():
                                if isinstance(child, ttk.Frame):
                                    for subchild in child.winfo_children():
                                        if isinstance(subchild, ttk.Combobox):
                                            subchild['values'] = camera_options
                                            self.camera_var.set(selected_option if selected_option else "No cameras detected")
                                            break

                self.dialog.after(0, update_ui)

            except Exception as e:
                logger.error(f"Error updating camera list: {e}")

        # Run detection in background
        refresh_cameras_async(callback=on_cameras_found)

    def reset_defaults(self):
        """Reset settings to defaults."""
        if messagebox.askyesno("Reset Settings", "Reset all settings to default values?"):
            self.settings_manager.reset_to_defaults()
            self.dialog.destroy()
            messagebox.showinfo("Settings Reset", "Settings have been reset to defaults.\nThe camera will restart automatically.")

    def save_settings(self):
        """Save settings."""
        try:
            # Parse resolution
            selected_res = self.resolution_var.get()
            width, height = 1280, 720
            for name, res in self.RESOLUTION_PRESETS:
                if name == selected_res:
                    width, height = res
                    break

            # Parse codec
            selected_codec = self.codec_var.get()
            codec = "mp4v"
            for name, c in self.CODEC_OPTIONS:
                if name == selected_codec:
                    codec = c
                    break

            # Parse camera index from selection
            camera_index = 0
            camera_selection = self.camera_var.get()
            if "(Index " in camera_selection:
                try:
                    start = camera_selection.index("(Index ") + 7
                    end = camera_selection.index(")", start)
                    camera_index = int(camera_selection[start:end])
                except:
                    logger.warning("Could not parse camera index, using 0")

            # Update video settings
            self.settings_manager.update_category('video', {
                'resolution_width': width,
                'resolution_height': height,
                'fps': self.fps_var.get(),
                'codec': codec
            })

            # Update camera settings
            self.settings_manager.update_category('camera', {
                'index': camera_index,
                'auto_exposure': self.auto_exposure_var.get(),
                'exposure': int(self.exposure_var.get()),
                'gain': int(self.gain_var.get()),
                'brightness': int(self.brightness_var.get())
            })

            # Update storage settings
            self.settings_manager.update_category('storage', {
                'video_path': self.video_path_var.get(),
                'database_path': self.db_path_var.get(),
                'log_path': self.log_path_var.get()
            })

            # Update app settings
            self.settings_manager.update_category('app', {
                'flask_host': self.flask_host_var.get(),
                'flask_port': self.flask_port_var.get(),
                'debug_mode': self.debug_mode_var.get()
            })

            # Update compression settings
            self.settings_manager.update_category('compression', {
                'enabled': self.compression_enabled_var.get(),
                'codec': self.compression_codec_var.get(),
                'crf': int(self.compression_crf_var.get()),
                'preset': self.compression_preset_var.get(),
                'delete_original': self.compression_delete_original_var.get(),
                'priority': self.compression_priority_var.get()
            })

            # Save to file
            if self.settings_manager.save_settings():
                # Close dialog first
                self.dialog.destroy()

                # Reinitialize camera in background with progress
                self._reinitialize_camera_async()
            else:
                messagebox.showerror("Error", "Failed to save settings")

        except Exception as e:
            logger.error(f"Error saving settings: {e}")
            messagebox.showerror("Error", f"Failed to save settings: {str(e)}")

    def _reinitialize_camera_async(self):
        """Reinitialize camera in background with progress dialog."""
        # Show progress dialog
        progress = SavingProgressDialog(self.main_app.root, "Applying Settings")
        progress.update_status("Restarting camera...", "Please wait...")

        result = {'success': False, 'error': None}

        def do_reinit():
            try:
                self.main_app.camera.reinitialize()
                result['success'] = True
            except Exception as e:
                result['error'] = str(e)
                logger.error(f"Error reinitializing camera: {e}")

        def check_complete():
            if thread.is_alive():
                self.main_app.root.after(50, check_complete)
            else:
                progress.close()
                if result['success']:
                    messagebox.showinfo(
                        "Settings Saved",
                        "Settings saved and camera restarted."
                    )
                else:
                    messagebox.showwarning(
                        "Settings Saved",
                        f"Settings saved but camera restart failed.\n\n"
                        f"Error: {result['error']}\n\n"
                        "Please restart the application."
                    )

        thread = threading.Thread(target=do_reinit, daemon=True)
        thread.start()
        self.main_app.root.after(50, check_complete)


def main():
    """Main entry point."""
    root = tk.Tk()
    app = EcomVideoTrackerApp(root)
    root.mainloop()


if __name__ == '__main__':
    main()
