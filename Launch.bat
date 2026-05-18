@echo off
REM Same as launcher.bat (kept for older shortcuts).
cd /d "%~dp0"
call "%~dp0launcher.bat"
exit /b %ERRORLEVEL%
