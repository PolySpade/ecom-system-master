@echo off
echo ========================================
echo Ecom Video Tracker - Installation
echo ========================================
echo.

REM Check if Python is installed
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python is not installed or not in PATH
    echo Please install Python 3.10+ from https://www.python.org/downloads/
    pause
    exit /b 1
)

echo Python is installed.
echo.

REM Check if virtual environment exists
if not exist .venv (
    echo Creating virtual environment...
    python -m venv .venv
    if errorlevel 1 (
        echo ERROR: Failed to create virtual environment
        pause
        exit /b 1
    )
    echo Virtual environment created successfully.
) else (
    echo Virtual environment already exists.
)
echo.

REM Activate virtual environment
echo Activating virtual environment...
call .venv\Scripts\activate
echo.

REM Install base dependencies
echo Installing base dependencies...
python -m pip install --upgrade pip
pip install -r requirements.txt
if errorlevel 1 (
    echo ERROR: Failed to install dependencies
    pause
    exit /b 1
)
echo.

REM Install Windows-specific packages
echo Installing Windows-specific packages...
pip install pygrabber==0.2
if errorlevel 1 (
    echo WARNING: Failed to install pygrabber (camera detection may be limited)
)
echo.

echo Installing calendar date picker...
pip install tkcalendar==1.6.1
if errorlevel 1 (
    echo WARNING: Failed to install tkcalendar (date pickers may not work)
)
echo.

echo ========================================
echo Installation Complete!
echo ========================================
echo.
echo To run the application:
echo   - Desktop GUI: run_gui.bat (or: python app_gui.py)
echo   - Web UI:      run_web.bat (or: python app.py)
echo.
echo The database and settings will be created automatically on first run.
echo.
pause
