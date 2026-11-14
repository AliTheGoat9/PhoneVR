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

rem On laptops with two GPUs, put the virtual display on the dedicated GPU (the one SteamVR renders and
rem encodes with), so frames never have to cross GPUs. Falls back to "default" when there is only one.
powershell -NoProfile -Command "$g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon' } | Select-Object -First 1; if ($g) { $f='C:\VirtualDisplayDriver\vdd_settings.xml'; (Get-Content $f -Raw) -replace '<friendlyname>[^<]*</friendlyname>', ('<friendlyname>' + $g.Name + '</friendlyname>') | Set-Content $f -Encoding UTF8; Write-Host ('Virtual display GPU: ' + $g.Name) }"

"%~dp0Dependencies\devcon.exe" install "%~dp0SignedDrivers\x86\VDD\MttVDD.inf" Root\MttVDD

echo.
echo ========================================================
echo Virtual Display Driver installed!
echo Now open Windows Settings - System - Display:
echo   1. Select the new virtual display.
echo   2. Choose "Extend these displays" (not Duplicate).
echo   3. Set it to 2992 x 1344 and 120 Hz (Advanced display).
echo Then restart SteamVR.
echo ========================================================
echo.
pause
