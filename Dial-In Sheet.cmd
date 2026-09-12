@echo off
rem Dial-In Sheet: the one thing to double-click.
rem Updates the helper, installs the latest plugin, opens the dial-in sheet in
rem your browser and starts PrusaSlicer. Runs minimised; close it to stop.
setlocal
cd /d "%~dp0"

set "PY="
py -3 --version >nul 2>&1
if not errorlevel 1 set "PY=py -3"
if not defined PY (
  python --version >nul 2>&1
  if not errorlevel 1 set "PY=python"
)
if not defined PY (
  python3 --version >nul 2>&1
  if not errorlevel 1 set "PY=python3"
)
if not defined PY (
  echo Python was not found on this PC.
  echo.
  echo Install Python 3 from https://www.python.org/downloads/ and tick
  echo "Add python.exe to PATH" in the installer, then double-click this file again.
  echo.
  pause
  exit /b 1
)

rem A failure keeps the window open to be read; a clean exit closes it.
start "Dial-In helper" /min cmd /c "%PY% "%~dp0helper\dialin_helper.py" --auto || pause"
exit /b 0
