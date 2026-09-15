@echo off
setlocal
title Build Beckhoff RT Linux Setup - release
cd /d "%~dp0"
echo ============================================================
echo  Beckhoff RT Linux Setup - release build
echo  Unofficial tool by Abdullah Omar, Beckhoff UAE
echo ============================================================
echo.
echo Step 1: BeckhoffRTLinuxSetup.ps1  -^>  build\BeckhoffRTLinuxSetup.exe
echo Step 2: build\...exe              -^>  dist\BeckhoffRTLinuxSetup-Setup-x.y.z.exe  (installer for customers)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Release.ps1"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
    echo Finished. The customer installer is in the "dist" folder.
) else (
    echo Build failed with code %RC%. Scroll up for details.
)
echo.
pause
exit /b %RC%
