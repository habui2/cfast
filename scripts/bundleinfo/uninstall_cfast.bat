@echo off

NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo *** Error: This script is running as %username%.  It must run as Administrator.
    echo       Run again, after right clicking on this script and selecting "Run as Adminstrator"
    echo       CFAST uninstaller aborted.
    pause
    exit
)

call :is_fds_installed
if %fdsinstalled% == 1 goto skip1
  echo.
  echo *** Removing the association between .smv and Smokeview
  assoc .smv=
  ftype smvDoc=
:skip1

echo. 
echo *** Removing cfast from the Start menu.
rmdir /q /s "%ALLUSERSPROFILE%\Start Menu\Programs\cfast"

