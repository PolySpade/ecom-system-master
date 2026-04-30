@echo off
echo ========================================
echo Installing tkcalendar for Date Pickers
echo ========================================
echo.

REM Activate virtual environment
call .venv\Scripts\activate

echo Installing tkcalendar...
pip install tkcalendar==1.6.1

echo.
echo ========================================
echo Installation Complete!
echo ========================================
echo.
echo Calendar date pickers are now available in the Search window.
echo You can now select dates using a visual calendar popup.
echo.
pause
