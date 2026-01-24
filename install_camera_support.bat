@echo off
echo ========================================
echo Installing Camera Detection Support
echo ========================================
echo.

REM Activate virtual environment
call .venv\Scripts\activate

echo Installing pygrabber for camera name detection...
pip install pygrabber

echo.
echo ========================================
echo Installation Complete!
echo ========================================
echo.
echo Camera names (like "DroidCam OBS") will now be detected automatically.
echo MSMF warnings have been eliminated by switching to DirectShow backend.
echo.
pause
