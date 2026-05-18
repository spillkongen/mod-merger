@echo off
cd /d "%~dp0"
title Mod Merger
if not exist "%~dp0Texturepack-Merge-Launcher.ps1" (
    echo ERROR: Texturepack-Merge-Launcher.ps1 not found in:
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
echo Starting Mod Merger...
"%PS_EXE%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Texturepack-Merge-Launcher.ps1"
set ERR=%ERRORLEVEL%
if %ERR% neq 0 (
    echo.
    echo Mod Merger did not start ^(exit code %ERR%^).
    if exist "%~dp0_err.txt" (
        echo.
        echo Contents of _err.txt:
        type "%~dp0_err.txt"
    ) else (
        echo No _err.txt was written - try Start Mod Merger.vbs instead.
    )
    echo.
    pause
    exit /b %ERR%
)
