@echo off
echo Starting Ecom Video Tracker (Web Version)...
echo.

REM Activate virtual environment
call .venv\Scripts\activate

REM Run Flask application
python app.py

pause
