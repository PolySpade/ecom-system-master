"""
Camera Utilities - Detect and enumerate available cameras
"""
import cv2
import platform
import logging
import sys
import os
import time
import threading
from typing import List, Dict, Optional
from contextlib import contextmanager

logger = logging.getLogger(__name__)

# Cache for camera detection results
_camera_cache: Optional[List[Dict]] = None
_cache_time: float = 0
_cache_lock = threading.Lock()
_CACHE_DURATION = 30.0  # Cache results for 30 seconds


@contextmanager
def suppress_opencv_warnings():
    """Suppress OpenCV warnings during camera enumeration."""
    # Redirect stderr to devnull to suppress C++ warnings
    old_stderr = sys.stderr
    try:
        sys.stderr = open(os.devnull, 'w')
        yield
    finally:
        sys.stderr.close()
        sys.stderr = old_stderr


def get_available_cameras(max_cameras: int = 5, use_cache: bool = True) -> List[Dict]:
    """
    Enumerate available cameras and return their information.

    Args:
        max_cameras: Maximum number of camera indices to check (default: 5)
        use_cache: Whether to use cached results (default: True)

    Returns:
        List of dictionaries with camera information:
        [{'index': 0, 'name': 'Built-in Camera', 'working': True}, ...]
    """
    global _camera_cache, _cache_time

    # Return cached results if available and fresh
    if use_cache and _camera_cache is not None:
        with _cache_lock:
            if time.time() - _cache_time < _CACHE_DURATION:
                return _camera_cache.copy()

    available_cameras = []

    logger.info("Enumerating available cameras...")

    # Suppress OpenCV warnings during enumeration
    old_opencv_log = os.environ.get("OPENCV_LOG_LEVEL")
    os.environ["OPENCV_LOG_LEVEL"] = "ERROR"

    # Try to get camera names using platform-specific methods
    camera_names = _get_camera_names()

    system = platform.system()
    use_msmf = system == 'Windows'

    # Use context manager to suppress stderr warnings from OpenCV
    with suppress_opencv_warnings():
        for i in range(max_cameras):
            try:
                # Use MSMF (Media Foundation) on Windows for better compatibility
                # This matches the backend used in camera_handler.py
                if use_msmf:
                    cap = cv2.VideoCapture(i, cv2.CAP_MSMF)
                else:
                    cap = cv2.VideoCapture(i)

                if cap.isOpened():
                    # Camera is available - try to read a frame
                    ret, frame = cap.read()
                    working = ret and frame is not None

                    # Get camera name from our detection or use generic name
                    name = camera_names.get(i, f"Camera {i}")

                    # Try to get resolution info
                    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
                    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

                    camera_info = {
                        'index': i,
                        'name': name,
                        'working': working,
                        'resolution': f"{width}x{height}" if working else "Unknown"
                    }

                    available_cameras.append(camera_info)
                    # Log to Python logger (stdout), not stderr

                    cap.release()
                else:
                    # Camera index exists but can't be opened (might be in use)
                    # We'll skip it
                    pass

            except Exception as e:
                # Silently continue for camera enumeration errors
                continue

    # Log results after enumeration (outside suppress context)
    for cam in available_cameras:
        logger.info(f"Found camera {cam['index']}: {cam['name']} ({cam['resolution']}, working: {cam['working']})")

    # Restore OpenCV logging
    if old_opencv_log is not None:
        os.environ["OPENCV_LOG_LEVEL"] = old_opencv_log
    else:
        os.environ.pop("OPENCV_LOG_LEVEL", None)

    # Always ensure index 0 is available as an option
    has_index_0 = any(cam['index'] == 0 for cam in available_cameras)
    if not has_index_0:
        logger.info("Adding index 0 as fallback option (not detected)")
        available_cameras.insert(0, {
            'index': 0,
            'name': 'Camera Index 0 (not detected)',
            'working': False,
            'resolution': 'Unknown'
        })

    if not available_cameras:
        logger.warning("No cameras detected!")
        # Add at least one entry for index 0 as fallback
        available_cameras.append({
            'index': 0,
            'name': 'Default Camera (Index 0)',
            'working': False,
            'resolution': 'Unknown'
        })

    logger.info(f"Found {len(available_cameras)} available camera(s)")

    # Cache the results
    with _cache_lock:
        _camera_cache = available_cameras.copy()
        _cache_time = time.time()

    return available_cameras


def get_available_cameras_fast() -> List[Dict]:
    """
    Get cameras quickly - returns cached results or minimal fallback.
    Use this for UI initialization to avoid lag.
    """
    global _camera_cache

    # Return cached results if available
    if _camera_cache is not None:
        return _camera_cache.copy()

    # Return minimal fallback without blocking
    return [{
        'index': 0,
        'name': 'Default Camera (Index 0)',
        'working': True,
        'resolution': 'Auto'
    }]


def refresh_cameras_async(callback=None):
    """
    Refresh camera list in background thread.

    Args:
        callback: Optional function to call with results when done
    """
    def _refresh():
        global _camera_cache, _cache_time
        with _cache_lock:
            _camera_cache = None  # Force refresh
            _cache_time = 0
        result = get_available_cameras(use_cache=False)
        if callback:
            callback(result)

    thread = threading.Thread(target=_refresh, daemon=True)
    thread.start()
    return thread


def _get_camera_names() -> Dict[int, str]:
    """
    Get camera names using platform-specific methods.

    Returns:
        Dictionary mapping camera index to camera name
    """
    camera_names = {}
    system = platform.system()

    try:
        if system == 'Windows':
            camera_names = _get_windows_camera_names()
        elif system == 'Linux':
            camera_names = _get_linux_camera_names()
        elif system == 'Darwin':  # macOS
            camera_names = _get_macos_camera_names()
    except Exception as e:
        logger.debug(f"Could not get camera names for {system}: {e}")

    return camera_names


