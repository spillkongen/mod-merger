@echo off
REM Mod Merger — always start the app with this file (double-click launcher.bat).
cd /d "%~dp0"
title Mod Merger

if not exist "%~dp0Texturepack-Merge-Launcher.ps1" (
    echo ERROR: Texturepack-Merge-Launcher.ps1 not found in:
    echo   %~dp0
    pause
    exit /b 1
)

if not exist "%~dp0Texturepack-Merge-GUI.ps1" (
    echo ERROR: Texturepack-Merge-GUI.ps1 not found in:
    echo   %~dp0
    pause
    exit /b 1
)

set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
    echo ERROR: PowerShell not found at:
    echo   %PS_EXE%
    pause
    exit /b 1
)

REM Show build tag if BUILD-VERSION.txt exists
if exist "%~dp0BUILD-VERSION.txt" (
    echo.
    type "%~dp0BUILD-VERSION.txt"
    echo.
) else (
    echo Starting Mod Merger...
)

"%PS_EXE%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Texturepack-Merge-Launcher.ps1"
set ERR=%ERRORLEVEL%

if %ERR% neq 0 (
    echo.
    echo Mod Merger exited with an error ^(code %ERR%^).
    if exist "%~dp0_err.txt" (
        echo.
        echo --- _err.txt ---
        type "%~dp0_err.txt"
    )
    if exist "%~dp0mod-merger.log" (
        echo.
        echo Tip: also see mod-merger.log in this folder.
    )
    echo.
    pause
    exit /b %ERR%
)

exit /b 0
