@echo off
REM Launcher that elevates to admin before running the supervisor.
REM Required for the software USB reset feature (pnputil /restart-device)
REM to recover from "device not functioning" without unplugging the cable.
REM
REM On first launch Windows will show a UAC prompt. Accept once and the
REM Task Scheduler / Startup shortcut path can be configured to skip the
REM prompt subsequently.

setlocal
net session >nul 2>&1
if %errorLevel% == 0 (
    REM Already elevated — just run.
    call "%~dp0run.bat" %*
    exit /b %errorLevel%
)

REM Not elevated — relaunch via PowerShell with Start-Process -Verb RunAs.
powershell -NoProfile -Command "Start-Process -FilePath '%~dp0run.bat' -ArgumentList '%*' -Verb RunAs -WorkingDirectory '%~dp0'"
endlocal
