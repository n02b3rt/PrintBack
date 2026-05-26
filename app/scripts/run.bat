@echo off
REM Convenience launcher for unattended PrintBack deployment.
REM Double-click this (or set as Startup task) to run the app under the
REM supervisor — it restarts on crash and logs uptime to
REM %APPDATA%\PrintBack\supervisor.log.
REM
REM Forwards all args to printback (e.g. run.bat --port COM5).

setlocal
cd /d "%~dp0\.."
if not exist ".venv\Scripts\python.exe" (
    echo error: .venv not found at %CD%\.venv
    echo run: python -m venv .venv ^&^& .venv\Scripts\activate ^&^& pip install -e .
    pause
    exit /b 1
)
".venv\Scripts\python.exe" "scripts\supervisor.py" %*
endlocal
