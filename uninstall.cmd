@echo off
rem Remove the startup entry and stop any running watchdog instance.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watchdog.ps1" -Uninstall
echo.
pause
