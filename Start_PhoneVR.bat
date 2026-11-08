@echo off
title PhoneVR All-In-One Launcher
cd /d "%~dp0"

echo Starting PhoneVR Server and Streaming...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc\phonevr_server.ps1"

if %errorlevel% neq 0 (
    echo.
    echo PhoneVR stopped with code %errorlevel%.
    pause
)
