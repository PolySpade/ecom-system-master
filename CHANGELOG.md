# Changelog

All notable changes to the Ecom Video Tracker project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-12

### 🎉 Phase 1 MVP Complete

### Added

#### Core Features
- **Barcode-triggered video recording system** - Automatic video capture on barcode scan
- **Continuous scanning workflow** - Each barcode stops previous recording and starts new one
- **Two user interfaces** - Desktop GUI (Tkinter) and Web UI (Flask)
- **SQLite database** - Complete transaction logging with metadata
- **Live camera feed** - Real-time preview with recording indicator
- **Advanced search functionality** - Search by barcode, date range, with pagination

#### Desktop GUI Features
- **Beautiful modern interface** - Purple-themed design with card-based layout
- **Calendar date pickers** - Visual calendar popups for date selection using tkcalendar
- **Real camera name detection** - Shows actual camera names like "DroidCam OBS"
- **Settings dialog** - Tabbed interface for configuring video, camera, storage, and app settings
- **Search window** - Separate popup window with beautiful card-based results
- **Gradient header** - Modern purple gradient with app title and settings button
- **Color-coded status** - Visual indicators for recording state
- **Hover effects** - Interactive UI elements with smooth transitions

#### Web UI Features
- **Responsive design** - Works on desktop and mobile browsers
- **Search modal** - Beautiful popup search interface
- **Card-based results** - Modern design with hover effects
- **Live status updates** - Real-time recording status via polling
- **Video playback modal** - In-browser video player
- **Download functionality** - Direct video downloads

#### Camera Features
- **DirectShow backend** - Stable Windows camera support, avoiding MSMF warnings
- **Camera enumeration** - Auto-detect and list all available cameras
- **Platform support** - Windows (DirectShow + pygrabber), Linux (v4l2), macOS (system_profiler)
- **Auto camera restart** - Settings changes applied without app restart
- **Warning suppression** - Clean console output, no spam from OpenCV

#### Settings & Configuration
- **Settings UI** - Configure all options without editing code
- **JSON persistence** - Settings saved to settings.json
- **Camera selection by name** - Choose from detected camera devices
- **Video quality options** - Resolution (480p-4K), FPS (15-60), codec selection
- **Storage paths** - Configurable video, database, and log locations
- **Flask configuration** - Host, port, and debug mode settings (Web UI)

#### Search & Discovery
- **Barcode search** - Find recordings by exact or partial barcode match
- **Date range filtering** - Search between specific dates
- **Multiple sort options** - Sort by date, barcode, duration, or file size
- **Pagination** - Navigate through large result sets
- **Result cards** - Beautiful display with barcode, date, duration, file size
- **Quick actions** - Play video, download, show in folder

#### Technical Improvements
- **Error handling** - Comprehensive error catching and user-friendly messages
- **Logging system** - Detailed logs to `logs/app.log`
- **Database schema** - Optimized SQLite with proper indexing
- **File organization** - Auto-organized videos by date (YYYY-MM-DD folders)
- **Geometry manager fix** - Corrected pack/grid mixing issues
- **OpenCV warning suppression** - Context manager for clean stderr output

### Changed
- **UI redesign** - Complete overhaul from basic ttk widgets to modern themed interface
- **Search interface** - Moved from inline to separate window/modal
- **Date inputs** - Upgraded from text entry to calendar pickers
- **Camera display** - Enhanced with better styling and indicators
- **Button styling** - Custom colored buttons matching theme

### Fixed
- **Geometry manager conflict** - Fixed grid/pack mixing causing errors
- **OpenCV DSHOW warnings** - Suppressed annoying camera enumeration warnings
- **Camera state updates** - Proper color and status synchronization
- **Date validation** - Improved handling of optional date filters
- **Recording indicator** - Fixed placement and visibility issues

### Security
- **Default localhost binding** - Flask binds to 127.0.0.1 by default
- **Configurable network access** - Option to enable 0.0.0.0 for network access
- **No hardcoded credentials** - All settings user-configurable

### Documentation
- **Comprehensive README** - Full installation and usage guide
- **Project structure** - Clear organization and file descriptions
- **Troubleshooting guide** - Common issues and solutions
- **Configuration examples** - Code samples for customization
- **Database schema** - SQL table structure documentation

### Developer Experience
- **Install scripts** - Batch files for easy dependency installation
- **Launch scripts** - One-click run for both GUI and Web versions
- **Build script** - Create standalone .exe with PyInstaller
- **Comprehensive .gitignore** - Proper exclusions for Python projects
- **Type hints** - Better code completion and IDE support

## [0.1.0] - 2025-01-10

### Initial Development

- Basic barcode recording functionality
- Simple Tkinter GUI
- Flask web interface prototype
- Database setup
- Video storage system

---

## Version Naming Scheme

- **Major version** (x.0.0): Breaking changes, major redesigns
- **Minor version** (1.x.0): New features, enhancements
- **Patch version** (1.0.x): Bug fixes, minor improvements

## Upcoming

See [README.md](README.md#roadmap) for planned features in Phase 2.
