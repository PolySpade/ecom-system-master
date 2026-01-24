@echo off
echo Starting Ecom Video Tracker (Desktop GUI)...
echo.

REM Activate virtual environment
call .venv\Scripts\activate

REM Run GUI application
python app_gui.py

pause
