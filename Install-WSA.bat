@echo off
:: wsa-autoinstall - one-click Windows Subsystem for Android installer
:: Copyright (C) 2026  Chi-K1ng
:: Licensed under the GNU Affero General Public License v3.0 or later.

setlocal
title WSA Auto-Install

:: --- self-elevate -------------------------------------------------------
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator rights...
    rem Passed through the environment, not the command line, so that paths
    rem or arguments containing quotes and spaces survive the trip into PowerShell.
    set "WSA_ELEV_SELF=%~f0"
    set "WSA_ELEV_ARGS=%*"
    powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try { if ([string]::IsNullOrWhiteSpace($env:WSA_ELEV_ARGS)) { Start-Process -FilePath $env:WSA_ELEV_SELF -Verb RunAs } else { Start-Process -FilePath $env:WSA_ELEV_SELF -ArgumentList $env:WSA_ELEV_ARGS -Verb RunAs } } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo   ERROR: could not restart with administrator rights.
        echo   Approve the User Account Control prompt, or right-click this
        echo   file and choose "Run as administrator".
        echo.
        pause
    )
    exit /b
)

:: --- locate the payload -------------------------------------------------
set "SCRIPT=%~dp0scripts\Install-WSA.ps1"
if not exist "%SCRIPT%" (
    echo.
    echo   ERROR: scripts\Install-WSA.ps1 was not found.
    echo   Extract the whole download, then run this file again.
    echo.
    pause
    exit /b 1
)

:: --- hand off to PowerShell --------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo   Finished.
) else (
    echo   Exited with code %RC%.
    echo   Logs are in %%TEMP%%\wsa-autoinstall-*.log - send the newest one when reporting a problem.
)
pause
exit /b %RC%
