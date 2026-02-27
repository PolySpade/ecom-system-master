"""
Bulk Video Compressor - Standalone tool for compressing multiple video files
"""
import os
import sys
import subprocess
import threading
import queue
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from dataclasses import dataclass
from typing import List, Optional, Tuple
from datetime import datetime

# Windows process priority flags
PRIORITY_FLAGS = {
    'low': 0x00000040,         # IDLE_PRIORITY_CLASS
    'below_normal': 0x00004000, # BELOW_NORMAL_PRIORITY_CLASS
    'normal': 0x00000020        # NORMAL_PRIORITY_CLASS
}

# Supported video extensions
VIDEO_EXTENSIONS = {'.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.mpeg', '.mpg'}


@dataclass
class CompressionJob:
    """Represents a compression job."""
    input_path: str
    output_path: str
    status: str = "Pending"
    progress: float = 0.0
    original_size: float = 0.0
    compressed_size: float = 0.0
    error_message: str = ""


class BulkVideoCompressor:
    """Main application class for bulk video compression."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Bulk Video Compressor")
        self.root.geometry("900x650")
        self.root.minsize(800, 550)

        # State
        self.jobs: List[CompressionJob] = []
        self.is_compressing = False
        self.stop_requested = False
        self.ffmpeg_path: Optional[str] = None
        self.compression_queue = queue.Queue()

        # Find FFmpeg
        self._find_ffmpeg()

        # Build UI
        self._create_ui()

        # Update FFmpeg status
        self._update_ffmpeg_status()

    def _find_ffmpeg(self):
        """Find FFmpeg executable."""
        script_dir = os.path.dirname(os.path.abspath(__file__))

        if os.name == 'nt':
            paths_to_check = [
                os.path.join(script_dir, "ffmpeg.exe"),
                os.path.join(script_dir, "ffmpeg", "ffmpeg.exe"),
                os.path.join(script_dir, "ffmpeg", "bin", "ffmpeg.exe"),
                r"C:\ffmpeg\bin\ffmpeg.exe",
                r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
                r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe",
                os.path.expanduser(r"~\ffmpeg\bin\ffmpeg.exe"),
            ]

            for path in paths_to_check:
                if os.path.isfile(path):
                    self.ffmpeg_path = path
                    return

        # Try system PATH
        try:
            creationflags = 0x08000000 if os.name == 'nt' else 0
            result = subprocess.run(
                ["ffmpeg", "-version"],
                capture_output=True,
                timeout=5,
                creationflags=creationflags
            )
            if result.returncode == 0:
                self.ffmpeg_path = "ffmpeg"
        except:
            pass

    def _create_ui(self):
        """Create the user interface."""
        # Main container
        main_frame = ttk.Frame(self.root, padding="10")
        main_frame.pack(fill=tk.BOTH, expand=True)

        # Top section - Settings
        self._create_settings_section(main_frame)

        # Middle section - File list
        self._create_file_list_section(main_frame)

        # Bottom section - Controls and status
        self._create_controls_section(main_frame)

    def _create_settings_section(self, parent):
        """Create compression settings section."""
        settings_frame = ttk.LabelFrame(parent, text="Compression Settings", padding="10")
        settings_frame.pack(fill=tk.X, pady=(0, 10))

        # Row 1: Codec, CRF, Preset
        row1 = ttk.Frame(settings_frame)
        row1.pack(fill=tk.X, pady=(0, 10))

        # Codec
        ttk.Label(row1, text="Codec:").pack(side=tk.LEFT)
        self.codec_var = tk.StringVar(value="h264")
        codec_combo = ttk.Combobox(
            row1, textvariable=self.codec_var,
            values=["h264", "h265"],
            state="readonly", width=8
        )
        codec_combo.pack(side=tk.LEFT, padx=(5, 20))

        # CRF
        ttk.Label(row1, text="Quality (CRF):").pack(side=tk.LEFT)
        self.crf_var = tk.IntVar(value=23)
        crf_spin = ttk.Spinbox(
            row1, from_=18, to=35, textvariable=self.crf_var, width=5
        )
        crf_spin.pack(side=tk.LEFT, padx=(5, 5))
        ttk.Label(row1, text="(18=Best, 35=Smallest)", foreground="gray").pack(side=tk.LEFT, padx=(0, 20))

        # Preset
        ttk.Label(row1, text="Speed:").pack(side=tk.LEFT)
        self.preset_var = tk.StringVar(value="medium")
        preset_combo = ttk.Combobox(
            row1, textvariable=self.preset_var,
            values=["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"],
            state="readonly", width=10
        )
        preset_combo.pack(side=tk.LEFT, padx=(5, 20))

        # Priority
        ttk.Label(row1, text="Priority:").pack(side=tk.LEFT)
        self.priority_var = tk.StringVar(value="below_normal")
        priority_combo = ttk.Combobox(
            row1, textvariable=self.priority_var,
            values=["low", "below_normal", "normal"],
            state="readonly", width=12
        )
        priority_combo.pack(side=tk.LEFT, padx=(5, 0))

        # Row 2: Output options
        row2 = ttk.Frame(settings_frame)
        row2.pack(fill=tk.X)

        # Output suffix
        ttk.Label(row2, text="Output Suffix:").pack(side=tk.LEFT)
        self.suffix_var = tk.StringVar(value="_compressed")
        suffix_entry = ttk.Entry(row2, textvariable=self.suffix_var, width=15)
        suffix_entry.pack(side=tk.LEFT, padx=(5, 20))

        # Delete original option
        self.delete_original_var = tk.BooleanVar(value=False)
        delete_check = ttk.Checkbutton(
            row2, text="Delete original after compression",
            variable=self.delete_original_var
        )
        delete_check.pack(side=tk.LEFT, padx=(0, 20))

        # Overwrite existing
        self.overwrite_var = tk.BooleanVar(value=False)
        overwrite_check = ttk.Checkbutton(
            row2, text="Overwrite existing files",
            variable=self.overwrite_var
        )
        overwrite_check.pack(side=tk.LEFT)

        # FFmpeg status
        self.ffmpeg_label = ttk.Label(row2, text="", foreground="gray")
        self.ffmpeg_label.pack(side=tk.RIGHT)

    def _create_file_list_section(self, parent):
        """Create file list section."""
        list_frame = ttk.LabelFrame(parent, text="Files to Compress", padding="10")
        list_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        # Buttons
        btn_frame = ttk.Frame(list_frame)
        btn_frame.pack(fill=tk.X, pady=(0, 10))

        ttk.Button(btn_frame, text="Add Files", command=self._add_files).pack(side=tk.LEFT, padx=(0, 5))
        ttk.Button(btn_frame, text="Add Folder", command=self._add_folder).pack(side=tk.LEFT, padx=(0, 5))
        ttk.Button(btn_frame, text="Remove Selected", command=self._remove_selected).pack(side=tk.LEFT, padx=(0, 5))
        ttk.Button(btn_frame, text="Clear All", command=self._clear_all).pack(side=tk.LEFT)

        # File count label
        self.file_count_label = ttk.Label(btn_frame, text="0 files")
        self.file_count_label.pack(side=tk.RIGHT)

        # Treeview for file list
        columns = ("file", "size", "status", "compressed", "ratio")
        self.tree = ttk.Treeview(list_frame, columns=columns, show="headings", selectmode="extended")

        self.tree.heading("file", text="File")
        self.tree.heading("size", text="Original Size")
        self.tree.heading("status", text="Status")
        self.tree.heading("compressed", text="Compressed Size")
        self.tree.heading("ratio", text="Reduction")

        self.tree.column("file", width=350, minwidth=200)
        self.tree.column("size", width=100, minwidth=80)
        self.tree.column("status", width=120, minwidth=80)
        self.tree.column("compressed", width=120, minwidth=80)
        self.tree.column("ratio", width=80, minwidth=60)

        # Scrollbars
        v_scroll = ttk.Scrollbar(list_frame, orient=tk.VERTICAL, command=self.tree.yview)
        h_scroll = ttk.Scrollbar(list_frame, orient=tk.HORIZONTAL, command=self.tree.xview)
        self.tree.configure(yscrollcommand=v_scroll.set, xscrollcommand=h_scroll.set)

        self.tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        v_scroll.pack(side=tk.RIGHT, fill=tk.Y)

    def _create_controls_section(self, parent):
        """Create controls section."""
        controls_frame = ttk.Frame(parent)
        controls_frame.pack(fill=tk.X)

        # Progress bar
        progress_frame = ttk.Frame(controls_frame)
        progress_frame.pack(fill=tk.X, pady=(0, 10))

        self.progress_var = tk.DoubleVar(value=0)
        self.progress_bar = ttk.Progressbar(
            progress_frame, variable=self.progress_var, maximum=100
        )
        self.progress_bar.pack(fill=tk.X, side=tk.LEFT, expand=True, padx=(0, 10))

        self.progress_label = ttk.Label(progress_frame, text="0%", width=6)
        self.progress_label.pack(side=tk.RIGHT)

        # Status and buttons
        status_frame = ttk.Frame(controls_frame)
        status_frame.pack(fill=tk.X)

        self.status_label = ttk.Label(status_frame, text="Ready", foreground="gray")
        self.status_label.pack(side=tk.LEFT)

        self.stop_btn = ttk.Button(
            status_frame, text="Stop", command=self._stop_compression, state=tk.DISABLED
        )
        self.stop_btn.pack(side=tk.RIGHT, padx=(5, 0))

        self.start_btn = ttk.Button(
            status_frame, text="Start Compression", command=self._start_compression
        )
        self.start_btn.pack(side=tk.RIGHT)

    def _update_ffmpeg_status(self):
        """Update FFmpeg status label."""
        if self.ffmpeg_path:
            self.ffmpeg_label.configure(text=f"FFmpeg: Found", foreground="green")
        else:
            self.ffmpeg_label.configure(text="FFmpeg: Not found!", foreground="red")

    def _add_files(self):
        """Add video files to the list."""
        filetypes = [
            ("Video files", "*.mp4 *.avi *.mkv *.mov *.wmv *.flv *.webm *.m4v *.mpeg *.mpg"),
            ("All files", "*.*")
        ]
        files = filedialog.askopenfilenames(filetypes=filetypes)

        for filepath in files:
            self._add_file_to_list(filepath)

        self._update_file_count()

    def _add_folder(self):
        """Add all video files from a folder."""
        folder = filedialog.askdirectory()
        if not folder:
            return

        # Ask about subfolders
        include_subfolders = messagebox.askyesno(
            "Include Subfolders",
            "Include video files from subfolders?"
        )

        if include_subfolders:
            for root, dirs, files in os.walk(folder):
                for filename in files:
                    if os.path.splitext(filename)[1].lower() in VIDEO_EXTENSIONS:
                        self._add_file_to_list(os.path.join(root, filename))
        else:
            for filename in os.listdir(folder):
                if os.path.splitext(filename)[1].lower() in VIDEO_EXTENSIONS:
                    self._add_file_to_list(os.path.join(folder, filename))

        self._update_file_count()

    def _add_file_to_list(self, filepath: str):
        """Add a single file to the list."""
        # Check if already in list
        for job in self.jobs:
            if job.input_path == filepath:
                return

        # Get file size
        try:
            size_bytes = os.path.getsize(filepath)
            size_mb = size_bytes / (1024 * 1024)
        except:
            size_mb = 0

        # Generate output path
        base, ext = os.path.splitext(filepath)
        output_path = f"{base}{self.suffix_var.get()}{ext}"

        job = CompressionJob(
            input_path=filepath,
            output_path=output_path,
            original_size=size_mb
        )
        self.jobs.append(job)

        # Add to treeview
        self.tree.insert("", tk.END, iid=filepath, values=(
            os.path.basename(filepath),
            f"{size_mb:.2f} MB",
            "Pending",
            "-",
            "-"
        ))

    def _remove_selected(self):
        """Remove selected items from the list."""
        selected = self.tree.selection()
        for item in selected:
            self.tree.delete(item)
            self.jobs = [j for j in self.jobs if j.input_path != item]
        self._update_file_count()

    def _clear_all(self):
        """Clear all items from the list."""
        self.tree.delete(*self.tree.get_children())
        self.jobs.clear()
        self._update_file_count()

    def _update_file_count(self):
        """Update file count label."""
        count = len(self.jobs)
        total_size = sum(j.original_size for j in self.jobs)
        self.file_count_label.configure(text=f"{count} files ({total_size:.1f} MB)")

    def _start_compression(self):
        """Start the compression process."""
        if not self.ffmpeg_path:
            messagebox.showerror("Error", "FFmpeg not found. Please install FFmpeg and add it to your PATH.")
            return

        if not self.jobs:
            messagebox.showwarning("No Files", "Please add files to compress.")
            return

        # Check for pending jobs
        pending_jobs = [j for j in self.jobs if j.status in ("Pending", "Failed")]
        if not pending_jobs:
            messagebox.showinfo("Complete", "All files have already been compressed.")
            return

        self.is_compressing = True
        self.stop_requested = False
        self.start_btn.configure(state=tk.DISABLED)
        self.stop_btn.configure(state=tk.NORMAL)

        # Start compression thread
        thread = threading.Thread(target=self._compression_worker, daemon=True)
        thread.start()

    def _stop_compression(self):
        """Stop the compression process."""
        self.stop_requested = True
        self.status_label.configure(text="Stopping...", foreground="orange")

    def _compression_worker(self):
        """Background worker for compression."""
        pending_jobs = [j for j in self.jobs if j.status in ("Pending", "Failed")]
        total = len(pending_jobs)

        for i, job in enumerate(pending_jobs):
            if self.stop_requested:
                self._update_ui(lambda: self._on_compression_stopped())
                return

            # Update status
            self._update_ui(lambda j=job, idx=i, t=total: self._update_job_status(j, "Compressing...", idx, t))

            # Regenerate output path with current suffix
            base, ext = os.path.splitext(job.input_path)
            job.output_path = f"{base}{self.suffix_var.get()}{ext}"

            # Check if output exists
            if os.path.exists(job.output_path) and not self.overwrite_var.get():
                self._update_ui(lambda j=job: self._update_job_status(j, "Skipped (exists)"))
                continue

            # Compress
            success, message = self._compress_video(job)

            if success:
                # Get compressed size
                try:
                    compressed_size = os.path.getsize(job.output_path) / (1024 * 1024)
                    job.compressed_size = compressed_size
                    ratio = (1 - compressed_size / job.original_size) * 100 if job.original_size > 0 else 0

                    # Delete original if requested
                    if self.delete_original_var.get():
                        try:
                            os.remove(job.input_path)
                        except:
                            pass

                    self._update_ui(lambda j=job, cs=compressed_size, r=ratio: self._update_job_complete(j, cs, r))
                except Exception as e:
                    self._update_ui(lambda j=job, m=str(e): self._update_job_status(j, f"Error: {m}"))
            else:
                job.error_message = message
                self._update_ui(lambda j=job, m=message: self._update_job_status(j, f"Failed: {m[:30]}"))

        self._update_ui(lambda: self._on_compression_complete())

    def _compress_video(self, job: CompressionJob) -> Tuple[bool, str]:
        """Compress a single video file."""
        codec = "libx265" if self.codec_var.get() == "h265" else "libx264"
        crf = self.crf_var.get()
        preset = self.preset_var.get()
        priority = self.priority_var.get()

        cmd = [
            self.ffmpeg_path,
            "-i", job.input_path,
            "-c:v", codec,
            "-crf", str(crf),
            "-preset", preset,
            "-threads", "0",  # Auto threads
            "-c:a", "aac",
            "-b:a", "128k",
            "-y" if self.overwrite_var.get() else "-n",
            job.output_path
        ]

        try:
            creationflags = 0
            startupinfo = None

            if os.name == 'nt':
                priority_flag = PRIORITY_FLAGS.get(priority, 0x00004000)
                creationflags = 0x08000000 | priority_flag
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = subprocess.SW_HIDE

            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
                creationflags=creationflags,
                startupinfo=startupinfo
            )

            # Wait for completion
            stdout, stderr = process.communicate()

            if process.returncode == 0:
                return True, "Success"
            else:
                error_msg = stderr.decode('utf-8', errors='ignore')[-200:] if stderr else "Unknown error"
                return False, error_msg

        except Exception as e:
            return False, str(e)

    def _update_ui(self, func):
        """Schedule UI update on main thread."""
        self.root.after(0, func)

    def _update_job_status(self, job: CompressionJob, status: str, current: int = 0, total: int = 0):
        """Update job status in UI."""
        job.status = status
        self.tree.set(job.input_path, "status", status)

        if total > 0:
            progress = ((current + 1) / total) * 100
            self.progress_var.set(progress)
            self.progress_label.configure(text=f"{int(progress)}%")
            self.status_label.configure(
                text=f"Compressing {current + 1}/{total}: {os.path.basename(job.input_path)}",
                foreground="blue"
            )

    def _update_job_complete(self, job: CompressionJob, compressed_size: float, ratio: float):
        """Update job as complete."""
        job.status = "Complete"
        self.tree.set(job.input_path, "status", "Complete")
        self.tree.set(job.input_path, "compressed", f"{compressed_size:.2f} MB")
        self.tree.set(job.input_path, "ratio", f"{ratio:.1f}%")

    def _on_compression_complete(self):
        """Called when compression finishes."""
        self.is_compressing = False
        self.start_btn.configure(state=tk.NORMAL)
        self.stop_btn.configure(state=tk.DISABLED)
        self.progress_var.set(100)
        self.progress_label.configure(text="100%")

        # Calculate totals
        completed = [j for j in self.jobs if j.status == "Complete"]
        total_original = sum(j.original_size for j in completed)
        total_compressed = sum(j.compressed_size for j in completed)
        total_saved = total_original - total_compressed

        self.status_label.configure(
            text=f"Complete! {len(completed)} files, saved {total_saved:.1f} MB",
            foreground="green"
        )

        messagebox.showinfo(
            "Compression Complete",
            f"Compressed {len(completed)} files\n"
            f"Original: {total_original:.1f} MB\n"
            f"Compressed: {total_compressed:.1f} MB\n"
            f"Saved: {total_saved:.1f} MB ({(total_saved/total_original*100) if total_original > 0 else 0:.1f}%)"
        )

    def _on_compression_stopped(self):
        """Called when compression is stopped."""
        self.is_compressing = False
        self.start_btn.configure(state=tk.NORMAL)
        self.stop_btn.configure(state=tk.DISABLED)
        self.status_label.configure(text="Stopped by user", foreground="orange")


def main():
    """Main entry point."""
    root = tk.Tk()

    # Set icon if available
    try:
        if os.name == 'nt':
            root.iconbitmap(default='')
    except:
        pass

    app = BulkVideoCompressor(root)
    root.mainloop()


if __name__ == "__main__":
    main()
