"""
Settings Manager - Handle application configuration with JSON persistence
"""
import json
import os
import logging
from typing import Dict, Any

logger = logging.getLogger(__name__)


class SettingsManager:
    """Manages application settings with JSON file persistence."""

    DEFAULT_SETTINGS = {
        'video': {
            'resolution_width': 1280,
            'resolution_height': 720,
            'fps': 30,
            'codec': 'mp4v'
        },
        'camera': {
            'index': 0,
            'auto_exposure': True,
            'exposure': -4,
            'gain': 0,
            'brightness': 128
        },
        'storage': {
            'video_path': 'videos',
            'database_path': 'database.db',
            'log_path': 'logs'
        },
        'app': {
            'flask_host': '127.0.0.1',
            'flask_port': 5000,
            'debug_mode': False
        },
        'compression': {
            'enabled': True,
            'codec': 'h264',       # 'h264' or 'h265'
            'crf': 23,             # 18-35 (lower = better quality)
            'preset': 'medium',    # ultrafast/fast/medium/slow
            'delete_original': True,  # Delete original after successful compression
            'priority': 'below_normal'  # 'low', 'below_normal', or 'normal'
        }
    }

    def __init__(self, settings_file='settings.json'):
        """Initialize settings manager."""
        self.settings_file = settings_file
        self.settings = self.load_settings()

    def load_settings(self) -> Dict[str, Any]:
        """Load settings from JSON file or create default if not exists."""
        if os.path.exists(self.settings_file):
            try:
                with open(self.settings_file, 'r') as f:
                    loaded_settings = json.load(f)
                    # Merge with defaults to ensure all keys exist
                    settings = self.DEFAULT_SETTINGS.copy()
                    self._deep_merge(settings, loaded_settings)
                    logger.info(f"Settings loaded from {self.settings_file}")
                    return settings
            except Exception as e:
                logger.error(f"Error loading settings: {e}, using defaults")
                return self.DEFAULT_SETTINGS.copy()
        else:
            logger.info("Settings file not found, using defaults")
            return self.DEFAULT_SETTINGS.copy()

    def save_settings(self) -> bool:
        """Save current settings to JSON file."""
        try:
            with open(self.settings_file, 'w') as f:
                json.dump(self.settings, f, indent=4)
            logger.info(f"Settings saved to {self.settings_file}")
            return True
        except Exception as e:
            logger.error(f"Error saving settings: {e}")
            return False

    def get(self, category: str, key: str, default=None):
        """Get a specific setting value."""
        return self.settings.get(category, {}).get(key, default)

    def set(self, category: str, key: str, value: Any):
        """Set a specific setting value."""
        if category not in self.settings:
            self.settings[category] = {}
        self.settings[category][key] = value

    def get_all(self) -> Dict[str, Any]:
        """Get all settings."""
        return self.settings.copy()

    def update_category(self, category: str, data: Dict[str, Any]):
        """Update an entire category of settings."""
        if category in self.settings:
            self.settings[category].update(data)
        else:
            self.settings[category] = data

    def reset_to_defaults(self):
        """Reset all settings to defaults."""
        self.settings = self.DEFAULT_SETTINGS.copy()
        logger.info("Settings reset to defaults")

    @staticmethod
    def _deep_merge(base: Dict, updates: Dict):
        """Recursively merge updates into base dictionary."""
        for key, value in updates.items():
            if key in base and isinstance(base[key], dict) and isinstance(value, dict):
                SettingsManager._deep_merge(base[key], value)
            else:
                base[key] = value

    # Convenience methods for specific settings

    def get_video_resolution(self) -> tuple:
        """Get video resolution as (width, height)."""
        return (
            self.get('video', 'resolution_width', 1280),
            self.get('video', 'resolution_height', 720)
        )

    def set_video_resolution(self, width: int, height: int):
        """Set video resolution."""
        self.set('video', 'resolution_width', width)
        self.set('video', 'resolution_height', height)

    def get_video_fps(self) -> int:
        """Get video FPS."""
        return self.get('video', 'fps', 30)

    def get_video_codec(self) -> str:
        """Get video codec."""
        return self.get('video', 'codec', 'mp4v')

    def get_camera_index(self) -> int:
        """Get camera index."""
        return self.get('camera', 'index', 0)

    def get_camera_auto_exposure(self) -> bool:
        """Get camera auto exposure setting."""
        return self.get('camera', 'auto_exposure', True)

    def get_camera_exposure(self) -> int:
        """Get camera manual exposure value (-13 to -1)."""
        return self.get('camera', 'exposure', -4)

    def get_camera_gain(self) -> int:
        """Get camera gain value (0 to 255)."""
        return self.get('camera', 'gain', 0)

    def get_camera_brightness(self) -> int:
        """Get camera brightness value (0 to 255)."""
        return self.get('camera', 'brightness', 128)

    def get_camera_exposure_settings(self) -> dict:
        """Get all camera exposure settings as a dictionary."""
        return {
            'auto_exposure': self.get_camera_auto_exposure(),
            'exposure': self.get_camera_exposure(),
            'gain': self.get_camera_gain(),
            'brightness': self.get_camera_brightness()
        }

    def get_video_storage_path(self) -> str:
        """Get video storage path (normalized for OS)."""
        path = self.get('storage', 'video_path', 'videos')
        return os.path.normpath(path) if path else 'videos'

    def get_database_path(self) -> str:
        """Get database path (normalized for OS)."""
        path = self.get('storage', 'database_path', 'database.db')
        return os.path.normpath(path) if path else 'database.db'

    def get_log_path(self) -> str:
        """Get log path (normalized for OS)."""
        path = self.get('storage', 'log_path', 'logs')
        return os.path.normpath(path) if path else 'logs'
