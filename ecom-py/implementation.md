# GAMECOVE Recording System - Project Plan

## Project Overview
A barcode-triggered video recording system for GAMECOVE PH (retro gaming handheld resale business). Scan a barcode → camera starts recording → stop manually or with second barcode scan. Built on Python + Flask, testing on Windows first, then transferring to Raspberry Pi.

---

## Core Functionality

### Recording Flow
1. **Barcode Scan** → Triggers camera to start recording
2. **Live Recording** → Video captures with timestamp metadata
3. **Stop Methods** (either one):
   - Manual stop button on UI
   - Second barcode scan (stop code)
4. **Save & Log** → Video file saved + transaction logged to database

### Key Features
- Live camera feed display in web UI
- Video files organized by date
- SQLite database logging transactions (barcode, timestamp, video filename, duration)
- Efficient video codec (h.264)
- Error handling for camera failures and storage issues

---

## Technology Stack

### Languages & Frameworks
- **Python 3.9+** - Core application
- **Flask** - Web UI and server
- **OpenCV** - Camera and video recording
- **SQLite** - Transaction logging
- **HTML/CSS/JavaScript** - Frontend UI

### Key Libraries
```
opencv-python
flask
pyzbar (for barcode detection - Phase 2)
sqlite3 (built-in)
```

### Hardware (Target)
- Raspberry Pi 4 or 5
- USB Camera (1080p minimum)
- USB Barcode Scanner
- 64GB+ microSD card
- Optional: External SSD for video storage

---

## Project Structure

```
gamecove-recording-system/
├── app.py                 # Main Flask application
├── camera_handler.py      # Video recording logic
├── barcode_handler.py     # Barcode/input detection
├── database.py            # SQLite operations
├── config.py              # Configuration settings
├── requirements.txt       # Python dependencies
├── templates/
│   └── index.html         # Main web UI
├── static/
│   ├── css/
│   │   └── style.css      # Styling
│   └── js/
│       └── script.js      # Frontend logic
├── videos/                # Video storage (by date)
│   └── 2025-01-10/
├── logs/                  # Debug logs
└── database.db            # SQLite database
```

---

## Phase 1 - MVP (Windows Testing)

### Objectives
Get a fully functional recording system working on Windows before Raspberry Pi deployment.

### Implementation Steps

#### Step 1: Flask Web App Setup
- Create `app.py` with Flask server
- Serve web UI on `localhost:5000`
- Implement basic routing (home page, API endpoints)

#### Step 2: Camera Integration
- Initialize USB camera (OpenCV)
- Display live camera feed in web UI (MJPEG stream or canvas)
- Test video codec settings (h.264)

#### Step 3: Barcode Input (Simulated)
- Add text input field on web UI for testing
- No actual scanner needed yet - just type barcodes
- Validate input format

#### Step 4: Recording Logic
- On barcode entry → start video recording
- Save video with timestamp in filename: `{YYYYMMDD_HHMMSS}_{barcode}.mp4`
- Organize videos by date folder

#### Step 5: Stop Methods
- Implement manual "Stop Recording" button
- Implement second barcode scan to trigger stop
- Properly finalize video file on stop

#### Step 6: Database Integration
- Create SQLite database schema
- Log each transaction: barcode, timestamp, video filename, duration
- Display recent recordings on UI

#### Step 7: UI/UX Polish
- Clean, minimal interface
- Show recording status (idle/recording)
- Display video file list with metadata
- Show storage usage

#### Step 8: Error Handling
- Handle camera initialization failures
- Handle storage full scenarios
- Handle file I/O errors
- Add logging for debugging

### Testing Checklist
- [ ] Flask app starts without errors
- [ ] Live camera feed displays in browser
- [ ] Can enter mock barcode and start recording
- [ ] Manual stop button works
- [ ] Second barcode stops recording
- [ ] Videos save with correct filenames
- [ ] Database logs all transactions
- [ ] Videos organized by date
- [ ] Error messages display properly

---

## Phase 2 - Hardware Integration & Optimization

### Real Barcode Scanner
- Remove mock input field
- Listen for actual USB barcode scanner keyboard input
- Set barcode prefixes (e.g., "START_" vs "STOP_")

### Raspberry Pi Deployment
- Install Raspberry Pi OS
- Install Python dependencies
- Transfer code from Windows
- Test with Pi camera module or USB camera
- Optimize video settings for Pi performance
- Auto-start on boot

### File Management
- Auto-cleanup old videos (configurable retention)
- Monitor storage usage
- Archive videos to external storage

### Cloud Sync
- Optional backup to cloud storage
- Batch upload recordings
- Sync transaction logs

### Enhanced Metadata
- Integration with GAMECOVE PH inventory system
- Pull product info (price, category, SKU)
- Link to sales channel (Shopee/Lazada/TikTok)

---

## Configuration Settings (config.py)

