@echo off
rem Start the watchdog now, and register it to run automatically at every logon.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watchdog.ps1" -Install
echo.
pause
