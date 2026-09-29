@echo off
title Wardogs Command Net setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-WardogsCommandNet.ps1"
if errorlevel 1 (
    echo.
    echo Setup did not finish. Send a screenshot of this window to the server admin.
)
echo.
pause
