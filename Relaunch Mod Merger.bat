@echo off
cd /d "%~dp0"
REM Opens Mod Merger on your desktop (detached from this window).
start "Mod Merger" /D "%~dp0" wscript.exe "%~dp0Start Mod Merger.vbs"
timeout /t 2 /nobreak >nul
echo Mod Merger launch requested. Check your taskbar for the window.
echo If nothing appears, run Launch.bat instead to see error text.
timeout /t 4