def _get_windows_camera_names() -> Dict[int, str]:
    """Get camera names on Windows using device enumeration."""
    camera_names = {}

    try:
        # Try using pygrabber (most reliable for camera names on Windows)
        try:
            from pygrabber.dshow_graph import FilterGraph

            graph = FilterGraph()
            devices = graph.get_input_devices()

            logger.info(f"pygrabber found {len(devices)} camera device(s)")

            for idx, device_name in enumerate(devices):
                # Clean up the device name
                clean_name = device_name.strip()
                camera_names[idx] = clean_name
                logger.debug(f"Camera {idx}: {clean_name}")

            return camera_names

        except ImportError:
            logger.debug("pygrabber not available, trying alternative methods")
        except Exception as e:
            logger.debug(f"Error using pygrabber: {e}")

        # Fallback 1: Try using Windows Registry
        try:
            import winreg

            # Check common registry locations for camera devices
            reg_paths = [
                r"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Video\Capture",
                r"SYSTEM\CurrentControlSet\Control\DeviceClasses\{65e8773d-8f56-11d0-a3b9-00a0c9223196}"
            ]

            device_idx = 0
            for reg_path in reg_paths:
                try:
                    key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, reg_path)
                    i = 0
                    while True:
                        try:
                            subkey_name = winreg.EnumKey(key, i)
                            subkey = winreg.OpenKey(key, subkey_name)
                            try:
                                device_name, _ = winreg.QueryValueEx(subkey, "FriendlyName")
                                if "camera" in device_name.lower() or "cam" in device_name.lower():
                                    camera_names[device_idx] = device_name
                                    device_idx += 1
                            except:
                                pass
                            winreg.CloseKey(subkey)
                            i += 1
                        except OSError:
                            break
                    winreg.CloseKey(key)
                except:
                    pass

            if camera_names:
                return camera_names

        except ImportError:
            logger.debug("winreg not available")
        except Exception as e:
            logger.debug(f"Error accessing Windows Registry: {e}")

        # Fallback 2: Try WMI if available
        try:
            import wmi
            c = wmi.WMI()

            # Try multiple WMI queries
            cameras = []
            try:
                cameras = c.Win32_PnPEntity(PNPClass="Camera")
            except:
                try:
                    cameras = c.Win32_PnPEntity(PNPClass="Image")
                except:
                    pass

            for idx, camera in enumerate(cameras):
                if hasattr(camera, 'Name'):
                    camera_names[idx] = camera.Name
                elif hasattr(camera, 'Caption'):
                    camera_names[idx] = camera.Caption

            if camera_names:
                return camera_names

        except ImportError:
            logger.debug("wmi not available")
        except Exception as e:
            logger.debug(f"Error using WMI: {e}")

    except Exception as e:
        logger.debug(f"Error getting Windows camera names: {e}")

    return camera_names


def _get_linux_camera_names() -> Dict[int, str]:
    """Get camera names on Linux using v4l2."""
    camera_names = {}

    try:
        import subprocess
        import re

        # Use v4l2-ctl to list devices
        result = subprocess.run(['v4l2-ctl', '--list-devices'],
                              capture_output=True, text=True, timeout=5)

        if result.returncode == 0:
            lines = result.stdout.split('\n')
            current_device = None
            device_idx = 0

            for line in lines:
                # Device name line (doesn't start with whitespace)
                if line and not line.startswith((' ', '\t')):
                    current_device = line.strip().rstrip(':')
                # Device path line (starts with whitespace)
                elif line.strip().startswith('/dev/video'):
                    match = re.search(r'/dev/video(\d+)', line)
                    if match and current_device:
                        idx = int(match.group(1))
                        camera_names[idx] = current_device

    except (subprocess.TimeoutExpired, FileNotFoundError, Exception) as e:
        logger.debug(f"Error getting Linux camera names: {e}")

    return camera_names


def _get_macos_camera_names() -> Dict[int, str]:
    """Get camera names on macOS."""
    camera_names = {}

    try:
        import subprocess

        # Use system_profiler to get camera info
        result = subprocess.run(
            ['system_profiler', 'SPCameraDataType'],
            capture_output=True, text=True, timeout=5
        )

        if result.returncode == 0:
            lines = result.stdout.split('\n')
            device_idx = 0

            for line in lines:
                # Look for camera model names
                if 'Model ID' in line or '_name' in line:
                    parts = line.split(':')
                    if len(parts) > 1:
                        camera_name = parts[1].strip()
                        camera_names[device_idx] = camera_name
                        device_idx += 1

    except (subprocess.TimeoutExpired, FileNotFoundError, Exception) as e:
        logger.debug(f"Error getting macOS camera names: {e}")

    return camera_names


def test_camera(camera_index: int) -> bool:
    """
    Test if a camera at the given index is working.

    Args:
        camera_index: Camera index to test

    Returns:
        True if camera is working, False otherwise
    """
    try:
        # Use MSMF (Media Foundation) on Windows for better compatibility
        # This matches the backend used in camera_handler.py
        if platform.system() == 'Windows':
            cap = cv2.VideoCapture(camera_index, cv2.CAP_MSMF)
        else:
            cap = cv2.VideoCapture(camera_index)

        if not cap.isOpened():
            return False

        ret, frame = cap.read()
        cap.release()

        return ret and frame is not None

    except Exception as e:
        logger.error(f"Error testing camera {camera_index}: {e}")
        return False
