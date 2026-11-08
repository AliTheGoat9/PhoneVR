@echo off
cd /d "%~dp0"
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~dp0uninstall_virtual_monitor.bat\"\"' -Verb RunAs"
    exit /b
)

echo Removing Virtual Display Driver...
"%~dp0Dependencies\devcon.exe" remove Root\MttVDD

echo.
echo ========================================================
echo Virtual Display Driver removed!
echo ========================================================
echo.
pause
