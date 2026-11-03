@echo off
rem Turns the Prompt Peon companion app off if it is running, and on if it is not. Double-click this file.
setlocal
if not exist "%~dp0bridge\promptpeon_bridge.py" (
  echo Unpack the ZIP first: right-click it and choose Extract All, then run this from the new folder.
  goto done
)
rem Never run a py.exe or python.exe that happens to sit next to this file.
set "NoDefaultCurrentDirectoryInExePath=1"
set "CHECK=import sys; sys.exit(sys.version_info < (3, 14))"
set "PYTHON="
set "PYFLAG="
py -3 -I -c "%CHECK%" >nul 2>nul && set "PYTHON=py" && set "PYFLAG=-3"
if not defined PYTHON python -I -c "%CHECK%" >nul 2>nul && set "PYTHON=python"
if not defined PYTHON if exist "%LOCALAPPDATA%\Programs\Python\Python314\python.exe" set "PYTHON=%LOCALAPPDATA%\Programs\Python\Python314\python.exe"
if not defined PYTHON (
  echo Could not find Python 3.14 or newer. Run install.cmd first, which gets it for you.
  goto done
)
"%PYTHON%" %PYFLAG% -I "%~dp0bridge\promptpeon_bridge.py" start-stop
:done
echo.
pause
