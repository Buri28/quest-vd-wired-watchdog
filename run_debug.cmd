@echo off
rem Run the watchdog in the foreground so the log can be watched live.
rem This does NOT register autostart - use install.cmd for that.
rem Close the window or press Ctrl+C to stop.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watchdog.ps1"
echo.
pause
