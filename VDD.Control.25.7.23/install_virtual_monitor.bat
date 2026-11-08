@echo off
cd /d "%~dp0"
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~dp0install_virtual_monitor.bat\"\"' -Verb RunAs"
    exit /b
)

echo Installing Virtual Display Driver...
if not exist "C:\VirtualDisplayDriver" mkdir "C:\VirtualDisplayDriver"
copy /y "%~dp0Dependencies\vdd_settings.xml" "C:\VirtualDisplayDriver\vdd_settings.xml"

"%~dp0Dependencies\devcon.exe" install "%~dp0SignedDrivers\x86\VDD\MttVDD.inf" Root\MttVDD

echo.
echo ========================================================
echo Virtual Display Driver installed!
echo Look at Windows Settings - System - Display for Display 3.
echo ========================================================
echo.
pause
