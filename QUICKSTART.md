# 🚀 Quick Start Guide

Get up and running with Ecom Video Tracker in 5 minutes!

## 📥 First Time Installation

### Windows

```bash
# 1. Clone the repository
git clone <your-repository-url>
cd ecom-system

# 2. Run the installer (does everything automatically)
install.bat

# 3. Launch the app
run_gui.bat
```

That's it! The installer handles:
- Creating virtual environment
- Installing all dependencies
- Setting up camera detection
- Installing calendar pickers

### Linux/Mac

```bash
# 1. Clone the repository
git clone <your-repository-url>
cd ecom-system

# 2. Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# 3. Install dependencies
pip install -r requirements.txt

# 4. Run the app
python app_gui.py  # Desktop GUI
python app.py      # Web UI
```

## 🎯 Basic Usage

### Recording Videos

1. **Start the app** - Double-click `run_gui.bat`
2. **Wait for camera** - Green indicator when ready
3. **Scan/Enter barcode** - Type or scan barcode, press Enter
4. **Recording starts** - Red indicator shows "RECORDING"
5. **Scan next barcode** - Previous video auto-saves, new one starts
6. **Repeat** - Keep scanning continuously!

### Searching Videos

**Desktop GUI:**
1. Click **"🔍 Search Recordings"** button
2. Use calendar picker to select dates (optional)
3. Enter barcode (optional)
4. Click **"🔍 Search"**
5. Click **"▶️ Play Video"** to watch

**Web UI:**
1. Scroll to **Search Recordings** section
2. Fill in search criteria
3. Click **Search**
4. Click **📹 View Video** to watch

## ⚙️ Quick Configuration

### Change Camera

**Desktop GUI:**
1. Click **⚙️ Settings**
2. Go to **Camera** tab
3. Select your camera from dropdown
4. Click **Save & Apply**

**Web UI:**
1. Click **⚙️ Settings**
2. Go to **Camera** tab
3. Select your camera
4. Click **Save & Apply**

### Change Video Quality

**Settings → Video Tab:**
- **720p**: 1280x720 (Recommended)
- **1080p**: 1920x1080 (Higher quality)
- **4K**: 3840x2160 (Best quality, large files)

**FPS Options:**
- **30 FPS**: Recommended for most uses
- **60 FPS**: Smoother video, larger files

## 📂 Where Are My Videos?

Videos are saved in:
```
videos/
  └── 2025-01-12/              ← Date folder
      ├── 20250112_103045_DEVICE001.mp4
      ├── 20250112_103152_DEVICE002.mp4
      └── 20250112_103301_DEVICE003.mp4
```

## 🔥 Common Commands

```bash
# Desktop GUI
run_gui.bat

# Web UI
run_web.bat

# Build standalone .exe
build_exe.bat

# Reinstall dependencies
.venv\Scripts\activate
pip install -r requirements.txt

# View logs
type logs\app.log          # Windows
cat logs/app.log           # Linux/Mac
```

## ⚡ Keyboard Shortcuts

**Desktop GUI:**
- `Enter` - Submit barcode
- `Ctrl+F` - Open search window
- `Esc` - Close search window
- `F5` - Refresh search results

**Web UI:**
- `Enter` - Submit barcode / Search

## 🐛 Quick Troubleshooting

### Camera Not Working
```bash
# Try these in order:
1. Close Zoom, Skype, or other camera apps
2. Settings → Camera → Refresh Cameras
3. Try different camera from dropdown
4. Restart the application
```

### Port Already in Use (Web)
```bash
# Change the port:
1. Settings → App → Flask Port
2. Change from 5000 to 5001
3. Save & Restart
```

### Dependencies Error
```bash
# Reinstall everything:
install.bat              # Windows
pip install -r requirements.txt  # Linux/Mac
```

## 📊 Quick Stats

View your recording statistics:

**Desktop GUI:**
- **System Status** panel shows:
  - Current status (Idle/Recording)
  - Active filename
  - Recording duration
  - Total storage used

**Web UI:**
- **System Status** card shows same info
- **Recent Recordings** shows last 10 videos

## 💡 Pro Tips

1. **Continuous Scanning**: Don't click Stop between barcodes - just scan the next one!
2. **Search by Date**: Use calendar pickers for easy date selection
3. **Sort Results**: Sort by date, barcode, duration, or file size
4. **Organize Videos**: Videos auto-organize by date - keep them that way!
5. **Monitor Storage**: Check storage used in System Status panel
6. **Check Logs**: If something's wrong, check `logs/app.log`

## 🆘 Need More Help?

- **Full Documentation**: See [README.md](README.md)
- **Troubleshooting**: [README.md#troubleshooting](README.md#troubleshooting)
- **Version History**: See [CHANGELOG.md](CHANGELOG.md)
- **Report Issues**: Create an issue on GitHub

## 📞 Quick Reference Card

```
┌─────────────────────────────────────────┐
│  ECOM VIDEO TRACKER - QUICK REFERENCE   │
├─────────────────────────────────────────┤
│ START:        run_gui.bat               │
│ SEARCH:       🔍 Search Recordings btn  │
│ SETTINGS:     ⚙️ Settings button        │
│ VIDEOS:       videos/YYYY-MM-DD/        │
│ LOGS:         logs/app.log              │
│ DATABASE:     database.db               │
├─────────────────────────────────────────┤
│ WORKFLOW:                               │
│  1. Enter/Scan barcode                  │
│  2. Recording starts (auto)             │
│  3. Scan next → Previous saves          │
│  4. Repeat for all items                │
│  5. Click Stop when done                │
└─────────────────────────────────────────┘
```

---

**Happy Recording!** 🎉

For detailed documentation, see [README.md](README.md)
