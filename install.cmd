@echo off
rem Prompt Peon setup for Windows. Double-click this file.
setlocal
if not exist "%~dp0bridge\promptpeon_bridge.py" (
  echo Unpack the ZIP first: right-click it and choose Extract All, then run install.cmd from the new folder.
  goto done
)
rem Never run a py.exe or python.exe that happens to sit next to this file.
set "NoDefaultCurrentDirectoryInExePath=1"
set "CHECK=import sys; sys.exit(sys.version_info < (3, 14))"
set "PYTHON="
set "PYFLAG="
py -3 -I -c "%CHECK%" >nul 2>nul && set "PYTHON=py" && set "PYFLAG=-3"
if not defined PYTHON python -I -c "%CHECK%" >nul 2>nul && set "PYTHON=python"
if not defined PYTHON (
  echo Prompt Peon needs Python, which is free and small. Installing it just for you...
  winget install -e --id Python.Python.3.14 --scope user --silent --accept-package-agreements --accept-source-agreements
  if exist "%LOCALAPPDATA%\Programs\Python\Python314\python.exe" set "PYTHON=%LOCALAPPDATA%\Programs\Python\Python314\python.exe"
)
if not defined PYTHON (
  echo.
  echo Could not install Python by itself. Get it from https://www.python.org/downloads/ and run this again.
  goto done
)
"%PYTHON%" %PYFLAG% -I "%~dp0bridge\promptpeon_bridge.py" install %*
:done
echo.
pause