```python
# Video Settings
VIDEO_CODEC = 'h264'           # or 'mp4v'
VIDEO_FPS = 30                 # Frames per second
VIDEO_RESOLUTION = (1280, 720) # Width, height
VIDEO_QUALITY = 80             # Quality percentage

# Storage
VIDEO_STORAGE_PATH = './videos'
DATABASE_PATH = './database.db'
MAX_STORAGE_GB = 500           # Alert when approaching limit

# Barcode Settings
BARCODE_START_PREFIX = 'START_'
BARCODE_STOP_PREFIX = 'STOP_'
BARCODE_TIMEOUT_SECONDS = 60   # Auto-stop if no activity

# Flask
FLASK_HOST = '0.0.0.0'
FLASK_PORT = 5000
DEBUG_MODE = True

# Logging
LOG_LEVEL = 'DEBUG'
LOG_FILE = './logs/app.log'
```

---

## Database Schema

### transactions table
```sql
CREATE TABLE transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    barcode TEXT NOT NULL,
    video_filename TEXT NOT NULL,
    start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    end_time TIMESTAMP,
    duration_seconds INTEGER,
    file_size_mb REAL,
    stop_method TEXT,  -- 'manual' or 'barcode'
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

## File Naming Convention

Videos: `{YYYYMMDD_HHMMSS}_{barcode}.mp4`

Example: `20250110_143045_DEVICE001.mp4`

Database entry links video filename to barcode and metadata.

---

## Prompt for Claude Code

Use this prompt to generate the initial codebase:

```
I'm building a barcode-triggered video recording system for my gaming device resale business (GAMECOVE PH). Here's what I need:

**Core Functionality:**
- Scan barcode → camera activates and starts recording video
- Manual stop button to end recording
- Second barcode scan also stops recording
- Save videos with metadata (barcode, timestamp, duration)
- SQLite database to log all transactions

**Current Setup (Windows testing first, then Raspberry Pi):**
- Windows environment with Python 3.9+
- USB camera (webcam)
- USB barcode scanner (simulated via text input initially)
- Need a web-based UI using Flask

**Project Structure:**
```
gamecove-recording-system/
├── app.py (main Flask app)
├── camera_handler.py (video recording logic)
├── barcode_handler.py (input detection)
├── database.py (SQLite operations)
├── config.py (settings and configuration)
├── templates/ (HTML UI)
├── static/ (CSS/JS)
├── videos/ (storage directory)
└── logs/ (debug logs)
```

**Phase 1 - MVP (start here):**
1. Create Flask web app with live camera feed display
2. Add text input field to simulate barcode scanning (manual entry for testing)
3. When "barcode" is entered → start recording video
4. Manual stop button to end recording
5. Add second barcode scan detection to also stop recording
6. Save videos to local folder with timestamp
7. Create simple transaction log (SQLite) storing: barcode, timestamp, video filename, duration

**Requirements:**
- Clean, minimal web UI with camera preview
- Video files should be organized by date
- Proper error handling (camera fails, storage issues, etc.)
- Use h.264 codec for file efficiency
- Add logging for debugging

**Future additions (Phase 2):**
- Actual barcode scanner input integration
- Product metadata from inventory system
- Video file management and cleanup
- Cloud sync capability
- Performance optimization for Raspberry Pi

Please build a complete, working solution for Phase 1 that I can test on Windows with my webcam.
```

---

## Development Timeline (Estimated)

- **Phase 1 (MVP)**: 3-5 days
  - Day 1: Project setup, Flask app, camera integration
  - Day 2-3: Recording logic, barcode input, stop methods
  - Day 4: Database, UI polish
  - Day 5: Testing, error handling, optimization

- **Phase 2 (Hardware & Production)**: 2-3 weeks
  - Barcode scanner integration
  - Raspberry Pi setup and testing
  - Performance optimization
  - Final testing and deployment

---

## Testing Environments

### Windows (Phase 1)
- Webcam for camera
- Text input for barcode (no physical scanner needed)
- SQLite database stored locally
- Flask dev server

### Raspberry Pi (Phase 2)
- USB camera or Pi camera module
- Physical barcode scanner
- External SSD for large video storage
- Production Flask server (Gunicorn/uWSGI)

---

## Next Steps

1. **Prepare Windows Environment**
   - Install Python 3.9+
   - Create project folder
   - Set up virtual environment

2. **Generate Code with Claude Code**
   - Use the prompt above
   - Generate Phase 1 MVP

3. **Test Locally**
   - Run Flask app
   - Test camera feed
   - Test recording with mock barcode
   - Test database logging

4. **Iterate & Refine**
   - Fix bugs
   - Optimize performance
   - Improve UI/UX

5. **Document for Pi Transfer**
   - Create setup guide for Raspberry Pi
   - Document any OS-specific changes needed
   - Plan hardware setup

---

## Notes

- Start simple, iterate quickly
- Windows testing saves time before Pi deployment
- Focus on Phase 1 MVP first—Phase 2 can be added incrementally
- Video files get large fast—plan storage strategy early
- Consider lighting for clear product recording on Pi setup