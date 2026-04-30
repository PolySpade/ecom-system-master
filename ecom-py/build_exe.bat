@echo off
echo Building Ecom Video Tracker executable...
echo.

REM Activate virtual environment
call .venv\Scripts\activate

REM Build executable
pyinstaller --onefile ^
    --windowed ^
    --name "Ecom-Video-Tracker" ^
    --add-data "config.py;." ^
    --hidden-import=PIL ^
    --hidden-import=PIL._tkinter_finder ^
    app_gui.py

echo.
echo Build complete!
echo Executable is in the 'dist' folder
echo.
pause
