@echo off
rem Removes Prompt Peon, your token and all its saved data. Double-click this file.
setlocal
set "NoDefaultCurrentDirectoryInExePath=1"
rem Windows won't delete a folder something is standing in, and this may be in the folder it removes.
cd /d "%TEMP%" 2>nul
set "PYTHON="
set "PYFLAG="
py -3 -I -c "" >nul 2>nul && set "PYTHON=py" && set "PYFLAG=-3"
if not defined PYTHON python -I -c "" >nul 2>nul && set "PYTHON=python"
if not defined PYTHON if exist "%LOCALAPPDATA%\Programs\Python\Python314\python.exe" set "PYTHON=%LOCALAPPDATA%\Programs\Python\Python314\python.exe"
if not defined PYTHON (
  echo Could not find Python to run the removal.
  goto done
)
rem All on one line, because this file may be gone by the time the removal finishes.
"%PYTHON%" %PYFLAG% -I "%~dp0bridge\promptpeon_bridge.py" uninstall %* & echo. & pause & exit /b
:done
echo.
pause
