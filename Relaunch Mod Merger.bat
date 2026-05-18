@echo off
cd /d "%~dp0"
start "Mod Merger" cmd /c "%~dp0launcher.bat"
timeout /t 2 /nobreak >nul
echo Mod Merger started via launcher.bat — check your taskbar.
