import os
import sys
from settings_manager import SettingsManager

# Base directory - handle PyInstaller frozen exe
if getattr(sys, 'frozen', False):
    # Running as compiled exe - use the exe's directory for runtime files
    BASE_DIR = os.path.dirname(sys.executable)
else:
    # Running as script
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Initialize settings manager
_settings = SettingsManager(os.path.join(BASE_DIR, 'settings.json'))

# Video Settings (dynamically loaded from settings)
VIDEO_CODEC = _settings.get_video_codec()
VIDEO_FPS = _settings.get_video_fps()
VIDEO_RESOLUTION = _settings.get_video_resolution()
VIDEO_QUALITY = 80

# Storage (dynamically loaded from settings) - normalize all paths
_video_path = _settings.get_video_storage_path()
VIDEO_STORAGE_PATH = os.path.normpath(_video_path if os.path.isabs(_video_path) else os.path.join(BASE_DIR, _video_path))

_db_path = _settings.get_database_path()
DATABASE_PATH = os.path.normpath(_db_path if os.path.isabs(_db_path) else os.path.join(BASE_DIR, _db_path))

_log_path = _settings.get_log_path()
LOG_PATH = os.path.normpath(_log_path if os.path.isabs(_log_path) else os.path.join(BASE_DIR, _log_path))

MAX_STORAGE_GB = 500

# Barcode Settings
BARCODE_START_PREFIX = 'START_'
BARCODE_STOP_PREFIX = 'STOP_'
BARCODE_TIMEOUT_SECONDS = 60

# Flask (dynamically loaded from settings)
FLASK_HOST = _settings.get('app', 'flask_host', '0.0.0.0')
FLASK_PORT = _settings.get('app', 'flask_port', 5000)
DEBUG_MODE = _settings.get('app', 'debug_mode', True)

# Logging
LOG_LEVEL = 'DEBUG'
LOG_FILE = os.path.join(LOG_PATH, 'app.log')

# Camera Settings (dynamically loaded from settings)
CAMERA_INDEX = _settings.get_camera_index()
CAMERA_WARMUP_TIME = 0.5  # Seconds to wait for camera to initialize

# Export settings manager for use by other modules
settings_manager = _settings

def reload_config():
    """Reload configuration from settings file."""
    global VIDEO_CODEC, VIDEO_FPS, VIDEO_RESOLUTION, VIDEO_STORAGE_PATH
    global DATABASE_PATH, LOG_PATH, FLASK_HOST, FLASK_PORT, DEBUG_MODE, CAMERA_INDEX

    _settings.settings = _settings.load_settings()

    VIDEO_CODEC = _settings.get_video_codec()
    VIDEO_FPS = _settings.get_video_fps()
    VIDEO_RESOLUTION = _settings.get_video_resolution()

    _video_path = _settings.get_video_storage_path()
    VIDEO_STORAGE_PATH = os.path.normpath(_video_path if os.path.isabs(_video_path) else os.path.join(BASE_DIR, _video_path))

    _db_path = _settings.get_database_path()
    DATABASE_PATH = os.path.normpath(_db_path if os.path.isabs(_db_path) else os.path.join(BASE_DIR, _db_path))

    _log_path = _settings.get_log_path()
    LOG_PATH = os.path.normpath(_log_path if os.path.isabs(_log_path) else os.path.join(BASE_DIR, _log_path))

    FLASK_HOST = _settings.get('app', 'flask_host', '0.0.0.0')
    FLASK_PORT = _settings.get('app', 'flask_port', 5000)
    DEBUG_MODE = _settings.get('app', 'debug_mode', True)

    CAMERA_INDEX = _settings.get_camera_index()
