# 📹 Ecom Video Tracker

A professional barcode-triggered video recording system for tracking e-commerce products with automated video capture. Features both a modern Desktop GUI and Web interface.

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Python](https://img.shields.io/badge/python-3.10+-brightgreen)
![License](https://img.shields.io/badge/license-MIT-green)

## ✨ Features

- 🎯 **Continuous Scanning Workflow** - Scan devices one after another without stopping
- 📹 **Live Camera Feed** - Real-time preview with beautiful recording indicator
- 🔄 **Auto Stop-and-Start** - Each barcode automatically stops previous recording and starts new one
- 🔍 **Advanced Search** - Search recordings by barcode, date range, with calendar date pickers
- 💾 **Smart Storage** - Auto-organized by date with metadata tracking
- 📊 **System Monitoring** - Real-time storage usage and recording statistics
- 🎨 **Beautiful UI** - Modern purple-themed interface with card-based design
- 🖥️ **Two Interfaces** - Desktop GUI (Tkinter) and Web UI (Flask)
- ⚙️ **Configurable Settings** - Camera selection, video quality, paths via UI
- 📝 **Complete Logging** - SQLite database with full transaction history

## 📦 Installation

### Prerequisites

- **Python 3.10 or higher**
- **Webcam** (built-in or USB)
- **Git** (for cloning the repository)

### Step 1: Clone the Repository

```bash
git clone <your-repository-url>
cd ecom-system
```

### Step 2: Set Up Virtual Environment

**Option A: Using UV (Recommended - Faster)**

```bash
# Install UV if not already installed
pip install uv

# Create virtual environment and install dependencies
uv venv
.venv\Scripts\activate
uv pip install -r requirements.txt
```

**Option B: Using Standard pip**

```bash
# Create virtual environment
python -m venv .venv

# Activate virtual environment
.venv\Scripts\activate  # Windows
source .venv/bin/activate  # Linux/Mac

# Install dependencies
pip install -r requirements.txt
```

### Step 3: Install Additional Components (Windows)

For camera name detection and calendar date pickers:

```bash
# Run the installation scripts
install_camera_support.bat
install_tkcalendar.bat
```

Or manually:
```bash
pip install pygrabber tkcalendar
```

### Step 4: Initialize the Database

The database will be created automatically on first run. No manual setup needed!

### Step 5: Run the Application

**Desktop GUI (Recommended):**
```bash
run_gui.bat
# Or manually: python app_gui.py
```

**Web Application:**
```bash
run_web.bat
# Or manually: python app.py
```

Then open your browser to: `http://localhost:5000`

## 🚀 Quick Start Guide

### Two Versions Available

#### 🖥️ Desktop Application (Recommended)
- Standalone GUI application - no browser needed!
- Beautiful modern interface with purple theme
- Calendar date pickers for search
- Real camera name detection
- Just double-click `run_gui.bat`

#### 🌐 Web Application
- Browser-based interface
- Access from any device on network
- Responsive design
- Great for remote access
- Run `run_web.bat` and visit `http://localhost:5000`

## 📖 How to Use

### Continuous Scanning Workflow

The system is designed for **fast, continuous scanning** - perfect for recording multiple devices in sequence:

1. **Scan DEVICE001** → Recording starts for DEVICE001
2. **Scan DEVICE002** → DEVICE001 stops & saves, DEVICE002 starts
3. **Scan DEVICE003** → DEVICE002 stops & saves, DEVICE003 starts
4. Keep scanning continuously!

### Example Workflow:
```
Scan: GAME001  → 🔴 Recording GAME001...
Scan: GAME002  → ✅ Saved GAME001.mp4 → 🔴 Recording GAME002...
Scan: GAME003  → ✅ Saved GAME002.mp4 → 🔴 Recording GAME003...
Scan: GAME004  → ✅ Saved GAME003.mp4 → 🔴 Recording GAME004...
```

**Each barcode automatically:**
- Stops the previous recording (if any)
- Saves that video with the previous barcode name
- Immediately starts a new recording with the new barcode

### Searching Recordings

**Desktop GUI:**
1. Click **"🔍 Search Recordings"** button
2. Beautiful search window opens with calendar date pickers
3. Select dates using visual calendar popup
4. Filter by barcode, date range, and sort options
5. View results in elegant cards with hover effects

**Web UI:**
1. Scroll to **"Search Recordings"** section
2. Enter barcode (optional)
3. Select start/end dates using HTML5 date pickers
4. Choose sort order and results per page
5. Click **"Search"** to find recordings

### Video Storage

- Videos are saved in `videos/YYYY-MM-DD/` folders
- Filename format: `YYYYMMDD_HHMMSS_BARCODE.mp4`
- All transactions logged in SQLite database
- Automatic folder organization by date

## 📁 Project Structure

```
ecom-system/
├── 📄 Core Application Files
│   ├── app_gui.py              # Desktop GUI (Tkinter) - Main interface ⭐
│   ├── app.py                  # Web application (Flask)
│   ├── main.py                 # Entry point
│   ├── camera_handler.py       # Video recording logic
│   ├── camera_utils.py         # Camera detection & enumeration
│   ├── barcode_handler.py      # Barcode input handling
│   ├── database.py             # SQLite operations & queries
│   ├── config.py               # Configuration management
│   └── settings_manager.py     # Settings persistence (JSON)
│
├── 🎨 Web Interface
│   ├── templates/
│   │   └── index.html          # Web UI HTML
│   └── static/
│       ├── css/
│       │   └── style.css       # Modern styling
│       └── js/
│           └── script.js       # Frontend logic
│
├── 🔧 Configuration & Setup
│   ├── requirements.txt        # Python dependencies
│   ├── pyproject.toml          # Project metadata
│   ├── .gitignore              # Git ignore rules
│   └── settings.json           # User settings (auto-generated)
│
├── 🚀 Launch Scripts
│   ├── run_gui.bat             # Quick start Desktop GUI
│   ├── run_web.bat             # Quick start Web app
│   ├── build_exe.bat           # Build standalone .exe
│   ├── install_camera_support.bat    # Install camera detection
│   └── install_tkcalendar.bat        # Install calendar picker
│
├── 📊 Data Storage (Auto-generated)
│   ├── videos/                 # Video files (by date)
│   ├── logs/                   # Application logs
│   └── database.db             # SQLite database
│
└── 📚 Documentation
    ├── README.md               # This file
    └── implementation.md       # Technical implementation details
```

## ⚙️ Configuration

### Via Settings UI (Recommended)

Both Desktop and Web interfaces have a **Settings** button:

**Video Settings:**
- Resolution (640x480 to 4K)
- FPS (15, 24, 30, 60)
- Video Codec (MP4V, H264, XVID, MJPEG)

**Camera Settings:**
- Select camera by name (auto-detected)
- Real-time camera preview
- Refresh camera list

**Storage Settings:**
- Video storage path
- Database location
- Log directory

**App Settings (Web only):**
- Flask host and port
- Debug mode

### Manual Configuration

Edit `config.py` for advanced settings:

```python
# Video settings
VIDEO_RESOLUTION = (1280, 720)  # Width x Height
VIDEO_FPS = 30
VIDEO_CODEC = 'mp4v'

# Camera
CAMERA_INDEX = 0

# Storage
VIDEO_STORAGE_PATH = 'videos'
DATABASE_PATH = 'database.db'
LOG_PATH = 'logs'
```

## 🔍 Advanced Features

### Camera Detection

The system automatically detects and shows camera names:
- **Windows**: Uses DirectShow backend with pygrabber
- **Linux**: Uses v4l2-ctl for device enumeration
- **macOS**: Uses system_profiler for camera info

Shows real camera names like "DroidCam OBS", "Logitech C920" instead of "Camera 0"

### Date Picker Calendars (Desktop GUI)

Beautiful calendar popups for date selection:
- Visual month/year navigation
- Purple-themed to match app design
- Click to select dates
- Clear to make optional
- Format: YYYY-MM-DD

### Auto Camera Restart

When changing camera settings:
- Camera automatically restarts with new settings
- No need to restart the entire application
- Settings applied immediately

## 🛠️ Building Standalone Executable

Create a standalone `.exe` file that doesn't require Python:

```bash
build_exe.bat
```

The executable will be in the `dist/` folder. You can distribute this file and run it on any Windows machine without Python installed!

## 🐛 Troubleshooting

### Camera Not Working

**Problem**: Black screen or "Camera not found"

**Solutions**:
1. Ensure webcam is connected and powered on
2. Close other applications using the camera (Zoom, Skype, etc.)
3. Open Settings → Camera → Refresh Cameras
4. Select the correct camera from dropdown
5. Try different camera index (0, 1, 2)

**DirectShow Warnings (Windows)**:
These warnings are suppressed automatically. If you see them, they're harmless.

### Port Already in Use (Web App)

**Problem**: "Address already in use" error

**Solution**:
1. Open Settings → App Settings
2. Change Flask port to 5001 or another port
3. Or manually edit `config.py`: `FLASK_PORT = 5001`

### Dependencies Issues

**Problem**: Import errors or missing modules

**Solutions**:

```bash
# Reinstall all dependencies
uv pip install -r requirements.txt

# Or with standard pip
pip install -r requirements.txt

# Install specific components
install_camera_support.bat
install_tkcalendar.bat
```

### Database Locked

**Problem**: "Database is locked" error

**Solutions**:
1. Close all instances of the application
2. Delete `database.db` (will recreate on next run)
3. Check if another process is using the file

### Video Files Not Saving

**Problem**: Recording works but no video file created

**Solutions**:
1. Check disk space
2. Verify `videos/` folder permissions
3. Check logs in `logs/app.log` for errors
4. Try changing video codec in Settings

## 📊 Database Schema

The SQLite database tracks all recordings:

```sql
CREATE TABLE transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    barcode TEXT NOT NULL,
    start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    end_time TIMESTAMP,
    video_filename TEXT,
    duration_seconds INTEGER,
    file_size_mb REAL,
    stop_method TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

Query manually:
```bash
sqlite3 database.db "SELECT * FROM transactions ORDER BY created_at DESC LIMIT 10;"
```

## 🔐 Security Notes

- Default Flask host is `127.0.0.1` (localhost only)
- Change to `0.0.0.0` in settings to allow network access
- **Warning**: Network access allows anyone on your network to access the app
- No authentication built-in - add if deploying to production

## 🚦 Performance Tips

1. **Video Quality**: Higher resolution = larger files. Use 720p for balance.
2. **Storage**: Videos can be large. Monitor disk space regularly.
3. **Camera**: DirectShow backend (Windows) is more stable than MSMF
4. **Database**: Clean old recordings periodically to keep database fast

## 🗺️ Roadmap

### Phase 2 (Future)
- [ ] Real barcode scanner hardware integration
- [ ] Raspberry Pi deployment guide
- [ ] Cloud storage sync (AWS S3, Google Drive)
- [ ] Mobile app for viewing recordings
- [ ] Inventory system integration
- [ ] Multi-camera support
- [ ] User authentication
- [ ] Video compression optimization
- [ ] Export to Excel/CSV

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 💬 Support

Having issues? Here's how to get help:

1. **Check the logs**: `logs/app.log` contains detailed error messages
2. **Read this README**: Most common issues are covered above
3. **Search Issues**: Check if someone else had the same problem
4. **Create an Issue**: Provide logs, screenshots, and steps to reproduce

## 🙏 Acknowledgments

- Built with Python, OpenCV, Flask, and Tkinter
- UI inspired by modern material design principles
- Special thanks to the open-source community

---

**Ecom Video Tracker** © 2025 | Phase 1 MVP Complete 🎉

Made with ❤️ for efficient e-commerce product tracking
